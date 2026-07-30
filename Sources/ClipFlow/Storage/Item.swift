import Foundation
import GRDB

/// One captured clipboard entry.
///
/// Text-only for now. Image and file columns arrive with Phase 6 as a migration —
/// GRDB's migrator makes adding them a non-event, so they aren't scaffolded here.
struct Item: Codable, Identifiable, Hashable, FetchableRecord, MutablePersistableRecord {
  var id: Int64?
  var content: String
  var preview: String
  var sourceBundleID: String?
  var sourceAppName: String?
  /// Unix epoch **milliseconds**. Seconds would make same-second ordering
  /// arbitrary and the list would flicker between queries (DECISIONS S-6).
  var copiedAt: Int64
  var lastUsedAt: Int64?
  var contentHash: String

  static let databaseTableName = "items"

  // Spelled out rather than using convertToSnakeCase/convertFromSnakeCase: those
  // two are not inverses across an acronym. `sourceBundleID` encodes to
  // `source_bundle_id` but decodes back as `sourceBundleId`, which silently
  // misses the property and yields nil — and the dedupe path then writes that
  // nil over a good row. Explicit keys can't drift.
  enum CodingKeys: String, CodingKey {
    case id
    case content
    case preview
    case sourceBundleID = "source_bundle_id"
    case sourceAppName = "source_app_name"
    case copiedAt = "copied_at"
    case lastUsedAt = "last_used_at"
    case contentHash = "content_hash"
  }

  mutating func didInsert(_ inserted: InsertionSuccess) {
    id = inserted.rowID
  }

  /// Sort key. Re-copying an old item has to float it back to the top, so
  /// ordering uses whichever of the two timestamps is newer (DECISIONS S-5).
  var sortedAt: Int64 { max(copiedAt, lastUsedAt ?? copiedAt) }

  var copiedAtDate: Date { Date(timeIntervalSince1970: Double(copiedAt) / 1000) }
}

extension Item {
  /// Newest first. `id DESC` breaks ties so the order is total, not arbitrary.
  static func recent(limit: Int = 500) -> SQLRequest<Item> {
    """
    SELECT * FROM items
    ORDER BY MAX(copied_at, COALESCE(last_used_at, copied_at)) DESC, id DESC
    LIMIT \(limit)
    """
  }
}
