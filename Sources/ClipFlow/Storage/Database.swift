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

    // `ocr_text` is created empty and stays empty until Phase 7 fills it. It is
    // here now because an external-content FTS5 table's columns are fixed at
    // creation: adding OCR later would mean dropping the table and rebuilding
    // all three triggers. One extra column now costs nothing.
    migrator.registerMigration("v4_search") { db in
      try db.alter(table: "items") { t in
        t.add(column: "ocr_text", .text)
      }

      // content='items' keeps the text in `items` rather than duplicating it into
      // the index. remove_diacritics 2 so "café" is findable as "cafe".
      try db.execute(sql: """
        CREATE VIRTUAL TABLE items_fts USING fts5(
          content,
          ocr_text,
          content='items',
          content_rowid='id',
          tokenize='unicode61 remove_diacritics 2'
        )
        """)

      // External-content tables are not maintained automatically, and delete and
      // update must use the special 'delete' command carrying the OLD values.
      // Ordinary DELETE triggers leave stale postings behind and search starts
      // returning rows that no longer exist (DECISIONS S-8).
      try db.execute(sql: """
        CREATE TRIGGER items_fts_ai AFTER INSERT ON items BEGIN
          INSERT INTO items_fts(rowid, content, ocr_text)
          VALUES (new.id, new.content, new.ocr_text);
        END
        """)
      try db.execute(sql: """
        CREATE TRIGGER items_fts_ad AFTER DELETE ON items BEGIN
          INSERT INTO items_fts(items_fts, rowid, content, ocr_text)
          VALUES ('delete', old.id, old.content, old.ocr_text);
        END
        """)
      try db.execute(sql: """
        CREATE TRIGGER items_fts_au AFTER UPDATE ON items BEGIN
          INSERT INTO items_fts(items_fts, rowid, content, ocr_text)
          VALUES ('delete', old.id, old.content, old.ocr_text);
          INSERT INTO items_fts(rowid, content, ocr_text)
          VALUES (new.id, new.content, new.ocr_text);
        END
        """)

      // The triggers only fire from here on, so everything already stored has to
      // be indexed once.
      try db.execute(sql: "INSERT INTO items_fts(items_fts) VALUES('rebuild')")
    }

    // FR-2.3's OCR state column. A plain ADD COLUMN, not a table rebuild: the
    // rebuild in v3 had to happen because nullability was changing, and doing one
    // here would drop and recreate the FTS triggers for nothing.
    migrator.registerMigration("v5_ocr_status") { db in
      try db.execute(sql: "ALTER TABLE items ADD COLUMN ocr_status TEXT NOT NULL DEFAULT 'na'")
      // Partial index: the queue only ever asks for pending rows, and 'na' is
      // almost every row, so indexing the other three states would be dead weight.
      try db.execute(sql: "CREATE INDEX idx_items_ocr ON items(ocr_status) WHERE ocr_status = 'pending'")
      // Screenshots stored before Phase 7 existed are still worth reading
      // (FR-4.5 picks them up on the next launch).
      try db.execute(sql: "UPDATE items SET ocr_status = 'pending' WHERE kind = 'image'")
    }

    return migrator
  }
}

enum ItemRepository {
  /// FR-2.5's N. Below the PRD's default of 1000 — the one number to change,
  /// here, until Phase 9 owns settings. Eviction converges on the next launch,
  /// so lowering it later cleans up retroactively.
  static let retentionLimit = 100

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
    evictBeyondRetentionLimit()
  }

  /// FR-2.5. Runs after every insert and once at launch, so lowering
  /// `retentionLimit` converges on the next run rather than only as new items
  /// arrive. Not on a timer: nothing changes between writes.
  ///
  /// The OFFSET is over `Item.orderBy` — the list's own ordering — because
  /// anything else would evict a row still visible near the top. Deleting by
  /// subquery rather than fetching candidates keeps the history off the heap
  /// (DECISIONS D-9).
  ///
  /// TODO(Phase 9): pinned rows are never evicted (FR-2.5). There is no `pinned`
  /// column yet; when there is, exclude it from the subquery *and* from the
  /// count, or a full set of pins would evict everything else.
  static func evictBeyondRetentionLimit() {
    let evicted = try? Database.shared.write { db -> Int in
      try db.execute(sql: """
        DELETE FROM items WHERE id IN (
          SELECT id FROM items
          ORDER BY \(Item.orderBy)
          LIMIT -1 OFFSET \(retentionLimit)
        )
        """)
      return db.changesCount
    }
    // Same order as `delete(id:)`: rows first, then sweep against what is
    // actually left. Skipped when nothing went, so an ordinary copy does not pay
    // for a directory listing.
    guard (evicted ?? 0) > 0 else { return }
    ImageStore.sweepOrphans(referencedBy: imagePaths())
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

  /// The next image waiting for OCR, newest first — a fresh screenshot becomes
  /// searchable while a backlog is still draining, rather than after it.
  static func nextPendingOCR() -> (id: Int64, imagePath: String)? {
    let row = try? Database.shared.read { db in
      try Row.fetchOne(db, sql: """
        SELECT id, image_path FROM items
        WHERE ocr_status = 'pending' AND image_path IS NOT NULL
        ORDER BY id DESC LIMIT 1
        """)
    }
    guard let row = row ?? nil else { return nil }
    return (row["id"], row["image_path"])
  }

  /// Terminal state for one OCR attempt. The AFTER UPDATE trigger from v4 turns
  /// the written `ocr_text` into FTS postings, which is the whole feature — no
  /// index maintenance belongs here.
  static func finishOCR(id: Int64, text: String?, status: OCRStatus) {
    try? Database.shared.write { db in
      try db.execute(
        sql: "UPDATE items SET ocr_text = ?, ocr_status = ? WHERE id = ?",
        arguments: [text, status.rawValue, id]
      )
    }
  }

  static func markUsed(id: Int64) {
    let now = Int64(Date().timeIntervalSince1970 * 1000)
    try? Database.shared.write { db in
      try db.execute(sql: "UPDATE items SET last_used_at = ? WHERE id = ?", arguments: [now, id])
    }
  }

  /// Deletes one item and any file it owned.
  ///
  /// The sweep runs after the row is gone, so it sees the real remaining
  /// references — deleting the file first would strand the row if the write
  /// failed, and computing the reference set first would race the delete.
  static func delete(id: Int64) {
    try? Database.shared.write { db in
      try db.execute(sql: "DELETE FROM items WHERE id = ?", arguments: [id])
    }
    ImageStore.sweepOrphans(referencedBy: imagePaths())
  }

  /// FR-7.5's destructive clear. Callers are responsible for confirming first.
  static func deleteAll() {
    try? Database.shared.write { db in
      try db.execute(sql: "DELETE FROM items")
    }
    // With no rows left, every file in the directory is an orphan.
    ImageStore.sweepOrphans(referencedBy: [])
  }
}
