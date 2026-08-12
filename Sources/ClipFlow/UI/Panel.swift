import AppKit
import SwiftUI

extension Notification.Name {
  static let clipFlowPanelDidOpen = Self("clipFlowPanelDidOpen")
  static let clipFlowOpenURL = Self("clipFlowOpenURL")
  /// FR-7.3/FR-7.4: pause and ignore-next-copy are each settable from two places
  /// and drawn in two more, so the state is announced rather than polled.
  static let clipFlowCaptureStateChanged = Self("clipFlowCaptureStateChanged")
}

/// Keeps the panel on screen while something that owns the keyboard is up.
///
/// The panel closes when it loses key focus — that is what makes it feel like
/// Spotlight, and it is exactly wrong for the vault: a sheet takes key focus from
/// its parent window, so presenting one would close the panel and take the sheet
/// down with it, mid-keystroke, while someone was typing a bank PIN. The Touch ID
/// prompt does the same thing for the same reason.
///
/// A counter rather than a flag, because the two nest: the add sheet is reached
/// through an unlock, and both hold.
///
/// Only `resignKey` consults this. An explicit `close()` — Escape, the status
/// menu, a pin-slot paste — still closes, deliberately: a stuck counter would
/// otherwise leave a panel that can never be dismissed, which is worse than a
/// dismissed sheet. `open(below:)` resets it for the same reason.
@MainActor
enum PanelHold {
  private static var count = 0
  /// The panel to hand focus back to once the last hold is released. Weak: the
  /// panel outlives every hold in practice, but nothing here should keep it alive.
  private(set) static weak var owner: NSWindow?

  static var isHeld: Bool { count > 0 }

  static func acquire() { count += 1 }

  static func release() {
    count = max(0, count - 1)
    // The sheet or the prompt took key focus away and `resignKey` deliberately
    // did nothing about it. Without this the panel stays on screen but deaf.
    if count == 0 { owner?.makeKey() }
  }

  static func reset(owner window: NSWindow?) {
    count = 0
    owner = window
  }
}

extension View {
  /// `sheet(item:)` that keeps the panel from closing underneath it.
  ///
  /// The hold is taken when the binding flips, not in the sheet's `onAppear` —
  /// AppKit orders the sheet in and the panel resigns key before SwiftUI runs the
  /// presented view's appearance callbacks, so an `onAppear` hold would arrive
  /// after the close it was meant to prevent.
  ///
  /// `NSApp.activate` is needed too: the panel is non-activating, and an inactive
  /// app's text field cannot take keyboard input at all.
  func panelSheet<Item: Identifiable, Sheet: View>(
    item: Binding<Item?>,
    @ViewBuilder content: @escaping (Item) -> Sheet
  ) -> some View {
    onChange(of: item.wrappedValue != nil) { _, presented in
      if presented {
        PanelHold.acquire()
        NSApp.activate(ignoringOtherApps: true)
      } else {
        PanelHold.release()
      }
    }
    .sheet(item: item, content: content)
  }
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
    // A hold belongs to one visit. If a sheet ever went away without its release
    // running, the count would otherwise keep the panel open forever.
    PanelHold.reset(owner: self)
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
    // The third of `VaultSession`'s three lock triggers, and the one it could not
    // wire itself: nothing posts a panel-close notification, so the panel says so.
    // Every route out of the panel funnels through here — Escape, focus loss, the
    // status menu, a pin-slot paste — so there is no way to leave a vault unlocked
    // behind a window that is no longer on screen.
    VaultSession.shared.lock()
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

  // Clicking away closes it, same as Spotlight — unless something the user is
  // typing into took the focus on purpose (`PanelHold`).
  override func resignKey() {
    super.resignKey()
    guard !PanelHold.isHeld else { return }
    close()
  }
}
