import AppKit
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

  /// The one file every branch of `shared` below is trying to open. Named here
  /// because `isEphemeral` has to compare against it.
  static let path: String = directory.appending(path: "clipflow.sqlite").path

  /// Whether `shared` is the in-memory fallback rather than that file — the
  /// last branch below, taken when the open failed for a reason that was not
  /// corruption. The user's real database is intact on disk and simply
  /// invisible for this session, which makes every count read off it a count of
  /// nothing rather than a count of what is there.
  ///
  /// That distinction is not cosmetic anywhere a zero authorises an action.
  /// `VaultKeys.masterKey` mints a fresh master key only when `vault_entries`
  /// is empty, and here it reads empty over a vault full of rows it cannot see;
  /// minting then overwrites the only key those rows can be opened with.
  ///
  /// Compared against the intended path rather than against SQLite's
  /// `":memory:"`, so anything unexpected reads as ephemeral. That is the safe
  /// direction: a false "ephemeral" costs a refusal the user can retry next
  /// launch, a false "real" costs the vault.
  static var isEphemeral: Bool { shared.path != path }

  /// Opening the database used to `fatalError`, which in a menu-bar app with no
  /// Dock icon reads as "the icon stopped appearing" and repeats on every launch:
  /// a corrupt WAL, a disk full during a migration, or a bug in a future
  /// migration bricked the app permanently with nothing on screen saying why.
  ///
  /// So instead: open, and if that fails move the existing files aside to
  /// `clipflow.sqlite.corrupt-<stamp>` and open a fresh one. Nothing is deleted
  /// or overwritten — the quarantined set is a complete database the user can
  /// move back — because a clipboard history is not reconstructible and neither
  /// are the images `images.noindex` still holds for it (DECISIONS D-15). The
  /// alert names both paths for that reason: it is the only instruction the user
  /// gets for recovering the old file, and the sweep will not touch those images
  /// while their rows are missing, since it only ever runs after a write.
  ///
  /// If the fresh open fails too — the disk-full case, where the rename can
  /// succeed and the create still cannot — the app runs on an in-memory queue.
  /// Capture works for this session and nothing persists, which is worse than
  /// working and better than an app that will not start.
  static let shared: DatabaseQueue = {
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let failure: Error
    do { return try openMigrated(at: path) } catch { failure = error }
    NSLog("ClipFlow: could not open \(path): \(failure)")

    // Only genuine corruption earns a quarantine. Every other reason an open can
    // fail is about the machine rather than the file — a full disk, a volume that
    // went away, another process holding a lock, or a bug in a migration running
    // against a perfectly good database. Renaming the history aside in those cases
    // would be the worst outcome available: the fault clears on its own, and the
    // user reopens to an empty ClipFlow with their real history sitting under a
    // name they have to read an alert to discover. Degraded-but-intact is the
    // better failure, so anything unrecognised falls through to the in-memory
    // branch below and leaves the file exactly where it is.
    if indicatesCorruption(failure), let quarantined = quarantine(path),
       let queue = try? openMigrated(at: path) {
      report("""
        The existing database could not be opened, so it was moved aside and a new, \
        empty one was created. Your old history has not been deleted:

        \(quarantined)

        Images for it are still in \(ImageStore.directory.path). Quit ClipFlow before \
        moving either file back.
        """)
      return queue
    }

    report("""
      No database could be opened or created at \(path). \
      Nothing copied during this session will be saved, and your existing history \
      has been left untouched. Check that the disk is not full, then quit and \
      reopen ClipFlow.
      """)
    // Only fails if SQLite cannot allocate at all, at which point there is no
    // degraded mode left to fall back to.
    let memory = try! DatabaseQueue()
    try? migrator.migrate(memory)
    return memory
  }()

  /// Whether SQLite is telling us the *file* is bad, as opposed to the conditions
  /// around it. `SQLITE_CORRUPT` is a malformed image and `SQLITE_NOTADB` is a
  /// file that is not a database at all — both mean reopening will fail forever,
  /// which is what makes moving it aside worth doing. `SQLITE_BUSY`,
  /// `SQLITE_CANTOPEN`, `SQLITE_IOERR` and `SQLITE_FULL` all describe a machine
  /// having a bad moment, and every one of them can clear by itself.
  ///
  /// Deliberately a allowlist rather than a denylist: an unrecognised error means
  /// we do not know what is wrong, and "do not touch the user's only copy" is the
  /// right default for not knowing.
  private static func indicatesCorruption(_ error: Error) -> Bool {
    guard let dbError = error as? DatabaseError else { return false }
    let code = dbError.resultCode.primaryResultCode
    return code == .SQLITE_CORRUPT || code == .SQLITE_NOTADB
  }

  private static func openMigrated(at path: String) throws -> DatabaseQueue {
    // GRDB only enables WAL automatically for DatabasePool, not DatabaseQueue,
    // so this has to be explicit. Fewer fsyncs per write and no rewrite-the-
    // whole-journal stall, which matters because we write on every copy.
    var config = Configuration()
    config.journalMode = .wal
    // Overwrites freed pages with zeroes instead of leaving them readable in the
    // file. Moving an item out of history and into `vault_entries` would
    // otherwise leave its plaintext sitting in the freelist of a file that is
    // backed up and synced.
    //
    // Known gap, deliberately not solved here: WAL means deleted content can
    // still persist in the `-wal` file until a checkpoint. Do not add a
    // checkpoint-on-delete without measuring what it costs the capture path,
    // which writes on every copy.
    config.prepareDatabase { db in
      try db.execute(sql: "PRAGMA secure_delete=ON")
    }

    let queue = try DatabaseQueue(path: path, configuration: config)
    try migrator.migrate(queue)
    return queue
  }

  /// Renames the database out of the way, siblings included: a `-wal` left
  /// behind would be replayed into the new file, which is how "recover from
  /// corruption" turns into corrupting the replacement. Returns the new path, or
  /// nil if there was nothing to move or the move itself failed — in which case
  /// the caller must not assume a clean slate.
  private static func quarantine(_ path: String) -> String? {
    let fm = FileManager.default
    guard fm.fileExists(atPath: path) else { return nil }

    let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
    let target = "\(path).corrupt-\(stamp)"
    do {
      try fm.moveItem(atPath: path, toPath: target)
    } catch {
      NSLog("ClipFlow: could not quarantine \(path): \(error)")
      return nil
    }
    for suffix in ["-wal", "-shm"] {
      try? fm.moveItem(atPath: path + suffix, toPath: target + suffix)
    }
    NSLog("ClipFlow: quarantined unreadable database to \(target)")
    return target
  }

  /// Async on the main queue because this runs inside a lazy global initializer
  /// that any thread may be the first to touch, and NSAlert is main-thread only.
  /// Deferring also keeps the modal out of the middle of `applicationDidFinishLaunching`.
  private static func report(_ detail: String) {
    NSLog("ClipFlow: \(detail)")
    DispatchQueue.main.async {
      let alert = NSAlert()
      alert.alertStyle = .critical
      alert.messageText = "ClipFlow could not open its clipboard history"
      alert.informativeText = detail
      NSApp.activate(ignoringOtherApps: true)
      alert.runModal()
    }
  }

  /// One place for every write, because the alternative — `try?` at each call
  /// site — is what made a failed write indistinguishable from a successful one.
  /// The result is optional so callers that care can tell; the NSLog is so the
  /// ones that don't still leave a trace.
  @discardableResult
  static func write<T>(_ label: String, _ body: (GRDB.Database) throws -> T) -> T? {
    do {
      return try shared.write(body)
    } catch {
      NSLog("ClipFlow: \(label) failed: \(error)")
      return nil
    }
  }

  /// Same for reads. A failed read is usually recoverable by retrying later, but
  /// silently reading zero rows is how a count in a confirmation alert ends up
  /// lying about what is on disk.
  static func read<T>(_ label: String, _ body: (GRDB.Database) throws -> T) -> T? {
    do {
      return try shared.read(body)
    } catch {
      NSLog("ClipFlow: \(label) failed: \(error)")
      return nil
    }
  }

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

    // The vault (design V-2). Its own table rather than a flag on `items`,
    // because the FTS triggers above fire on `items` and would write every
    // secret into `items_fts` in plaintext — which is the one thing this table
    // exists to avoid.
    //
    // **No FTS trigger and no index here, both on purpose.** Ciphertext is not
    // tokenizable and not orderable, so an index would only cost writes; the
    // list sorts in memory after the names decrypt. Adding either would be a
    // regression, not a fix.
    //
    // ponytail: in-memory sort of decrypted names, fine to ~1000 entries
    migrator.registerMigration("v9_vault") { db in
      try db.create(table: "vault_entries") { t in
        t.autoIncrementedPrimaryKey("id")
        t.column("sealed_name", .blob).notNull()
        t.column("sealed_value", .blob).notNull()
        t.column("created_at", .integer).notNull()
        t.column("updated_at", .integer).notNull()
      }
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
  ///
  /// A dedupe hit on an image row whose file is gone is *repaired* rather than
  /// merely bumped: the caller has just written a fresh copy of the identical
  /// bytes, so the row is adopted onto the new path instead of a second row
  /// being inserted for content that already has one. Repair rather than
  /// insert-and-delete because the row's identity is worth keeping — its pin
  /// slot, its "first seen" `copied_at`, and its id, which the panel may have
  /// selected.
  static func save(_ item: Item) {
    var item = item
    Database.write("save") { db in
      if var existing = try Item
        .filter(Column("content_hash") == item.contentHash)
        .fetchOne(db)
      {
        existing.lastUsedAt = item.copiedAt
        if let path = item.imagePath, isDeadImageRow(existing) {
          existing.imagePath = path
          // Identical bytes by definition — same hash — so a `done` row's OCR
          // text still describes the new file and re-reading it would be work
          // for an identical answer. `failed`, though, is very often failed
          // *because* the file was missing when the queue reached it
          // (`pixelSize` returns nil and FR-4.3 makes that terminal), so the
          // repair is the one moment that verdict is worth reopening.
          if existing.ocrStatus == .failed { existing.ocrStatus = .pending }
          NSLog("ClipFlow: repaired image row \(existing.id.map(String.init) ?? "?") onto \(path)")
        }
        try existing.update(db)
        return
      }
      try item.insert(db)
    }
    evictBeyondRetentionLimit()
  }

  /// An image row whose PNG is not on disk. It renders, it can be selected, and
  /// it does nothing — and because dedupe is global on `content_hash`
  /// (DECISIONS D-5b), re-copying the very screenshot that would fix it used to
  /// count as a hit and leave it dead forever.
  private static func isDeadImageRow(_ item: Item) -> Bool {
    guard item.kind == .image, let path = item.imagePath else { return false }
    return !ImageStore.exists(path)
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
    let evicted = Database.write("eviction") { db -> Int in
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

  /// Bumps an existing row by hash, reporting whether it found a *usable* one.
  ///
  /// `save` already dedupes, but an image has to be written to disk *before* it
  /// can be described as an Item — so re-copying the same screenshot would write
  /// several megabytes only to discard them. This is the check that runs first.
  ///
  /// False for a row whose image file has gone missing, which is what makes such
  /// a row repairable at all: the caller short-circuits on true, so a hit there
  /// meant `ImageStore.save` never ran and the only copy that could have restored
  /// the file was thrown away by the dedupe that the missing file caused. False
  /// sends the caller on to write the bytes and call `save`, which adopts this
  /// same row onto the new path — so it does not become a duplicate, and the
  /// UNIQUE index on `content_hash` is never offered a second row.
  static func bump(contentHash: String, at timestamp: Int64) -> Bool {
    let bumped = Database.write("bump") { db -> Bool in
      guard var existing = try Item
        .filter(Column("content_hash") == contentHash)
        .fetchOne(db)
      else { return false }
      guard !isDeadImageRow(existing) else { return false }
      existing.lastUsedAt = timestamp
      try existing.update(db)
      return true
    }
    return bumped ?? false
  }

  /// Fetches the full payload for one item. The list deliberately never loads
  /// `content`, so this is where it gets read — one row, on demand.
  static func item(id: Int64) -> Item? {
    Database.read("item(id:)") { db in
      try Item.withID(id).fetchOne(db)
    } ?? nil
  }

  /// Everything the images directory is allowed to keep (DECISIONS S-17).
  ///
  /// A failed read used to return the empty set, and the empty set is the exact
  /// argument that tells `sweepOrphans` every file on disk is an orphan — one
  /// unreadable page and every image is deleted, which D-15 records as the
  /// unrecoverable half of this app's data. So on failure it names every file
  /// that is already there instead: the sweep then matches everything, keeps
  /// everything, and the next successful sweep collects whatever was really
  /// orphaned.
  static func imagePaths() -> Set<String> {
    let paths = Database.read("imagePaths") { db in
      try String.fetchAll(db, sql: "SELECT image_path FROM items WHERE image_path IS NOT NULL")
    }
    if let paths { return Set(paths) }
    let names = (try? FileManager.default.contentsOfDirectory(atPath: ImageStore.directory.path)) ?? []
    return Set(names.map { "\(ImageStore.directory.lastPathComponent)/\($0)" })
  }

  /// The next image waiting for OCR, newest first — a fresh screenshot becomes
  /// searchable while a backlog is still draining, rather than after it.
  static func nextPendingOCR() -> (id: Int64, imagePath: String)? {
    let row = Database.read("nextPendingOCR") { db in
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
    Database.write("finishOCR") { db in
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
    let ids = Database.read("idsMissingURLDetection") { db in
      try Int64.fetchAll(db, sql: "SELECT id FROM items WHERE kind = 'text' AND detected_urls IS NULL")
    }
    return ids ?? []
  }

  static func setDetectedURLs(id: Int64, json: String) {
    Database.write("setDetectedURLs") { db in
      try db.execute(sql: "UPDATE items SET detected_urls = ? WHERE id = ?", arguments: [json, id])
    }
  }

  /// Slots are 1..9 because that is how many `Option+1..9` can address
  /// (FR-5.2). A pinned row always holds one — see `togglePin`.
  static let pinSlots = 1...9

  /// What `togglePin` did, so the caller can say so. `slotsFull` and `failed`
  /// are the outcomes the user cannot see for themselves.
  ///
  /// `failed` exists because a failed write used to be reported as `slotsFull`,
  /// which told the user all nine slots were taken when they were not — a
  /// specific, checkable claim about a state that isn't true, and one that sends
  /// them to unpin something to make room for a write that would have failed
  /// anyway (DECISIONS D-14).
  enum PinResult {
    case pinned(slot: Int)
    case unpinned
    case slotsFull
    case failed
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
    let result = Database.write("togglePin") { db -> PinResult in
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
    return result ?? .failed
  }

  /// Resolves one of FR-5.2's `Option+1..9` to the row it pastes. Nil when the
  /// slot is empty, which is the common case for most of the nine — the shortcut
  /// then does nothing rather than pasting something arbitrary.
  static func pinnedItemID(slot: Int) -> Int64? {
    Database.read("pinnedItemID") { db in
      try Int64.fetchOne(db, sql: "SELECT id FROM items WHERE pin_slot = ?", arguments: [slot])
    } ?? nil
  }

  /// A best-effort bump: if it fails the item just does not float to the top,
  /// which is why nothing is propagated and the log line is the whole response.
  static func markUsed(id: Int64) {
    let now = Int64(Date().timeIntervalSince1970 * 1000)
    Database.write("markUsed") { db in
      try db.execute(sql: "UPDATE items SET last_used_at = ? WHERE id = ?", arguments: [now, id])
    }
  }

  /// Deletes one item and any file it owned.
  ///
  /// The sweep runs after the row is gone, so it sees the real remaining
  /// references — deleting the file first would strand the row if the write
  /// failed, and computing the reference set first would race the delete. It is
  /// skipped entirely when the delete failed, since nothing became orphaned.
  ///
  /// Returns whether the row is actually gone. The user asked for this one, so
  /// "it didn't work" is theirs to know — but the alert belongs to the caller,
  /// not here.
  @discardableResult
  static func delete(id: Int64) -> Bool {
    let ok = Database.write("delete(id:)") { db in
      try db.execute(sql: "DELETE FROM items WHERE id = ?", arguments: [id])
    } != nil
    guard ok else { return false }
    ImageStore.sweepOrphans(referencedBy: imagePaths())
    return true
  }

  /// The only bulk clear, and it never touches pinned rows. A
  /// delete-everything-including-pinned variant existed and was removed: two
  /// near-identically named destructive menu entries invite picking the wrong
  /// one. `unpinAll()` then this reaches the same end state in two steps that
  /// each say what they do.
  ///
  /// Callers confirm first. The sweep runs against what is left rather than the
  /// empty set, so pinned rows keep their images.
  ///
  /// Returns whether the clear happened, and this is the one return value here
  /// that is not optional politeness: the user read a count, clicked Clear, and
  /// walked away believing the history is gone. If the write failed it is all
  /// still there, and that is a privacy outcome rather than a cosmetic one, so
  /// the caller has to be able to say so.
  @discardableResult
  static func deleteUnpinned() -> Bool {
    let ok = Database.write("deleteUnpinned") { db in
      try db.execute(sql: "DELETE FROM items WHERE pinned = 0")
    } != nil
    guard ok else { return false }
    ImageStore.sweepOrphans(referencedBy: imagePaths())
    return true
  }

  /// Clears every pin and its slot, keeping the rows. Not destructive — nothing
  /// is deleted and no image is swept — so it does not confirm. A no-op with
  /// nothing pinned, because the UPDATE simply matches no rows.
  static func unpinAll() {
    Database.write("unpinAll") { db in
      try db.execute(sql: "UPDATE items SET pinned = 0, pin_slot = NULL WHERE pinned = 1")
    }
  }

  /// What the confirmation alerts name. Counted in SQLite rather than off
  /// `History.shared.items`, which is capped at 500 rows and holds search
  /// results whenever the panel was last used to search — either would make the
  /// alert understate what is about to go.
  ///
  /// **Nil means the count is unknown, and it is not the same as zero.** A
  /// failed read used to come back as `(0, 0)`, so the alert offered to clear
  /// "0 items", the user confirmed that, and `deleteUnpinned()` then ran against
  /// everything there actually was. A destructive action confirmed against a
  /// number the user was shown and that was wrong is the one outcome a
  /// confirmation exists to prevent, so the failure has to be visible to the
  /// caller. Callers must bail out of the confirmation on nil rather than
  /// substitute a number.
  static func counts() -> (total: Int, pinned: Int)? {
    guard let row = Database.read("counts", { db in
      try Row.fetchOne(db, sql: "SELECT COUNT(*) AS total, COALESCE(SUM(pinned), 0) AS pinned FROM items")
    }) ?? nil else { return nil }
    return (row["total"], row["pinned"])
  }
}
