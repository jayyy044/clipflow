import AppKit
import SwiftUI

extension Notification.Name {
  static let clipFlowPanelDidOpen = Self("clipFlowPanelDidOpen")
  static let clipFlowOpenURL = Self("clipFlowOpenURL")
  /// FR-7.3/FR-7.4: pause and ignore-next-copy are each settable from two places
  /// and drawn in two more, so the state is announced rather than polled.
  static let clipFlowCaptureStateChanged = Self("clipFlowCaptureStateChanged")
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
    // The content draws its own rounded glass (`HistoryView`). Without these the
    // window paints an opaque rectangle behind it, so the glass has nothing to
    // refract and the square corners show through the rounded ones.
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
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
    let started = ContinuousClock.now
    // First statement in the method, deliberately: DECISIONS S-12 wants the
    // frontmost app read before anything of ours is on screen. Move this below
    // orderFrontRegardless and paste starts landing in ClipFlow.
    Paster.captureTargetApp()
    // Rows keep whatever relative timestamp they rendered with, because SwiftUI
    // skips re-rendering rows whose data hasn't changed. Announcing the open lets
    // the list re-date itself instead of showing "now" for a minute-old item.
    NotificationCenter.default.post(name: .clipFlowPanelDidOpen, object: nil)
    setFrameOrigin(origin(below: statusButton))
    // orderFrontRegardless, not makeKeyAndOrderFront — the latter would activate
    // ClipFlow and we'd lose the frontmost app we need to paste into.
    orderFrontRegardless()
    makeKey()
    // NFR's "hotkey to window visible". Measured to here rather than to the
    // hotkey handler's return: the window is ordered in and key at this point,
    // which is when the user can actually see and type into it.
    Timing.since(started, "hotkey to window visible")
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

  /// FR-5.2's Cmd+O, handled here rather than in SwiftUI.
  ///
  /// A Command chord is a *key equivalent*: AppKit offers it to the responder
  /// chain and the menu system, and it never reaches SwiftUI's `onKeyPress`.
  /// Three separate SwiftUI bindings for it were written and none of them ever
  /// fired — only the context menu's button worked, and only while that menu was
  /// open. This is where the event actually arrives.
  ///
  /// Only Cmd+O is claimed; everything else falls through to `super` so the
  /// search field keeps Cmd+A, Cmd+C and Cmd+V.
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    guard modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "o" else {
      return super.performKeyEquivalent(with: event)
    }
    NotificationCenter.default.post(name: .clipFlowOpenURL, object: nil)
    return true
  }

  // Without this the search field can never take keyboard focus.
  override var canBecomeKey: Bool { true }

  // Clicking away closes it, same as Spotlight.
  override func resignKey() {
    super.resignKey()
    close()
  }
}
