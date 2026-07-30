import AppKit
import SwiftUI

extension Notification.Name {
  static let clipFlowPanelDidOpen = Self("clipFlowPanelDidOpen")
}

/// Spotlight-style floating panel that shows without stealing focus from the app
/// you were typing in — that app has to stay frontmost so Phase 4 can paste back
/// into it.
///
/// Window configuration adapted from Maccy's `FloatingPanel.swift`
/// (MIT, Copyright (c) 2025 Alex Rodionov) — https://github.com/p0deje/Maccy
final class Panel<Content: View>: NSPanel {
  private var onClose: () -> Void

  init(size: NSSize, onClose: @escaping () -> Void, @ViewBuilder view: () -> Content) {
    self.onClose = onClose

    super.init(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )

    animationBehavior = .none
    isFloatingPanel = true
    // Chrome's autofill popup sits at window level 999; screenSaver (1000) clears
    // it while still covering status items. Maccy issue #1403.
    level = .screenSaver
    collectionBehavior = [.auxiliary, .stationary, .moveToActiveSpace, .fullScreenAuxiliary]
    titleVisibility = .hidden
    titlebarAppearsTransparent = true
    titlebarSeparatorStyle = .none
    isMovableByWindowBackground = true
    hidesOnDeactivate = false
    standardWindowButton(.closeButton)?.isHidden = true
    standardWindowButton(.miniaturizeButton)?.isHidden = true
    standardWindowButton(.zoomButton)?.isHidden = true

    contentView = NSHostingView(rootView: view().ignoresSafeArea())
  }

  var isPresented: Bool { isVisible }

  func toggle(below statusButton: NSStatusBarButton?) {
    isPresented ? close() : open(below: statusButton)
  }

  func open(below statusButton: NSStatusBarButton?) {
    // Rows keep whatever relative timestamp they rendered with, because SwiftUI
    // skips re-rendering rows whose data hasn't changed. Announcing the open lets
    // the list re-date itself instead of showing "now" for a minute-old item.
    NotificationCenter.default.post(name: .clipFlowPanelDidOpen, object: nil)
    setFrameOrigin(origin(below: statusButton))
    // orderFrontRegardless, not makeKeyAndOrderFront — the latter would activate
    // ClipFlow and we'd lose the frontmost app we need to paste into.
    orderFrontRegardless()
    makeKey()
  }

  override func close() {
    super.close()
    onClose()
  }

  /// Anchored under the menu bar icon, falling back to centred on the active
  /// screen when the icon isn't on screen (hidden by a notch, or Bartender).
  private func origin(below statusButton: NSStatusBarButton?) -> NSPoint {
    if let window = statusButton?.window {
      let button = window.convertToScreen(statusButton!.bounds)
      return NSPoint(x: button.midX - frame.width / 2, y: button.minY - frame.height)
    }
    guard let visible = NSScreen.main?.visibleFrame else { return .zero }
    return NSPoint(
      x: visible.midX - frame.width / 2,
      y: visible.midY - frame.height / 2
    )
  }

  // Without this the search field can never take keyboard focus.
  override var canBecomeKey: Bool { true }

  // Clicking away closes it, same as Spotlight.
  override func resignKey() {
    super.resignKey()
    close()
  }
}
