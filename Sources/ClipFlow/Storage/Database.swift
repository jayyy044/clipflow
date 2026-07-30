import Foundation
import GRDB

enum Database {
  /// Also the root that `image_path` is relative to (FR-2.2), which is why it's
  /// named here rather than inlined into the queue's initializer.
  static let directory = URL.applicationSupportDirectory.appending(path: "ClipFlow", directoryHint: .isDirectory)

  static let shared: DatabaseQueue = {
    let dir = directory
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    do {
      // GRDB only enables WAL automatically for DatabasePool, not DatabaseQueue,
      // so this has to be explicit. Fewer fsyncs per write and no rewrite-the-
      // whole-journal stall, which matters because we write on every copy.
      var config = Configuration()
      config.journalMode = .wal

      let queue = try DatabaseQueue(
        path: dir.appending(path: "clipflow.sqlite").path,
        configuration: config
      )
      try migrator.migrate(queue)
      return queue
    } catch {
      fatalError("Cannot open database: \(error)")
    }
  }()

  static var migrator: DatabaseMigrator {
    var migrator = DatabaseMigrator()

    migrator.registerMigration("v1_items") { db in
      try db.create(table: "items") { t in
        t.autoIncrementedPrimaryKey("id")
        t.column("content", .text).notNull()
        t.column("preview", .text).notNull()
        t.column("source_bundle_id", .text)
        t.column("source_app_name", .text)
        t.column("copied_at", .integer).notNull()
        t.column("last_used_at", .integer)
        t.column("content_hash", .text).notNull()
      }
      try db.create(index: "idx_items_copied_at", on: "items", columns: ["copied_at"])
      try db.create(index: "idx_items_hash", on: "items", columns: ["content_hash"])
    }

    // FR-1.3 only deduped against the newest row, so copying A, then B, then A
    // again produced two rows for A. Dedupe is now global: the same content can
    // only ever occupy one row, whenever it was last seen.
    migrator.registerMigration("v2_global_dedupe") { db in
      // Collapse existing duplicates before the unique index can reject them.
      // Carry the newest activity onto the survivor so nothing moves backwards.
      try db.execute(sql: """
        UPDATE items SET last_used_at = (
          SELECT MAX(COALESCE(o.last_used_at, o.copied_at))
          FROM items o WHERE o.content_hash = items.content_hash
        )
        WHERE content_hash IN (
          SELECT content_hash FROM items GROUP BY content_hash HAVING COUNT(*) > 1
        )
        """)
      // Keep the earliest row of each group, so copied_at stays "first seen".
      try db.execute(sql: """
        DELETE FROM items WHERE id NOT IN (SELECT MIN(id) FROM items GROUP BY content_hash)
        """)

      try db.drop(index: "idx_items_hash")
      try db.create(index: "idx_items_hash", on: "items", columns: ["content_hash"], unique: true)
    }

    // Image rows carry no text payload, so `content` has to become nullable.
    // SQLite cannot ALTER a column's nullability, hence the full table rebuild.
    // Storing '' instead would have dodged this and then poisoned Clipboard.copy
    // and the Phase 3 FTS index with empty documents.
    migrator.registerMigration("v3_images") { db in
      try db.create(table: "items_new") { t in
        t.autoIncrementedPrimaryKey("id")
        t.column("kind", .text).notNull().defaults(to: "text")
        t.column("content", .text)
        t.column("preview", .text).notNull()
        t.column("image_path", .text)
        t.column("source_bundle_id", .text)
        t.column("source_app_name", .text)
        t.column("copied_at", .integer).notNull()
        t.column("last_used_at", .integer)
        t.column("content_hash", .text).notNull()
      }
      try db.execute(sql: """
        INSERT INTO items_new
          (id, kind, content, preview, source_bundle_id, source_app_name, copied_at, last_used_at, content_hash)
        SELECT id, 'text', content, preview, source_bundle_id, source_app_name, copied_at, last_used_at, content_hash
        FROM items
        """)
      // Both indexes belong to the old table and go away with it, so both have
      // to come back — including the UNIQUE one that enforces global dedupe
      // (DECISIONS D-5b).
      try db.drop(table: "items")
      try db.rename(table: "items_new", to: "items")
      try db.create(index: "idx_items_copied_at", on: "items", columns: ["copied_at"])
      try db.create(index: "idx_items_hash", on: "items", columns: ["content_hash"], unique: true)
    }

    return migrator
  }
}

enum ItemRepository {
  /// Insert, or bump whichever existing row already holds this content —
  /// anywhere in the history, not just the newest one. Bumping `last_used_at`
  /// floats it back to the top, since ordering is max(copied_at, last_used_at).
  static func save(_ item: Item) {
    var item = item
    try? Database.shared.write { db in
      if var existing = try Item
        .filter(Column("content_hash") == item.contentHash)
        .fetchOne(db)
      {
        existing.lastUsedAt = item.copiedAt
        try existing.update(db)
        return
      }
      try item.insert(db)
    }
  }

  /// Bumps an existing row by hash, reporting whether it found one.
  ///
  /// `save` already dedupes, but an image has to be written to disk *before* it
  /// can be described as an Item — so re-copying the same screenshot would write
  /// several megabytes only to discard them. This is the check that runs first.
  static func bump(contentHash: String, at timestamp: Int64) -> Bool {
    let changes = try? Database.shared.write { db -> Int in
      try db.execute(
        sql: "UPDATE items SET last_used_at = ? WHERE content_hash = ?",
        arguments: [timestamp, contentHash]
      )
      return db.changesCount
    }
    return (changes ?? 0) > 0
  }

  /// Fetches the full payload for one item. The list deliberately never loads
  /// `content`, so this is where it gets read — one row, on demand.
  static func item(id: Int64) -> Item? {
    try? Database.shared.read { db in
      try Item.withID(id).fetchOne(db)
    }
  }

  /// Everything the images directory is allowed to keep (DECISIONS S-17).
  static func imagePaths() -> Set<String> {
    let paths = try? Database.shared.read { db in
      try String.fetchAll(db, sql: "SELECT image_path FROM items WHERE image_path IS NOT NULL")
    }
    return Set(paths ?? [])
  }

  static func markUsed(id: Int64) {
    let now = Int64(Date().timeIntervalSince1970 * 1000)
    try? Database.shared.write { db in
      try db.execute(sql: "UPDATE items SET last_used_at = ? WHERE id = ?", arguments: [now, id])
    }
  }

  // FR-7.5's clear-history actions land in Phase 9 with the Settings pane that
  // calls them. Whatever implements them has to delete the image files too, not
  // only the rows — ImageStore.sweepOrphans(referencedBy:) already does exactly
  // that and the launch sweep is the safety net either way.
}
