import AppKit

enum Clipboard {
  /// Puts an item back on the system clipboard. `Paster.paste()` is what then
  /// makes another app take it; on its own this is the context menu's Copy — the
  /// only deliberate copy-without-paste left after DECISIONS D-22 — and FR-5.4's
  /// copy-only fallback when pasting isn't permitted.
  ///
  /// `plainText` is FR-5.2's Shift+Enter: it writes the string alone, so
  /// the receiving app has no rich representation to take. A normal copy writes
  /// both, so formatting survives a round trip through the history. For an item
  /// captured without RTF — most of them — the two are identical, and for image
  /// items the flag is ignored: PNG is written either way.
  ///
  /// Returns whether the pasteboard was actually written. The two early returns
  /// below leave the *previous* clipboard contents in place, which is the right
  /// call on its own (see the comment on `payload`) but is indistinguishable from
  /// success to a caller that goes straight on to `Paster.paste()` — it would
  /// paste whatever the user copied before, into the document they are editing,
  /// with no sign anything went wrong. Since this app stores everything copied,
  /// that stale item can be a password. So every caller that pastes must gate the
  /// paste on this, and the failure is logged rather than staying silent.
  @MainActor
  @discardableResult
  static func copy(itemID: Int64, plainText: Bool = false) -> Bool {
    guard let item = ItemRepository.item(id: itemID) else {
      // Normal enough to not be an error: retention or a Clear can evict a row
      // between the list rendering it and the user pressing Return on it.
      NSLog("ClipFlow: item \(itemID) is gone — nothing copied")
      return false
    }

    // Resolved before clearContents(): a missing image file would otherwise leave
    // the user's pasteboard emptied.
    let payload: [(Data, NSPasteboard.PasteboardType)]
    switch item.kind {
    case .image:
      // Written as image data, not a path, so it pastes into Preview as a picture.
      guard let path = item.imagePath, let data = ImageStore.data(for: path) else {
        NSLog("ClipFlow: image file missing for item \(itemID) — nothing copied")
        return false
      }
      payload = [(data, .png)]
    case .text:
      guard let content = item.content else {
        NSLog("ClipFlow: text item \(itemID) has no content — nothing copied")
        return false
      }
      // Richest first. A reader takes the first declared type it understands, so
      // RTF written after the string would never be chosen and FR-5.2's two
      // paste actions would collapse back into one.
      let rtf = plainText ? nil : item.rtfData
      payload = (rtf.map { [($0, NSPasteboard.PasteboardType.rtf)] } ?? []) + [(Data(content.utf8), .string)]
    }

    let pasteboard = NSPasteboard.general
    // clearContents() returns the resulting change count. Handing it to the
    // monitor is what stops our own write being captured as a fresh copy, which
    // would insert a duplicate row and reshuffle the list on every use.
    let changeCount = pasteboard.clearContents()
    for (data, type) in payload {
      pasteboard.setData(data, forType: type)
    }
    PasteboardMonitor.shared.ignore(changeCount: changeCount)

    // Using an old item floats it back to the top, since ordering is
    // max(copied_at, last_used_at). Only reached on the success path — a copy that
    // never wrote the pasteboard is not a use, and floating it to the top would
    // reward the failure by making the broken row easier to hit again.
    ItemRepository.markUsed(id: itemID)
    return true
  }
}
