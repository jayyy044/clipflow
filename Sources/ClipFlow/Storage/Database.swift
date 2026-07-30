import Foundation
import GRDB

enum Database {
  static let shared: DatabaseQueue = {
    let dir = URL.applicationSupportDirectory.appending(path: "ClipFlow", directoryHint: .isDirectory)
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

    return migrator
  }
}

enum ItemRepository {
  /// Insert, or bump the existing row when the same content is already the newest
  /// entry. Returns nothing — the UI observes the table rather than the return value.
  static func save(_ item: Item) {
    var item = item
    try? Database.shared.write { db in
      if var newest = try Item.recent(limit: 1).fetchOne(db),
         newest.contentHash == item.contentHash {
        newest.lastUsedAt = item.copiedAt
        try newest.update(db)
        return
      }
      try item.insert(db)
    }
  }

  static func deleteAll() {
    try? Database.shared.write { db in
      _ = try Item.deleteAll(db)
    }
  }
}
