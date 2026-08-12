import AppKit
import CryptoKit
import Foundation
import GRDB
import Security

/// The vault's stand-in for a test target, per the design's "Self-check"
/// section. There is no test target and this does not add one; the asserts run
/// as a command-line flag against a scratch database so they can be run against
/// the *signed bundle*, which is the only build whose entitlements and Secure
/// Enclave access match what the user actually runs.
///
/// Nothing here touches the user's data directory, the pasteboard, or the real
/// vault keys — the scratch data directory below is where the probe's key blob
/// lands, and it is deleted on the way out.
enum VaultSelfCheck {
  private static var failures = 0

  private static func check(_ label: String, _ body: () throws -> Bool) {
    do {
      if try body() {
        print("ok    \(label)")
      } else {
        failures += 1
        print("FAIL  \(label)")
      }
    } catch {
      failures += 1
      print("FAIL  \(label) — threw \(error)")
    }
  }

  static func run() -> Never {
    // Redirected before anything reads `Database.directory`, which is a lazy
    // global: the first touch of `Database.shared` below is what resolves it.
    // `Database` only honours the override when it resolves under a scratch
    // root, so this path is not incidentally the user's history.
    let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
      .appending(path: "clipflow-selfcheck-\(UUID().uuidString)", directoryHint: .isDirectory)
    setenv("CLIPFLOW_DATA_DIR", scratch.path, 1)

    // 0. Does the Secure Enclave design work for this app as signed?
    //    Everything in Unit A rests on it, now that V-6 is reversed: the
    //    data-protection keychain refuses an under-entitled process with
    //    errSecMissingEntitlement (-34018) and the legacy keychain hands the
    //    value key back with no prompt at all. So the keys are wrapped to SEP
    //    keys instead, and this creates one, writes it, reads it back and
    //    rebuilds it in-process.
    //
    //    The *name* key, which has no user-presence ACL — so this raises no
    //    sheet and runs headless. The value key's Touch ID path cannot be
    //    verified from here and is deliberately not asserted: headless, its key
    //    agreement fails with -1009, which is the gate working.
    let sep = VaultKeys.probeSecureEnclave()
    check("Secure Enclave key create/persist/reconstruct — \(sep ?? "ok")") { sep == nil }

    // 1 & 2. AES-GCM: it round-trips, and a tampered box is refused rather than
    //        opened into garbage or, worse, into empty text that reads as an
    //        entry worth deleting. Keys are generated here, not fetched, so no
    //        Touch ID sheet and no real vault key is created.
    let key = SymmetricKey(size: .bits256)
    let secret = "self-check value ünïcode 🔐 4111-1111-1111-1111"
    let sealed = (try? VaultCrypto.seal(secret, using: key)) ?? Data()

    check("seal then open round-trips") { try VaultCrypto.open(sealed, using: key) == secret }

    check("tampered sealed blob throws") {
      guard !sealed.isEmpty else { return false }
      var tampered = Data(sealed)
      tampered[tampered.index(before: tampered.endIndex)] ^= 0xFF
      do {
        _ = try VaultCrypto.open(tampered, using: key)
        return false
      } catch {
        return true
      }
    }

    // 3. The one that matters: a vault entry must not reach `items_fts`. This
    //    is what catches a future "simplification" that folds `vault_entries`
    //    back onto `items`, where the v4 triggers would index every secret in
    //    plaintext (design V-2).
    //
    //    Asked as a MATCH rather than a row count, because `items_fts` is an
    //    external-content table: `SELECT COUNT(*) FROM items_fts` reads the
    //    *content* table and would answer even with an empty index. A MATCH
    //    goes to the index itself.
    let needle = "clipflowselfcheckneedle"
    let now = Int64(Date().timeIntervalSince1970 * 1000)

    check("inserting a vault entry leaves items_fts empty") {
      var entry = VaultEntry(
        id: nil,
        sealedName: try VaultCrypto.seal("name \(needle)", using: key),
        sealedValue: try VaultCrypto.seal("value \(needle)", using: key),
        createdAt: now,
        updatedAt: now
      )
      guard VaultRepository.save(&entry), entry.id != nil else { return false }
      guard let items = scalar("SELECT COUNT(*) FROM items"), items == 0 else { return false }
      return ftsMatches(needle) == 0
    }

    // The control for the check above. Without it, an `items_fts` that had
    // simply stopped working would make assertion 3 pass for the wrong reason
    // and keep passing forever.
    check("control: an items row does reach items_fts") {
      Database.write("self-check items insert") { db in
        try db.execute(
          sql: "INSERT INTO items (kind, content, preview, copied_at, content_hash) VALUES ('text', ?, ?, ?, ?)",
          arguments: ["a row containing \(needle)", "preview", now, "selfcheckhash"]
        )
      } != nil && ftsMatches(needle) == 1
    }

    // 4. Unit B set `PRAGMA secure_delete=ON` through `config.prepareDatabase`
    //    and explicitly could not verify it took effect. Reading it back off a
    //    live connection is that verification. 1 is ON, 2 is FAST, 0 is off.
    check("PRAGMA secure_delete is in effect on the live connection") {
      (scalar("PRAGMA secure_delete") ?? 0) != 0
    }

    // 5. The `.keyLost` branch, which had never executed before this assertion
    //    existed and was otherwise only reachable by four manual GUI steps.
    //
    //    A key file that has gone missing while `vault_entries` still has rows
    //    in it means those rows can never be opened again. Minting a
    //    replacement raises no Touch ID sheet — wrapping only needs the Enclave
    //    key's public half — so an Unlock would report success, and the
    //    overwrite would be the last chance anyone had of noticing. Hence both
    //    halves below: it must throw, *and* no key blob may appear on disk.
    //    Throwing after minting would still be a silent overwrite.
    //
    //    Runs last because it deletes the key the probe in assertion 0 created,
    //    and reuses the vault entry assertion 3 inserted.
    check("a missing key file over a non-empty vault throws keyLost and mints nothing") {
      guard (VaultRepository.count() ?? 0) > 0 else { return false }
      guard !keyFiles().isEmpty else { return false }
      for file in keyFiles() {
        try FileManager.default.removeItem(at: Database.directory.appending(path: file))
      }

      do {
        _ = try VaultKeys.nameKey()
        return false  // returned a key rather than refusing
      } catch VaultKeys.Failure.keyLost {
        // The required outcome. Anything else propagates and reports as a throw.
      }
      return keyFiles().isEmpty
    }

    // GAP — assertion 5 of the design's self-check, deliberately absent:
    //   "Export then import under a different pair of device keys reproduces
    //    the same names and values, and a wrong passphrase fails cleanly."
    // `VaultTransfer` (Unit C) does not exist at the time of writing, so there
    // is nothing to call. Add it here when it lands; do not consider the
    // self-check complete until then.

    try? FileManager.default.removeItem(at: scratch)

    print(failures == 0 ? "\nvault self-check passed" : "\nvault self-check FAILED (\(failures))")
    exit(failures == 0 ? 0 : 1)
  }

  /// The vault key blobs sitting in the scratch data directory. Named by suffix
  /// rather than spelled out, so a third key file added later is deleted — and
  /// noticed if it reappears — by the assertion above without editing it.
  private static func keyFiles() -> [String] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: Database.directory.path)) ?? []
    return names.filter { $0.hasSuffix(".key") }
  }

  /// Nil means the read failed, which every caller treats as a failed assertion
  /// rather than as a zero.
  private static func scalar(_ sql: String) -> Int? {
    Database.read("self-check scalar") { db in try Int.fetchOne(db, sql: sql) } ?? nil
  }

  /// How many rows the full-text index returns for a token. `-1` on a failed
  /// read, so it can never be mistaken for "clean".
  private static func ftsMatches(_ token: String) -> Int {
    let count = Database.read("self-check fts match") { db in
      try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM items_fts WHERE items_fts MATCH ?", arguments: [token])
    }
    return (count ?? nil) ?? -1
  }
}

// Before AppKit, before the pasteboard monitor, before anything opens the real
// database — this exits and never returns.
if CommandLine.arguments.contains("--vault-self-check") {
  VaultSelfCheck.run()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Equivalent of LSUIElement, but works when running the bare SPM executable too:
// menu bar only, no Dock icon, no app menu.
app.setActivationPolicy(.accessory)
app.run()
