import AppKit
import Foundation
import GRDB

/// One captured clipboard entry.
///
/// `kind='file'` is still unresolved (DECISIONS, known conflicts), so the enum
/// has two cases and the column has no CHECK constraint that a third would have
/// to rebuild the table to widen.
enum ItemKind: String, Codable {
  case text
  case image
}

struct Item: Codable, Identifiable, Hashable, FetchableRecord, MutablePersistableRecord {
  var id: Int64?
  var kind: ItemKind = .text
  /// Nil for image rows — their bytes are on disk, never in SQLite (FR-2.2).
  var content: String?
  var preview: String
  /// Relative to `Database.directory`. Nil for text rows.
  var imagePath: String?
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
    case kind
    case content
    case preview
    case imagePath = "image_path"
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
  ///
  /// Selects `content`, so this is for the dedupe check and for resolving a
  /// single item on paste — never for populating the list. See `ItemSummary`.
  static func recent(limit: Int = 500) -> SQLRequest<Item> {
    """
    SELECT * FROM items
    ORDER BY \(sql: orderBy)
    LIMIT \(limit)
    """
  }

  static func withID(_ id: Int64) -> SQLRequest<Item> {
    "SELECT * FROM items WHERE id = \(id)"
  }

  static let orderBy = "MAX(copied_at, COALESCE(last_used_at, copied_at)) DESC, id DESC"
}

/// What the list renders — everything except `content`.
///
/// `content` is capped at 1 MB per item, so observing 500 full rows could hold
/// half a gigabyte resident to draw a list that only ever displays `preview`.
/// The full payload is fetched by id at the moment it's actually needed.
struct ItemSummary: Codable, Identifiable, Hashable, FetchableRecord {
  var id: Int64
  var kind: ItemKind
  var preview: String
  var imagePath: String?
  var sourceBundleID: String?
  var sourceAppName: String?
  var copiedAt: Int64
  var lastUsedAt: Int64?

  enum CodingKeys: String, CodingKey {
    case id
    case kind
    case preview
    case imagePath = "image_path"
    case sourceBundleID = "source_bundle_id"
    case sourceAppName = "source_app_name"
    case copiedAt = "copied_at"
    case lastUsedAt = "last_used_at"
  }

  /// The thumbnail generated at insert time, not the original — FR-6.7 forbids
  /// the list ever touching a full-resolution file.
  var thumbnail: NSImage? {
    guard kind == .image, let imagePath else { return nil }
    return ImageStore.thumbnail(for: imagePath)
  }

  /// The timestamp the row is *sorted* by, and therefore the one it must
  /// display. Showing `copied_at` while ordering by this is what put a "53m ago"
  /// row at the top of the list.
  var lastActivityDate: Date {
    Date(timeIntervalSince1970: Double(max(copiedAt, lastUsedAt ?? copiedAt)) / 1000)
  }

  static func recent(limit: Int = 500) -> SQLRequest<ItemSummary> {
    """
    SELECT id, kind, preview, image_path, source_bundle_id, source_app_name, copied_at, last_used_at
    FROM items
    ORDER BY \(sql: Item.orderBy)
    LIMIT \(limit)
    """
  }
}
