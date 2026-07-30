import Foundation
import GRDB

enum SearchService {
  /// Turns whatever the user typed into a valid FTS5 MATCH expression.
  ///
  /// This is not optional politeness. FTS5's query language treats `"`, `(`, `*`,
  /// `:`, `-`, `NOT`, `OR` and `NEAR` as syntax, so passing raw input straight to
  /// MATCH makes ordinary developer text — `foo(bar`, `--verbose`, `Optional<T>` —
  /// raise a syntax error rather than return no rows (DECISIONS S-7).
  ///
  /// Each term is wrapped in double quotes, where FTS5 treats everything as
  /// literal, with any embedded quote doubled. A trailing `*` gives the prefix
  /// matching FR-3.2 asks for, so `err` finds `error`.
  ///
  /// Returns nil when there is nothing searchable, which the caller treats as
  /// "show the unfiltered list" rather than "show no results".
  static func ftsQuery(from raw: String) -> String? {
    let terms = raw
      .split(whereSeparator: \.isWhitespace)
      // A term of pure punctuation would become `""*`, which is itself a syntax
      // error. The tokenizer would have discarded it anyway.
      .filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }
      .map { $0.replacingOccurrences(of: "\"", with: "\"\"") }

    guard !terms.isEmpty else { return nil }
    return terms.map { "\"\($0)\"*" }.joined(separator: " ")
  }

  /// Matching rows, best match first.
  ///
  /// bm25 returns a *negative* score where more negative is more relevant, so
  /// plain ascending order puts the best match on top. The column weights favour
  /// `content` over `ocr_text`: a screenshot yields hundreds of OCR words and a
  /// commit hash yields one token, and unweighted length normalisation would let
  /// screenshots crowd out short text items (DECISIONS S-9).
  static func matching(_ query: String, limit: Int = 500) -> SQLRequest<ItemSummary> {
    """
    SELECT i.id, i.kind, i.preview, i.image_path,
           i.source_bundle_id, i.source_app_name, i.copied_at, i.last_used_at
    FROM items i
    JOIN items_fts ON items_fts.rowid = i.id
    WHERE items_fts MATCH \(query)
    ORDER BY bm25(items_fts, 1.0, 0.5),
             MAX(i.copied_at, COALESCE(i.last_used_at, i.copied_at)) DESC,
             i.id DESC
    LIMIT \(limit)
    """
  }
}
