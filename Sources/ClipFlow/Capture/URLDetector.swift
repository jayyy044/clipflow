import Foundation

/// FR-5.1's link detection: runs on every text capture, and once at launch over
/// rows stored before the column existed.
///
/// **Phone numbers are deliberately not detected.** FR-5.1 asks for
/// `.phoneNumber` as well, but FR-5.2 defines no phone action and no code path
/// reads such a column — it would cost a second detector pass on every copy to
/// fill a column nothing opens. Already cut in DECISIONS ("Cut from v1");
/// reinstate together with the action, not before.
enum URLDetector {
  /// `NSDataDetector` is an `NSRegularExpression` subclass: immutable after
  /// construction and documented thread-safe, so one instance serves both the
  /// capture path and the backfill task.
  private static let detector = try? NSDataDetector(
    types: NSTextCheckingResult.CheckingType.link.rawValue
  )

  /// S-4 caps stored content at 1 MB, and detection is a regex pass over the
  /// whole string on the capture path — so a megabyte of pasted log would be
  /// scanned synchronously every time it is copied. Measured on link-dense text
  /// (a URL every ~50 characters, the worst case there is): **1.9 M chars takes
  /// 1343 ms, 64k takes 21 ms.** 64k characters is also well past any text a link
  /// is meaningfully *in* — nobody opens the 900th URL of a pasted log.
  static let scanLimit = 64_000

  /// JSON array of absolute strings, in document order.
  ///
  /// `[]` rather than NULL when nothing was found: NULL is reserved to mean
  /// "never scanned", which is what `backfill()` selects on.
  static func json(for content: String) -> String {
    guard let data = try? JSONEncoder().encode(detect(in: content)),
          let json = String(data: data, encoding: .utf8)
    else { return "[]" }
    return json
  }

  static func detect(in content: String) -> [String] {
    guard let detector else { return [] }

    let scanned = String(content.prefix(scanLimit))
    let truncated = scanned.count < content.count
    let range = NSRange(scanned.startIndex..., in: scanned)

    return detector.matches(in: scanned, range: range).compactMap { match in
      // A match that runs into the cut-off is most likely half a URL, and half a
      // URL opens the wrong page rather than no page.
      guard !(truncated && match.range.upperBound == range.length) else { return nil }
      return match.url?.absoluteString
    }
  }

  static func decode(_ json: String?) -> [String] {
    guard let json, let data = json.data(using: .utf8) else { return [] }
    return (try? JSONDecoder().decode([String].self, from: data)) ?? []
  }

  /// Everything copied before this feature existed has no detection, so the whole
  /// history would show zero link glyphs and read as broken. Detection needs
  /// Swift, so it cannot live in the migration — same shape as the OCR queue's
  /// FR-4.5 resume pass instead: fired once at launch, off the main thread, at a
  /// priority that yields to anything the user can see.
  ///
  /// Ids first and then one row at a time, because `content` is up to 1 MB per
  /// row (S-4) and selecting the whole backlog at once would put all of it on the
  /// heap for the duration (DECISIONS D-9).
  static func backfill() {
    Task.detached(priority: .utility) {
      for id in ItemRepository.idsMissingURLDetection() {
        ItemRepository.setDetectedURLs(id: id, json: json(for: ItemRepository.item(id: id)?.content ?? ""))
      }
    }
  }
}
