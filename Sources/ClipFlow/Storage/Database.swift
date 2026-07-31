import Foundation
import GRDB

enum Database {
  /// Also the root that `image_path` is relative to (FR-2.2), which is why it's
  /// named here rather than inlined into the queue's initializer.
  ///
  /// Redirectable to a scratch copy, because PRD §6 says to measure the budgets
  /// at 10k items and there is no honest way to do that against the real
  /// history: 10k rows trips FR-2.5 retention and evicts the user's items and
  /// their image files with them. `URL.applicationSupportDirectory` does *not*
  /// follow `HOME` — that assumption is what destroyed 13 screenshots
  /// (DECISIONS D-15) — so the redirect is explicit, and it is only honoured
  /// when the **resolved** path really is under a scratch root. Ignored, loudly,
  /// otherwise.
  static let directory: URL = {
    let live = URL.applicationSupportDirectory.appending(path: "ClipFlow", directoryHint: .isDirectory)
    guard let override = ProcessInfo.processInfo.environment["CLIPFLOW_DATA_DIR"] else { return live }
    let resolved = URL(fileURLWithPath: override).standardizedFileURL.resolvingSymlinksInPath()
    guard isScratch(resolved) else {
      NSLog("ClipFlow: ignoring CLIPFLOW_DATA_DIR \(resolved.path) — not under a scratch root")
      return live
    }
    NSLog("ClipFlow: using scratch data directory \(resolved.path)")
    return resolved
  }()

  /// Both spellings of "temporary" on macOS: the per-user container
  /// `NSTemporaryDirectory()` hands back, and `/tmp`, which resolves through a
  /// symlink to `/private/tmp` and would fail a naive prefix check.
  private static func isScratch(_ url: URL) -> Bool {
    let roots = [NSTemporaryDirectory(), "/tmp"].map {
      URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path
    }
    return roots.contains { url.path == $0 || url.path.hasPrefix($0 + "/") }
  }

  /// Whether the app is pointed at a scratch copy. Read by the seed command,
  /// which refuses to insert anything anywhere else (DECISIONS D-15).
  static var isScratchDirectory: Bool { isScratch(directory) }

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

    // FR-5.1's link column. A plain ADD COLUMN for the same reason v5 was one:
    // nothing about an existing column changes, and a rebuild would drop and
    // recreate the FTS triggers for nothing.
    //
    // Existing rows stay NULL. Detection is `NSDataDetector`, not SQL, so it
    // cannot happen here — `URLDetector.backfill()` fills them on the next
    // launch, and NULL is what it selects on.
    migrator.registerMigration("v6_detected_urls") { db in
      try db.execute(sql: "ALTER TABLE items ADD COLUMN detected_urls TEXT")
    }

    // FR-2.3's pinning columns. Plain ADD COLUMNs for the same reason v5 and v6
    // were: nothing about an existing column changes, and a rebuild would drop
    // and recreate the FTS triggers for nothing.
    //
    // The partial UNIQUE index is what makes DECISIONS D-3 safe. Option+1..9
    // resolves a slot to exactly one row, so two rows sharing a slot would make
    // the shortcut's target arbitrary. Enforced in SQLite rather than only in
    // `pin(id:)`, for the same reason D-5b's dedupe index is.
    migrator.registerMigration("v7_pinning") { db in
      try db.execute(sql: "ALTER TABLE items ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0")
      try db.execute(sql: "ALTER TABLE items ADD COLUMN pin_slot INTEGER")
      try db.execute(sql: """
        CREATE UNIQUE INDEX idx_items_pin_slot ON items(pin_slot) WHERE pin_slot IS NOT NULL
        """)
    }

    // FR-1.2's rich representation. Plain ADD COLUMN for the same reason v5, v6
    // and v7 were: nothing about an existing column changes, and a rebuild would
    // drop and recreate the FTS triggers for nothing.
    //
    // Not indexed and not in the FTS table: it is written on capture and read
    // only by `Clipboard.copy`, and its text is already in `content`.
    migrator.registerMigration("v8_rtf") { db in
      try db.execute(sql: "ALTER TABLE items ADD COLUMN rtf_data BLOB")
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
  /// FR-2.5: pinned rows are never evicted. `WHERE pinned = 0` sits *inside* the
  /// subquery, which is what excludes them from the OFFSET count as well as from
  /// the delete — retention is "keep the newest N unpinned", not "keep N rows of
  /// which some happen to be pinned". Filtering only the DELETE would let nine
  /// pins silently shorten the history by nine.
  static func evictBeyondRetentionLimit() {
    let evicted = try? Database.shared.write { db -> Int in
      try db.execute(sql: """
        DELETE FROM items WHERE id IN (
          SELECT id FROM items
          WHERE pinned = 0
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

  /// Text rows that predate FR-5.1. NULL means "never scanned" — a scanned row
  /// with no links holds `[]` — so this drains to empty and stays there.
  /// Ids only: see `URLDetector.backfill()` for why the content isn't fetched
  /// alongside.
  static func idsMissingURLDetection() -> [Int64] {
    let ids = try? Database.shared.read { db in
      try Int64.fetchAll(db, sql: "SELECT id FROM items WHERE kind = 'text' AND detected_urls IS NULL")
    }
    return ids ?? []
  }

  static func setDetectedURLs(id: Int64, json: String) {
    try? Database.shared.write { db in
      try db.execute(sql: "UPDATE items SET detected_urls = ? WHERE id = ?", arguments: [json, id])
    }
  }

  /// Slots are 1..9 because that is how many `Option+1..9` can address
  /// (FR-5.2). A pinned row always holds one — see `togglePin`.
  static let pinSlots = 1...9

  /// What `togglePin` did, so the caller can say so. `slotsFull` is the only
  /// outcome the user cannot see for themselves.
  enum PinResult {
    case pinned(slot: Int)
    case unpinned
    case slotsFull
  }

  /// FR-5.2's Option+P, both directions.
  ///
  /// Slot rules, which DECISIONS D-14 records and the PRD left open:
  /// the lowest free slot is taken, so unpinning frees a number the next pin
  /// reuses; a tenth pin is refused rather than pinned without a slot, because a
  /// pin the shortcuts cannot reach is a pin that half works.
  ///
  /// One write transaction: reading the used slots and claiming one has to be
  /// atomic, or two pins in the same millisecond both see the same gap and the
  /// second hits the UNIQUE index.
  @discardableResult
  static func togglePin(id: Int64) -> PinResult {
    let result = try? Database.shared.write { db -> PinResult in
      let isPinned = try Bool.fetchOne(db, sql: "SELECT pinned FROM items WHERE id = ?", arguments: [id])
      guard let isPinned else { return .unpinned }

      if isPinned {
        try db.execute(sql: "UPDATE items SET pinned = 0, pin_slot = NULL WHERE id = ?", arguments: [id])
        return .unpinned
      }

      let used = Set(try Int.fetchAll(db, sql: "SELECT pin_slot FROM items WHERE pin_slot IS NOT NULL"))
      guard let slot = pinSlots.first(where: { !used.contains($0) }) else { return .slotsFull }
      try db.execute(
        sql: "UPDATE items SET pinned = 1, pin_slot = ? WHERE id = ?",
        arguments: [slot, id]
      )
      return .pinned(slot: slot)
    }
    return result ?? .slotsFull
  }

  /// Resolves one of FR-5.2's `Option+1..9` to the row it pastes. Nil when the
  /// slot is empty, which is the common case for most of the nine — the shortcut
  /// then does nothing rather than pasting something arbitrary.
  static func pinnedItemID(slot: Int) -> Int64? {
    try? Database.shared.read { db in
      try Int64.fetchOne(db, sql: "SELECT id FROM items WHERE pin_slot = ?", arguments: [slot])
    } ?? nil
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

  /// The only bulk clear, and it never touches pinned rows. A
  /// delete-everything-including-pinned variant existed and was removed: two
  /// near-identically named destructive menu entries invite picking the wrong
  /// one. `unpinAll()` then this reaches the same end state in two steps that
  /// each say what they do.
  ///
  /// Callers confirm first. The sweep runs against what is left rather than the
  /// empty set, so pinned rows keep their images.
  static func deleteUnpinned() {
    try? Database.shared.write { db in
      try db.execute(sql: "DELETE FROM items WHERE pinned = 0")
    }
    ImageStore.sweepOrphans(referencedBy: imagePaths())
  }

  /// Clears every pin and its slot, keeping the rows. Not destructive — nothing
  /// is deleted and no image is swept — so it does not confirm. A no-op with
  /// nothing pinned, because the UPDATE simply matches no rows.
  static func unpinAll() {
    try? Database.shared.write { db in
      try db.execute(sql: "UPDATE items SET pinned = 0, pin_slot = NULL WHERE pinned = 1")
    }
  }

  /// What the confirmation alerts name. Counted in SQLite rather than off
  /// `History.shared.items`, which is capped at 500 rows and holds search
  /// results whenever the panel was last used to search — either would make the
  /// alert understate what is about to go.
  static func counts() -> (total: Int, pinned: Int) {
    let row = try? Database.shared.read { db in
      try Row.fetchOne(db, sql: "SELECT COUNT(*) AS total, COALESCE(SUM(pinned), 0) AS pinned FROM items")
    }
    guard let row = row ?? nil else { return (0, 0) }
    return (row["total"], row["pinned"])
  }
}
