import AppKit
import KeyboardShortcuts
import SwiftUI

/// Shown once, on the first launch that reaches the menu bar.
///
/// A menu bar app with no Dock icon and no window has a real discovery problem:
/// nothing tells you the hotkey, and the one permission it wants is only
/// mentioned at the moment a paste silently degrades into a copy. One screen at
/// the start beats finding out by being confused later.
///
/// Deliberately not a tour. It states the hotkey, what makes the app different,
/// and the one optional permission — then gets out of the way. It never appears
/// again, whichever button is used to dismiss it.
final class WelcomeWindow: NSObject, NSWindowDelegate {
  static let shared = WelcomeWindow()
  static let shownKey = "hasShownWelcome"

  private var window: NSWindow?

  /// No-ops after the first time, and never fires for the unbundled `make debug`
  /// binary — that has no bundle identity, so its permission story is different
  /// and the advice would be wrong.
  static func showIfFirstLaunch() {
    guard Bundle.main.bundleIdentifier != nil else { return }
    guard !UserDefaults.standard.bool(forKey: shownKey) else { return }
    UserDefaults.standard.set(true, forKey: shownKey)
    shared.show()
  }

  func show() {
    if window == nil {
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 460, height: 400),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
      )
      window.title = "Welcome to ClipFlow"
      window.isReleasedWhenClosed = false
      window.delegate = self
      window.center()
      window.contentView = NSHostingView(rootView: WelcomeView { [weak self] in
        self?.window?.close()
      })
      self.window = window
    }
    NSApp.activate(ignoringOtherApps: true)
    window?.makeKeyAndOrderFront(nil)
  }

  /// Same reason SettingsWindow does it: an `.accessory` app with no windows
  /// left still counts as active, and the next copy would be attributed to
  /// ClipFlow rather than to whatever the user is actually typing in.
  func windowWillClose(_ notification: Notification) {
    NSApp.hide(nil)
  }
}

struct WelcomeView: View {
  var onDismiss: () -> Void

  @State private var trusted = Paster.isTrusted

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      VStack(alignment: .leading, spacing: 6) {
        Text("ClipFlow is running in your menu bar")
          .font(.title3.weight(.semibold))
        Text("It keeps what you copy so you can find it again.")
          .foregroundStyle(.secondary)
      }

      row(
        "command",
        "Press \(shortcutDescription) to open it",
        "Then type to search. Enter copies what you picked."
      )
      row(
        "text.viewfinder",
        "Screenshots are searchable too",
        "Text inside an image is read on device, so a word you can see in a screenshot will find it."
      )
      row(
        trusted ? "checkmark.circle" : "hand.raised",
        trusted ? "Pasting is enabled" : "Pasting needs one permission",
        trusted
          ? "Enter or a click pastes straight into the app you were in."
          : "Without it ClipFlow copies and you press Cmd+V yourself. Everything else works either way."
      )

      Spacer(minLength: 0)

      HStack {
        // Nothing here is required, so the dismissal is not a "skip" — the app is
        // already working. Offering the permission without demanding it is the
        // whole point of FR-5.4's copy-only fallback.
        if !trusted {
          Button("Enable Pasting…") {
            Paster.openAccessibilitySettings()
            onDismiss()
          }
        }
        Spacer()
        Button("Done", action: onDismiss)
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(24)
    .frame(width: 460, height: 400)
  }

  /// Read from the live binding rather than hardcoded: the hotkey is rebindable
  /// (FR-6.2), and a welcome screen naming a shortcut the user has already
  /// changed is worse than naming none.
  private var shortcutDescription: String {
    KeyboardShortcuts.getShortcut(for: .toggleHistory).map(String.init(describing:)) ?? "the ClipFlow hotkey"
  }

  private func row(_ symbol: String, _ title: String, _ detail: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: symbol)
        .font(.system(size: 16))
        .foregroundStyle(.secondary)
        .frame(width: 22)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.body.weight(.medium))
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }
}
