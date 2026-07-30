import AppKit
import KeyboardShortcuts
import ServiceManagement
import SwiftUI

extension KeyboardShortcuts.Name {
  /// Ctrl+Cmd+V. Two modifiers that both suppress text input, so it still fires
  /// inside password fields (PRD HP-4) — Option+J would emit `∆` and get
  /// swallowed there. Ctrl+Cmd is near-empty territory on macOS: only F
  /// (fullscreen), Q (lock screen), and Space (emoji picker) are taken.
  /// Rebindable in Settings once Phase 9 exists.
  ///
  /// Gotcha: KeyboardShortcuts writes this default into UserDefaults on first
  /// launch, and a stored value then wins forever. Editing the line below will
  /// appear to do nothing on a machine that has already run the app — clear it
  /// with `defaults delete ClipFlow KeyboardShortcuts_toggleHistory` first.
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
  /// Carbon hot key wins system-wide with no Settings UI to rebind it yet.
  /// Ctrl+Cmd emits nothing and matches the toggle hotkey.
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
    statusItem.button?.image = NSImage(
      systemSymbolName: "clipboard",
      accessibilityDescription: "ClipFlow"
    )
    // Template images follow the menu bar's light/dark appearance for free.
    statusItem.button?.image?.isTemplate = true
    statusItem.button?.action = #selector(statusItemClicked)
    statusItem.button?.target = self
    statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

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
    enableLaunchAtLogin()
    // FR-5.4: paste degrading to copy is a silent difference, and the grant can
    // vanish on its own (a rebuild with a different signature, a macOS update).
    // One line at launch makes "why did it stop pasting" answerable from the log.
    NSLog("ClipFlow: accessibility \(Paster.isTrusted ? "granted, paste enabled" : "not granted, paste falls back to copy")")
  }

  /// A clipboard manager that isn't running has lost history you can never get
  /// back, so this is on by default rather than opt-in. Phase 9's Settings pane
  /// gets a toggle; until then, turn it off in System Settings > General >
  /// Login Items.
  private func enableLaunchAtLogin() {
    // The unbundled `make debug` binary has no bundle identity to register.
    guard Bundle.main.bundleIdentifier != nil else { return }

    let service = SMAppService.mainApp
    guard service.status != .enabled else {
      NSLog("ClipFlow: launch at login already enabled")
      return
    }
    do {
      try service.register()
    } catch {
      // Not fatal — the app still works, it just won't come back after a reboot.
      NSLog("ClipFlow: could not enable launch at login: \(error.localizedDescription)")
      return
    }
    // register() succeeding does not mean it's on: macOS commonly parks the
    // request at .requiresApproval and waits for the user in System Settings.
    // Saying so beats appearing to work and then not surviving a reboot.
    switch service.status {
    case .enabled:
      NSLog("ClipFlow: launch at login enabled")
    case .requiresApproval:
      NSLog("ClipFlow: launch at login needs approval in System Settings > General > Login Items")
    case .notFound:
      NSLog("ClipFlow: launch at login unavailable — app not found (running unbundled?)")
    default:
      NSLog("ClipFlow: launch at login status \(service.status.rawValue)")
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
    } else {
      toggle()
    }
  }

  private func toggle() {
    panel.toggle(below: statusItem.button)
    statusItem.button?.isHighlighted = panel.isPresented
  }

  private func showMenu() {
    panel.close()

    let menu = NSMenu()
    // FR-5.4's explanation alert fires once and then never again, so without a
    // standing entry there is no way back to the permission after dismissing it.
    // Hidden when granted — a permanently visible "enable" for something already
    // enabled reads as broken.
    if !Paster.isTrusted {
      let enable = NSMenuItem(title: "Enable Pasting…", action: #selector(enablePasting), keyEquivalent: "")
      enable.target = self
      menu.addItem(enable)
      menu.addItem(.separator())
    }
    let clear = NSMenuItem(title: "Clear History…", action: #selector(clearHistory), keyEquivalent: "")
    clear.target = self
    menu.addItem(clear)
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

  /// FR-7.5. Irreversible and unbounded, so it confirms — and says how much is
  /// about to go, because "clear history" reads very differently at 3 items than
  /// at 900.
  @objc private func clearHistory() {
    let count = History.shared.items.count

    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Clear all clipboard history?"
    alert.informativeText = count == 1
      ? "1 item and any stored images will be permanently deleted."
      : "\(count) items and any stored images will be permanently deleted."
    alert.addButton(withTitle: "Clear")
    alert.addButton(withTitle: "Cancel")
    alert.buttons.first?.hasDestructiveAction = true

    // An .accessory app has no windows to bring forward, so without this the
    // alert can open behind whatever the user was looking at.
    NSApp.activate(ignoringOtherApps: true)
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    ItemRepository.deleteAll()
  }
}
