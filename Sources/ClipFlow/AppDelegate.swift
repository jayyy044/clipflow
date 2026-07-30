import AppKit
import KeyboardShortcuts
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
    statusItem.button?.action = #selector(toggle)
    statusItem.button?.target = self
    statusItem.menu = nil

    panel = Panel(size: NSSize(width: 420, height: 400), onClose: { [weak self] in
      self?.statusItem.button?.isHighlighted = false
    }) {
      HistoryView(onClose: { [weak self] in self?.panel.close() })
    }

    KeyboardShortcuts.onKeyUp(for: .toggleHistory) { [weak self] in
      self?.toggle()
    }

    // Touching .shared here is what runs the migrations, before the first copy
    // can arrive and try to insert into a table that doesn't exist yet.
    _ = Database.shared
    _ = History.shared
    PasteboardMonitor.shared.start()
  }

  @objc private func toggle() {
    panel.toggle(below: statusItem.button)
    statusItem.button?.isHighlighted = panel.isPresented
  }
}
