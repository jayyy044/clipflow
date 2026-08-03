import SwiftUI

extension View {
  /// Liquid Glass where the OS has it, the old material where it does not.
  ///
  /// `glassEffect` is macOS 26 and the package floor is macOS 15
  /// (`Package.swift`), so without this every call site carries its own
  /// `#available` branch. There are two today and the fallback has to stay
  /// correct in both, which is exactly the thing that rots when it is copied.
  ///
  /// Deliberately not applied to every surface. Glass is a *floating* material —
  /// it belongs on things layered over other content, and stacking it on itself
  /// muddies both layers. The panel is a popover over whatever app you were
  /// typing in, so it qualifies; a Settings window does not, and Apple's own
  /// Settings is not glass either.
  @ViewBuilder
  func liquidGlass<S: Shape>(in shape: S) -> some View {
    if #available(macOS 26.0, *) {
      glassEffect(.regular, in: shape)
    } else {
      background(.thinMaterial, in: shape)
    }
  }
}
