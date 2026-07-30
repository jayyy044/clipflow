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
    // Return reaches the view two ways — the panel's key handler and the search
    // field's onSubmit — and only one of them should ever fire per press. If
    // SwiftUI delivers both, the visible damage is the item pasted twice into the
    // user's document, which is worse than dropping a deliberate second paste
    // 200 ms after the first (nothing can select and re-fire that fast).
    let now = ContinuousClock.now
    guard now - lastPasteAt > .milliseconds(200) else { return }
    lastPasteAt = now

    guard isTrusted else {
      explainMissingPermission()
      return
    }
    // PRD HP-6: with secure input held, the synthetic keystroke is swallowed and
    // the user sees an app that did nothing at all.
    guard !IsSecureEventInputEnabled() else {
      explainSecureInput()
      return
    }

    let target = targetApp
    if let target, !target.isTerminated, !target.isActive {
      target.activate()
    }

    Task { @MainActor in
      await waitForFrontmost(target)
      try? await Task.sleep(for: settleAfterFocus)
      postCommandV()
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

  /// FR-5.4's one-time explanation. Once, not per paste — an app that opens a
  /// dialog every time you use it gets its permission revoked out of annoyance.
  /// The status item menu keeps a permanent, silent route back (AppDelegate).
  private static func explainMissingPermission() {
    guard !UserDefaults.standard.bool(forKey: explainedKey) else {
      NSLog("ClipFlow: paste needs Accessibility permission; copied instead")
      return
    }
    UserDefaults.standard.set(true, forKey: explainedKey)

    let alert = NSAlert()
    alert.messageText = "ClipFlow copied the item instead of pasting it"
    alert.informativeText = """
      Pasting into another app means pressing Cmd+V for you, which macOS only \
      allows with Accessibility permission.

      Grant it in System Settings > Privacy & Security > Accessibility. Until \
      then Option+Enter copies, and you can paste yourself.
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

  /// Not persisted like the permission alert: secure input is transient and only
  /// ever surfaces on an explicit Option+Enter, so it can't nag on its own.
  private static func explainSecureInput() {
    NSLog("ClipFlow: secure input is enabled; copied instead of pasting")

    let alert = NSAlert()
    alert.messageText = "ClipFlow copied the item instead of pasting it"
    alert.informativeText = """
      An app has secure input turned on — usually a focused password field. \
      macOS discards synthetic keystrokes while it is on.

      The item is on your clipboard. Click outside the password field and press \
      Cmd+V.
      """
    alert.addButton(withTitle: "OK")
    NSApp.activate(ignoringOtherApps: true)
    alert.runModal()
  }
}
