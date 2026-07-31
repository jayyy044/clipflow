import AppKit
import KeyboardShortcuts
import ServiceManagement
import SwiftUI

extension KeyboardShortcuts.Name {
  /// Ctrl+Cmd+V. Two modifiers that both suppress text input, so it still fires
  /// inside password fields (PRD HP-4) — Option+J would emit `∆` and get
  /// swallowed there. Ctrl+Cmd is near-empty territory on macOS: only F
  /// (fullscreen), Q (lock screen), and Space (emoji picker) are taken.
  /// Rebindable in Settings (FR-6.2).
  ///
  /// Gotcha: KeyboardShortcuts writes this default into UserDefaults on first
  /// launch, and a stored value then wins forever. Editing the line below will
  /// appear to do nothing on a machine that has already run the app — Settings ›
  /// Shortcuts › Restore Defaults is what clears the stored value.
  static let toggleHistory = Self("toggleHistory", default: .init(.v, modifiers: [.control, .command]))

  /// FR-5.2's `Option+1..9`, one registration per slot. Index 0 is slot 1.
  ///
  /// Global, not panel-local: the whole point is skipping the window (DECISIONS
  /// D-3), so these have to fire while ClipFlow has no focus at all — which is
  /// what KeyboardShortcuts' Carbon hot key does and `onKeyPress` cannot.
  ///
  /// Ctrl+Cmd, not FR-5.2's Option. Option+1..9 emits `¡™£¢∞§¶•ª` on a US
  /// layout, and HP-4 warns that character-emitting chords get suppressed in
  /// secure input contexts — the same reason Option+J was rejected for
  /// `toggleHistory`. They are also tab-switchers in a lot of apps, and a global
  /// Carbon hot key wins system-wide. Ctrl+Cmd emits nothing and matches the
  /// toggle hotkey; Settings can rebind any of the nine (FR-6.2).
  ///
  /// Same first-launch gotcha as `toggleHistory`: the default is written to
  /// UserDefaults once and the stored value then wins.
  static let pasteSlots: [Self] = zip(
    1...9,
    [KeyboardShortcuts.Key.one, .two, .three, .four, .five, .six, .seven, .eight, .nine]
  ).map { slot, key in
    Self("pasteSlot\(slot)", default: .init(key, modifiers: [.control, .command]))
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  private var statusItem: NSStatusItem!
  private var panel: Panel<HistoryView>!

  func applicationDidFinishLaunching(_ notification: Notification) {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    statusItem.button?.action = #selector(statusItemClicked)
    statusItem.button?.target = self
    statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    updateStatusIcon()
    // FR-7.3's arming can be spent by a copy made anywhere, and FR-7.4's pause is
    // settable from the Settings window as well as the menu, so the icon follows
    // the state rather than being set by whichever control was clicked.
    NotificationCenter.default.addObserver(
      forName: .clipFlowCaptureStateChanged, object: nil, queue: .main
    ) { [weak self] _ in
      self?.updateStatusIcon()
    }

    panel = Panel(size: NSSize(width: 420, height: 400), onClose: { [weak self] in
      self?.statusItem.button?.isHighlighted = false
    }) {
      HistoryView(onClose: { [weak self] in self?.panel.close() })
    }

    KeyboardShortcuts.onKeyUp(for: .toggleHistory) { [weak self] in
      self?.toggle()
    }

    for (index, name) in KeyboardShortcuts.Name.pasteSlots.enumerated() {
      KeyboardShortcuts.onKeyUp(for: name) { [weak self] in
        self?.pasteSlot(index + 1)
      }
    }

    // Touching .shared here is what runs the migrations, before the first copy
    // can arrive and try to insert into a table that doesn't exist yet.
    _ = Database.shared
    _ = History.shared
    // FR-2.5: `retentionLimit` may have been lowered since the last run, and
    // nothing else would bring the history back under it until the next copy.
    ItemRepository.evictBeyondRetentionLimit()
    ImageStore.sweepOrphans(referencedBy: ItemRepository.imagePaths())
    PasteboardMonitor.shared.start()
    // FR-4.5: a queue interrupted by quitting left rows at 'pending'.
    OCRQueue.shared.wake()
    // FR-5.1: rows copied before link detection existed have never been scanned,
    // and a history with no link glyphs anywhere looks like the feature is off.
    URLDetector.backfill()
    registerLaunchAtLoginOnce()
    // FR-5.4: paste degrading to copy is a silent difference, and the grant can
    // vanish on its own (a rebuild with a different signature, a macOS update).
    // One line at launch makes "why did it stop pasting" answerable from the log.
    NSLog("ClipFlow: accessibility \(Paster.isTrusted ? "granted, paste enabled" : "not granted, paste falls back to copy")")
  }

  /// A clipboard manager that isn't running has lost history you can never get
  /// back, so this is on by default rather than opt-in — but exactly once.
  ///
  /// FR-7.7 makes it a toggle, and a launch that re-registers unconditionally
  /// would undo the user's choice on the next restart, which is precisely the
  /// restart the setting exists to control. The flag records that the offer was
  /// made; after that, the Settings toggle owns the state.
  private func registerLaunchAtLoginOnce() {
    // The unbundled `make debug` binary has no bundle identity to register.
    guard Bundle.main.bundleIdentifier != nil else { return }
    guard !UserDefaults.standard.bool(forKey: Preferences.didRegisterLaunchAtLoginKey) else {
      NSLog("ClipFlow: launch at login status \(LaunchAtLogin.status.rawValue) (user-controlled)")
      return
    }
    UserDefaults.standard.set(true, forKey: Preferences.didRegisterLaunchAtLoginKey)

    LaunchAtLogin.set(true)
    // register() succeeding does not mean it's on: macOS commonly parks the
    // request at .requiresApproval and waits for the user in System Settings.
    // Saying so beats appearing to work and then not surviving a reboot.
    switch LaunchAtLogin.status {
    case .enabled:
      NSLog("ClipFlow: launch at login enabled")
    case .requiresApproval:
      NSLog("ClipFlow: launch at login needs approval in System Settings > General > Login Items")
    case .notFound:
      NSLog("ClipFlow: launch at login unavailable — app not found (running unbundled?)")
    default:
      NSLog("ClipFlow: launch at login status \(LaunchAtLogin.status.rawValue)")
    }
  }

  /// FR-7.4 wants the paused state visible without opening anything, and
  /// `appearsDisabled` is the system's own rendering of "this control is off" —
  /// unlike `isEnabled`, which would also stop the button responding to clicks
  /// and strand the user with no way to un-pause.
  ///
  /// The filled glyph for FR-7.3 is a second state, not a second control: armed
  /// and paused can both be true, and dimming already carries paused.
  private func updateStatusIcon() {
    let monitor = PasteboardMonitor.shared
    let symbol = monitor.ignoresNextCapture ? "clipboard.fill" : "clipboard"
    // Falling back rather than assigning nil: a status item with no image is an
    // invisible status item, and the app would look like it had quit.
    let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "ClipFlow")
      ?? NSImage(systemSymbolName: "clipboard", accessibilityDescription: "ClipFlow")
    // Template images follow the menu bar's light/dark appearance for free.
    image?.isTemplate = true

    statusItem.button?.image = image
    statusItem.button?.appearsDisabled = monitor.isPaused
    statusItem.button?.toolTip = switch (monitor.isPaused, monitor.ignoresNextCapture) {
    case (true, _): "ClipFlow — capture paused"
    case (false, true): "ClipFlow — the next copy will be ignored"
    case (false, false): "ClipFlow"
    }
  }

  /// FR-5.2's `Option+N`: paste the item in that pin slot without the panel ever
  /// appearing. Same `Clipboard.copy` + `Paster.paste` pair the panel's
  /// Option+Enter uses — there is one paste path, and HP-2's timing and FR-5.4's
  /// copy-only fallback both live in it.
  ///
  /// An empty slot does nothing. Pasting the wrong item into a document because
  /// slot 4 happens to be free is worse than a shortcut that appears inert.
  @MainActor private func pasteSlot(_ slot: Int) {
    guard let itemID = ItemRepository.pinnedItemID(slot: slot) else { return }
    // Nothing of ours is on screen in the normal case, so frontmost is already
    // the app to paste into. Closing first covers the case where the panel is
    // open — it holds key focus, and DECISIONS S-12's capture must not see it.
    panel.close()
    Paster.captureTargetApp()
    Clipboard.copy(itemID: itemID)
    Paster.paste()
  }

  @objc private func statusItemClicked() {
    // Right-click opens the menu; left-click opens the history. Assigning
    // `statusItem.menu` instead would make the menu appear on *both*, costing the
    // one-click path to the thing the app is for.
    if NSApp.currentEvent?.type == .rightMouseUp {
      showMenu()
      return
    }
    // FR-7.3's modifier click. Option, not Command or Control: Command-dragging a
    // status item is how macOS lets you rearrange the menu bar, and Control-click
    // is a right-click, which is already the menu. It toggles rather than only
    // arming, so a click made by accident is undone by another click — the menu
    // item is the discoverable route, this is the fast one.
    if NSApp.currentEvent?.modifierFlags.contains(.option) == true {
      toggleIgnoreNextCopy()
      return
    }
    toggle()
  }

  private func toggle() {
    panel.toggle(below: statusItem.button)
    statusItem.button?.isHighlighted = panel.isPresented
  }

  private func showMenu() {
    panel.close()

    let menu = NSMenu()
    func add(_ title: String, _ action: Selector, checked: Bool = false) {
      let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
      item.target = self
      item.state = checked ? .on : .off
      menu.addItem(item)
    }

    // FR-5.4's explanation alert fires once and then never again, so without a
    // standing entry there is no way back to the permission after dismissing it.
    // Hidden when granted — a permanently visible "enable" for something already
    // enabled reads as broken.
    if !Paster.isTrusted {
      add("Enable Pasting…", #selector(enablePasting))
      menu.addItem(.separator())
    }

    let monitor = PasteboardMonitor.shared
    // FR-7.4 and FR-7.3. Checkmarks rather than a title that flips between
    // "Pause" and "Resume": the menu is also where you come to find out which
    // state you are in, and a verb only tells you what will happen next.
    add("Pause Capture", #selector(togglePause), checked: monitor.isPaused)
    add("Ignore Next Copy", #selector(toggleIgnoreNextCopy), checked: monitor.ignoresNextCapture)
    menu.addItem(.separator())
    // Bulk actions, ordered by how much they take away. Unpinning is reversible
    // by re-pinning and deletes nothing, so it sits above the two that do — and
    // it is the only one without an ellipsis, because it does not ask.
    add("Unpin All", #selector(unpinAll))
    add("Clear Unpinned History…", #selector(clearUnpinnedHistory))
    add("Clear All History…", #selector(clearAllHistory))
    menu.addItem(.separator())
    add("Settings…", #selector(openSettings))
    menu.addItem(.separator())
    let quit = NSMenuItem(title: "Quit ClipFlow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    menu.addItem(quit)

    // Attaching, popping, then detaching: leaving `menu` set would hijack
    // left-click too.
    statusItem.menu = menu
    statusItem.button?.performClick(nil)
    statusItem.menu = nil
  }

  @MainActor @objc private func enablePasting() {
    Paster.openAccessibilitySettings()
  }

  @objc private func togglePause() {
    PasteboardMonitor.shared.setPaused(!PasteboardMonitor.shared.isPaused)
  }

  @objc private func toggleIgnoreNextCopy() {
    let monitor = PasteboardMonitor.shared
    monitor.setIgnoresNextCapture(!monitor.ignoresNextCapture)
  }

  @MainActor @objc private func openSettings() {
    SettingsWindow.shared.show()
  }

  /// Unpinning deletes nothing — the rows stay in the history and only lose
  /// their slot — so it does not carry a confirmation. Silent when nothing is
  /// pinned, because an alert saying "nothing happened" is worse than nothing
  /// happening.
  @objc private func unpinAll() {
    ItemRepository.unpinAll()
  }

  /// FR-7.5, first of two. Irreversible and unbounded, so it confirms — and says
  /// how much is about to go, because "clear history" reads very differently at
  /// 3 items than at 900. Naming what *survives* is the point of this one: it is
  /// the only thing that distinguishes it from the action underneath it.
  @objc private func clearUnpinnedHistory() {
    let counts = ItemRepository.counts()
    let unpinned = counts.total - counts.pinned
    guard confirm(
      "Clear unpinned clipboard history?",
      detail: "\(Self.items(unpinned)) and any stored images will be permanently deleted. "
        + (counts.pinned == 0 ? "Nothing is pinned." : "\(Self.items(counts.pinned)) pinned will be kept."),
      action: "Clear Unpinned"
    ) else { return }
    ItemRepository.deleteUnpinned()
  }

  /// FR-7.5, second of two. Pins are named separately in the text: a user who
  /// pinned nine things does not expect them in scope, and this is the action
  /// where they are.
  @objc private func clearAllHistory() {
    let counts = ItemRepository.counts()
    guard confirm(
      "Clear all clipboard history?",
      detail: "\(Self.items(counts.total)) and any stored images will be permanently deleted"
        + (counts.pinned == 0 ? "." : ", including \(Self.items(counts.pinned)) pinned."),
      action: "Clear Everything"
    ) else { return }
    ItemRepository.deleteAll()
  }

  private func confirm(_ message: String, detail: String, action: String) -> Bool {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = message
    alert.informativeText = detail
    alert.addButton(withTitle: action)
    alert.addButton(withTitle: "Cancel")
    alert.buttons.first?.hasDestructiveAction = true

    // An .accessory app has no windows to bring forward, so without this the
    // alert can open behind whatever the user was looking at.
    NSApp.activate(ignoringOtherApps: true)
    return alert.runModal() == .alertFirstButtonReturn
  }

  private static func items(_ count: Int) -> String {
    count == 1 ? "1 item" : "\(count) items"
  }
}
