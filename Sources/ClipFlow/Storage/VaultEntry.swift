import Foundation
import GRDB

/// One vault secret. Both the name and the value are AES-GCM sealed boxes
/// (`sealedBox.combined`) — nothing on this row is readable from the file, which
/// is the point of keeping it out of `items` (design V-2).
///
/// The two blobs are sealed under *different* keys: the name key has no access
/// control, so a locked vault can still list real names, while the value key is
/// `.userPresence` and only comes back after Touch ID (V-1). Sealing, opening
/// and the keys themselves belong to `VaultSession` — this file only stores
/// bytes and never sees plaintext.
struct VaultEntry: Codable, Identifiable, Hashable, FetchableRecord, MutablePersistableRecord {
  var id: Int64?
  var sealedName: Data
  var sealedValue: Data
  /// Unix epoch **milliseconds**, matching `Item.copiedAt` — same reason
  /// (DECISIONS S-6): seconds make same-second ordering arbitrary.
  var createdAt: Int64
  var updatedAt: Int64

  static let databaseTableName = "vault_entries"

  // Spelled out for the same reason `Item`'s are: convertToSnakeCase and
  // convertFromSnakeCase are not inverses, and a key that silently misses its
  // property here would write a nil blob over a secret that cannot be recovered
  // from anywhere else.
  enum CodingKeys: String, CodingKey {
    case id
    case sealedName = "sealed_name"
    case sealedValue = "sealed_value"
    case createdAt = "created_at"
    case updatedAt = "updated_at"
  }

  mutating func didInsert(_ inserted: InsertionSuccess) {
    id = inserted.rowID
  }
}

enum VaultRepository {
  /// Insert or update, depending on whether `entry.id` is set. Returns whether
  /// the row is really on disk — a vault write that quietly failed would look
  /// exactly like a saved secret until the user next needed it.
  @discardableResult
  static func save(_ entry: inout VaultEntry) -> Bool {
    var copy = entry
    let ok = Database.write("vault save") { db in
      try copy.save(db)
    } != nil
    entry = copy
    return ok
  }

  /// Every entry, oldest first — `id` only so the order is total and stable.
  /// The *displayed* order is decided after the names decrypt, in memory, since
  /// ciphertext does not sort.
  ///
  /// **Nil means the read failed, not that the vault is empty**, following
  /// `ItemRepository.counts()`'s precedent: an empty vault and an unreadable one
  /// look identical to a caller that substitutes `[]`, and "your vault is empty"
  /// is a lie a user acts on. Callers must show an error rather than an empty
  /// list.
  static func all() -> [VaultEntry]? {
    Database.read("vault all") { db in
      try VaultEntry.order(Column("id")).fetchAll(db)
    }
  }

  /// One entry by id. Nil covers both "no such row" and "read failed" — unlike
  /// `all()`, the two are equivalent here: there is nothing to render either way
  /// and no destructive decision hangs off the difference.
  static func entry(id: Int64) -> VaultEntry? {
    Database.read("vault entry(id:)") { db in
      try VaultEntry.fetchOne(db, key: id)
    } ?? nil
  }

  /// Returns whether the row is actually gone. The user asked for this one, so
  /// a failure is theirs to know; the alert belongs to the caller.
  @discardableResult
  static func delete(id: Int64) -> Bool {
    Database.write("vault delete(id:)") { db in
      try db.execute(sql: "DELETE FROM vault_entries WHERE id = ?", arguments: [id])
    } != nil
  }

  /// **Nil means unknown, not zero** — same rule as `all()` and for the same
  /// reason `ItemRepository.counts()` has it: a zero invented by a failed read
  /// is what let a destructive confirmation run against a full table.
  static func count() -> Int? {
    Database.read("vault count") { db in
      try VaultEntry.fetchCount(db)
    }
  }
}
