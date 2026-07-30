import AppKit

enum Clipboard {
  /// Puts an item back on the system clipboard, ready for the user to paste with
  /// Cmd+V themselves.
  ///
  /// Deliberately does not synthesize the Cmd+V keystroke. That needs
  /// Accessibility permission, which needs a stable code signing identity, and
  /// neither is worth blocking on — FR-5.4 treats copy-only as a legitimate
  /// state, not a half-built one.
  @MainActor
  static func copy(itemID: Int64) {
    guard let item = ItemRepository.item(id: itemID) else { return }

    // Resolved before clearContents(): a missing image file would otherwise leave
    // the user's pasteboard emptied.
    let payload: (Data, NSPasteboard.PasteboardType)
    switch item.kind {
    case .image:
      // Written as image data, not a path, so it pastes into Preview as a picture.
      guard let path = item.imagePath, let data = ImageStore.data(for: path) else { return }
      payload = (data, .png)
    case .text:
      guard let content = item.content else { return }
      payload = (Data(content.utf8), .string)
    }

    let pasteboard = NSPasteboard.general
    // clearContents() returns the resulting change count. Handing it to the
    // monitor is what stops our own write being captured as a fresh copy, which
    // would insert a duplicate row and reshuffle the list on every use.
    let changeCount = pasteboard.clearContents()
    pasteboard.setData(payload.0, forType: payload.1)
    PasteboardMonitor.shared.ignore(changeCount: changeCount)

    // Using an old item floats it back to the top, since ordering is
    // max(copied_at, last_used_at).
    ItemRepository.markUsed(id: itemID)
  }
}
