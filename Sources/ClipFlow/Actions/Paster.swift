import AppKit
import Carbon.HIToolbox

/// Makes the app you were in actually paste. PRD HP-2 calls this the hardest
/// part of the project, and both ways it fails are timing: the keystroke lands
/// in the wrong app, or it lands before the right one is listening again.
///
/// Nothing here writes the pasteboard — `Clipboard.copy` does that first.
@MainActor
enum Paster {
  /// DECISIONS S-12. Recorded *before* the panel is ordered front. Read at paste
  /// time instead, this returns whatever macOS considers frontmost once our panel
  /// has taken key focus, which can be ClipFlow itself — and then Cmd+V goes into
  /// our own search field.
  private(set) static var targetApp: NSRunningApplication?

  /// kVK_ANSI_V. Not mapped through the current keyboard layout: PRD HP-4's
  /// layout problem is what Maccy pulls in `Sauce` for, and NFR-3 caps us at two
  /// dependencies. macOS's own Dvorak variants keep QWERTY positions while Cmd is
  /// held, which is the case that would otherwise break.
  private static let vKeyCode = CGKeyCode(kVK_ANSI_V)

  /// HP-2's "brief moment" after the panel closes, sized against the thing the
  /// target app is actually waiting on: the window server retiring our panel.
  /// Measured over 10 opens of a panel with this exact configuration, timing
  /// `close()` to the window leaving `CGWindowListCopyWindowInfo` — 2.0 ms best,
  /// 20.1 ms mean, 46.8 ms worst. 60 ms clears every observation.
  ///
  /// Not measured end to end: pasting into a real app needs the Accessibility
  /// grant, which nobody had when this was written (DECISIONS D-12). Hence the
  /// override — being 20 ms early fails silently, the keystroke is simply eaten,
  /// and the alternative to a knob is asking for a rebuild to find that out.
  private static var settleAfterFocus: Duration {
    let override = UserDefaults.standard.integer(forKey: "pasteSettleMilliseconds")
    return .milliseconds(override > 0 ? override : 60)
  }

  /// Polling budget for the target app becoming frontmost again. Only spent when
  /// it actually lost frontmost — in the normal flow the panel never took it
  /// away, so the first poll passes and this costs nothing.
  private static let activationTimeout: Duration = .milliseconds(250)
  private static let activationPollInterval: Duration = .milliseconds(10)

  private static let explainedKey = "hasExplainedAccessibility"
  private static var lastPasteAt = ContinuousClock.now - .seconds(1)

  /// `nonisolated` so the status item's click handler can ask without hopping
  /// actors mid-menu-build. `AXIsProcessTrusted` is a thread-safe C call.
  nonisolated static var isTrusted: Bool { AXIsProcessTrusted() }

  static func captureTargetApp() {
    guard let app = NSWorkspace.shared.frontmostApplication else { return }
    // Clicking the status item can leave ClipFlow frontmost. Pasting into
    // ourselves is never what was meant, so the last real target is kept.
    guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
    targetApp = app
  }

  /// Call after the item is on the pasteboard and the panel is closed. When it
  /// can't paste it says why (FR-5.4) — the item is already copied either way,
  /// which is the copy-only fallback, not a failure.
  static func paste() {
    deliver(didCopy: true) { postCommandV() }
  }

  /// Types `text` as literal characters. DECISIONS V-5: a vault value written to
  /// `NSPasteboard.general` is readable by every app on the machine for as long as
  /// it sits there, and nothing in this process can bound that. Synthesised key
  /// events never touch the pasteboard.
  ///
  /// Same preconditions as `paste()`, with one difference that changes how failure
  /// has to be handled: there is no copy-only fallback here. When this refuses, the
  /// secret went nowhere at all, so the user must be told rather than left watching
  /// an app that did nothing.
  static func type(_ text: String) {
    guard !text.isEmpty else { return }
    deliver(didCopy: false) { await postUnicode(text) }
  }

  /// Everything both routes need before a synthetic event is worth posting.
  /// `didCopy` is only about what the user is told when we bail — the checks are
  /// identical, the consolation prize is not.
  private static func deliver(didCopy: Bool, _ post: @escaping @MainActor () async -> Void) {
    // Return reaches the view two ways — the panel's key handler and the search
    // field's onSubmit — and only one of them should ever fire per press. If
    // SwiftUI delivers both, the visible damage is the item pasted twice into the
    // user's document, which is worse than dropping a deliberate second paste
    // 200 ms after the first (nothing can select and re-fire that fast). Shared
    // across both routes deliberately: a vault value typed twice is the same bug.
    let now = ContinuousClock.now
    guard now - lastPasteAt > .milliseconds(200) else { return }
    lastPasteAt = now

    guard isTrusted else {
      explainMissingPermission(didCopy: didCopy)
      return
    }
    // PRD HP-6: with secure input held, the synthetic keystroke is swallowed and
    // the user sees an app that did nothing at all. Unchanged for typing — the
    // same tap eats both — so this is a shared limitation, not a new one.
    guard !IsSecureEventInputEnabled() else {
      explainSecureInput(didCopy: didCopy)
      return
    }

    let target = targetApp
    if let target, !target.isTerminated, !target.isActive {
      target.activate()
    }

    Task { @MainActor in
      await waitForFrontmost(target)
      try? await Task.sleep(for: settleAfterFocus)
      await post()
    }
  }

  /// A target that quit, or was never captured, is not a reason to refuse: the
  /// panel is non-activating, so whatever is frontmost now is what the user was
  /// looking at when they pressed the key. Posting blind is what they asked for.
  private static func waitForFrontmost(_ target: NSRunningApplication?) async {
    guard let target, !target.isTerminated else { return }

    let deadline = ContinuousClock.now + activationTimeout
    while ContinuousClock.now < deadline {
      if NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier {
        return
      }
      try? await Task.sleep(for: activationPollInterval)
    }
    NSLog("ClipFlow: \(target.localizedName ?? "target app") did not come frontmost; pasting anyway")
  }

  private static func postCommandV() {
    let source = CGEventSource(stateID: .combinedSessionState)
    guard let down = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
          let up = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
    else { return }

    // NX_DEVICELCMDKEYMASK alongside maskCommand: some apps check which physical
    // Cmd key was pressed and ignore an event that claims neither. Same fix Maccy
    // carries from Flycut (p0deje/Maccy Clipboard.swift, TermiT/Flycut#18).
    let flags = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x0000_0008)
    // On both halves: an app tracking modifier state off the key-up otherwise
    // sees Cmd released mid-chord and treats the whole thing as a bare "v".
    down.flags = flags
    up.flags = flags
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
  }

  /// The unicode payload each event carries is copied into a fixed-size buffer
  /// inside the event, so one call with a long string is truncated rather than
  /// rejected — a silently short secret. Roughly 20 UTF-16 units per event stays
  /// well inside it.
  private static let chunkUTF16Budget = 20

  /// Back-to-back posts arrive faster than any keyboard can produce them, and apps
  /// that do their own key handling (terminals, Electron fields) drop events that
  /// land inside a single run-loop pass. A 2 ms gap costs ~10 ms on a 100-character
  /// secret, which nobody notices.
  ///
  /// A guess, not a measurement, and it has `settleAfterFocus`'s override for
  /// `settleAfterFocus`'s reason: too small fails *silently*. The dropped
  /// characters land in a field that renders every one of them as a bullet, so
  /// the user cannot see that half their SSN went missing — and the alternative
  /// to a knob is asking them to rebuild the app to find out.
  private static var interChunkDelay: Duration {
    let override = UserDefaults.standard.integer(forKey: "typeChunkDelayMilliseconds")
    return .milliseconds(override > 0 ? override : 2)
  }

  /// Split on grapheme cluster boundaries, never on a UTF-16 index. A cut through a
  /// surrogate pair yields a replacement character, and a cut between a base letter
  /// and its combining mark makes the target app compose — and often autocorrect —
  /// something other than what was stored. For a password neither is recoverable by
  /// the user, because they can't see what arrived.
  private static func chunks(of text: String) -> [[UniChar]] {
    var result: [[UniChar]] = []
    var current: [UniChar] = []
    for character in text {
      let units = Array(String(character).utf16)
      if !current.isEmpty, current.count + units.count > chunkUTF16Budget {
        result.append(current)
        current = []
      }
      // A single cluster over budget (long emoji ZWJ sequences) goes out whole and
      // over: splitting it is the one thing that must not happen.
      current.append(contentsOf: units)
    }
    if !current.isEmpty { result.append(current) }
    return result
  }

  /// Never logged, never string-interpolated into anything — the argument here is
  /// the plaintext, and NSLog goes to the unified log where any admin can read it.
  private static func postUnicode(_ text: String) async {
    let source = CGEventSource(stateID: .combinedSessionState)
    for chunk in chunks(of: text) {
      guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
      else { return }

      // Virtual key 0 is a real key ('a'); the unicode string is what a text field
      // reads instead. The flags are the part that matters: the hotkey that opened
      // the panel may still be physically held, and a Cmd left set turns every
      // chunk into a shortcut fired at the user's document.
      down.flags = []
      up.flags = []
      chunk.withUnsafeBufferPointer { buffer in
        down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
        up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
      }
      down.post(tap: .cghidEventTap)
      up.post(tap: .cghidEventTap)
      try? await Task.sleep(for: interChunkDelay)
    }
  }

  /// FR-5.4's one-time explanation. Once, not per paste — an app that opens a
  /// dialog every time you use it gets its permission revoked out of annoyance.
  /// The status item menu keeps a permanent, silent route back (AppDelegate).
  private static func explainMissingPermission(didCopy: Bool) {
    // Suppression is for the paste route only. There the item is already on the
    // pasteboard and the user has a working manual route, so a repeat alert is pure
    // annoyance. Typing has no fallback: silencing it leaves a vault value that
    // simply never arrived, with nothing on screen to say why.
    if didCopy {
      guard !UserDefaults.standard.bool(forKey: explainedKey) else {
        NSLog("ClipFlow: paste needs Accessibility permission; copied instead")
        return
      }
      UserDefaults.standard.set(true, forKey: explainedKey)
    }

    let alert = NSAlert()
    alert.messageText = didCopy
      ? "ClipFlow copied the item instead of pasting it"
      : "ClipFlow could not type the item"
    alert.informativeText = didCopy ? """
      Pasting into another app means pressing Cmd+V for you, which macOS only \
      allows with Accessibility permission.

      Grant it in System Settings > Privacy & Security > Accessibility. Until \
      then picking an item copies it, and you can paste yourself.
      """ : """
      Typing into another app means sending keystrokes for you, which macOS only \
      allows with Accessibility permission.

      Grant it in System Settings > Privacy & Security > Accessibility. Nothing \
      was sent and nothing was put on your clipboard.
      """
    alert.addButton(withTitle: "Open System Settings")
    alert.addButton(withTitle: "Not Now")

    NSApp.activate(ignoringOtherApps: true)
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    openAccessibilitySettings()
  }

  /// Prompting is what gets ClipFlow listed in the Accessibility pane at all, so
  /// it runs before opening the pane — otherwise the user arrives at a list that
  /// doesn't contain us and has to find the app by hand.
  static func openAccessibilitySettings() {
    let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    _ = AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
    guard let url = URL(
      string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    ) else { return }
    NSWorkspace.shared.open(url)
  }

  /// Not persisted like the permission alert, because secure input is transient —
  /// it goes away when the password field loses focus. Since D-22 made pasting the
  /// default action this can fire on a plain Return, where before it needed a
  /// deliberate modified one; that is the case where the explanation is most
  /// useful, so it stays un-suppressed until it actually proves annoying.
  private static func explainSecureInput(didCopy: Bool) {
    NSLog("ClipFlow: secure input is enabled; \(didCopy ? "copied instead of pasting" : "nothing was typed")")

    let alert = NSAlert()
    alert.messageText = didCopy
      ? "ClipFlow copied the item instead of pasting it"
      : "ClipFlow could not type the item"
    alert.informativeText = didCopy ? """
      An app has secure input turned on — usually a focused password field. \
      macOS discards synthetic keystrokes while it is on.

      The item is on your clipboard. Click outside the password field and press \
      Cmd+V.
      """ : """
      An app has secure input turned on — usually a focused password field. \
      macOS discards synthetic keystrokes while it is on, so nothing reached the \
      field you were in.

      Nothing was put on your clipboard. Close the password field, or reveal the \
      entry and type it yourself.
      """
    alert.addButton(withTitle: "OK")
    NSApp.activate(ignoringOtherApps: true)
    alert.runModal()
  }
}
