import CommonCrypto
import CryptoKit
import Foundation

/// Moving the vault between machines: one sealed file, a passphrase, and nothing
/// device-bound inside it.
///
/// **The device keys are never written to the file** (V-8). The export is sealed
/// under a key derived from a passphrase and from nothing else — writing the
/// vault's master keys into the file would make the file equivalent to the
/// vault, and the whole point of binding them to the Secure Enclave is that the
/// vault does not travel.
///
/// The other half of that bargain is stated plainly in the design's threat
/// model: whoever holds this file *and* the passphrase holds the entire vault,
/// on any machine, forever. There is no Touch ID on a file. That is inherent to
/// wanting transfer at all, and the mitigations are procedural — explicit action
/// only, never automatic, and a blunt warning at the point of export.
///
/// No AppKit here on purpose: the panels, the acknowledgement step and the
/// warning belong to Settings. This file is the format and the crypto.
enum VaultTransfer {
  // MARK: - Format

  /// `.clipflowvault`, one sealed file rather than an archive (V-7): ZipCrypto is
  /// broken, AES-zip support is patchy, and there is nothing here to archive.
  static let fileExtension = "clipflowvault"

  private static let formatID = "clipflow.vault.export"
  private static let formatVersion = 1
  private static let kdfID = "pbkdf2-hmac-sha256"

  /// OWASP's current PBKDF2-HMAC-SHA256 figure.
  static let iterations = 600_000
  private static let saltCount = 32
  private static let keyCount = 32

  /// Only enforced for a passphrase the user typed. A generated recovery key is
  /// 26 characters and clears it without anyone thinking about it.
  static let minimumPassphraseLength = 12

  /// The header is JSON in the clear, and has to be: the salt and the KDF
  /// parameters are what let the key be derived at all. Publishing them is
  /// standard practice, not a leak — the secret is the passphrase.
  private struct Envelope: Codable {
    var format: String
    var version: Int
    var kdf: String
    var iterations: Int
    /// base64, 32 random bytes.
    var salt: String
    /// base64, the AES-GCM combined box.
    var sealed: String
  }

  /// One secret, in the clear, only ever inside the sealed box or in memory
  /// between decrypting and re-sealing.
  struct Entry: Codable, Equatable {
    var name: String
    var value: String
    /// Unix epoch **milliseconds**, matching `VaultEntry.createdAt`.
    var createdAt: Int64

    enum CodingKeys: String, CodingKey {
      case name, value
      case createdAt = "created_at"
    }
  }

  struct ImportResult {
    /// Rows actually written to `vault_entries`.
    var imported: Int
    /// Entries the vault already had, byte for byte, on both name and value.
    var skipped: Int
  }

  enum Failure: LocalizedError, Equatable {
    /// A file we do not know how to read. Checked before any work happens.
    case unsupportedFormat
    /// Structurally broken — not JSON, or not base64 where base64 was promised.
    case malformed
    /// The GCM tag did not verify. This is the *only* thing the user is told,
    /// deliberately: no partial results, no count of what almost worked, no hint
    /// about how close the guess was.
    case wrongPassphrase
    case passphraseTooShort
    /// The session is locked. Both directions need the value key.
    case locked
    /// A row in this machine's vault would not decrypt. Export stops rather than
    /// writing a backup that is quietly missing a secret.
    case corruptEntry
    /// The vault could not be read. Never treated as "the vault is empty" — on
    /// import that would disable the duplicate check, and on export it would
    /// write a file with nothing in it.
    case vaultUnreadable
    /// Some entries were decrypted but not stored.
    case saveFailed
    case randomFailed

    var errorDescription: String? {
      switch self {
      case .unsupportedFormat: "This is not a ClipFlow vault export, or it was written by a newer version."
      case .malformed: "This file is damaged and cannot be read."
      case .wrongPassphrase: "Wrong passphrase."
      case .passphraseTooShort: "Use at least \(VaultTransfer.minimumPassphraseLength) characters. This passphrase is the only thing protecting the file."
      case .locked: "Unlock the vault first."
      case .corruptEntry: "An entry in your vault could not be decrypted, so the export was cancelled."
      case .vaultUnreadable: "Your vault could not be read, so nothing was changed."
      case .saveFailed: "Some entries could not be saved. Your existing entries were not changed."
      case .randomFailed: "The system random number generator is unavailable."
      }
    }
  }

  // MARK: - Recovery key

  /// Crockford's base32: no I, L, O or U, so nothing in it can be confused with
  /// 1 or 0 when it is read off a screen and written on paper.
  private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

  /// A fresh 128-bit recovery key, grouped for transcription
  /// (`K7QM-4F2A-9B17-XR3D-88TW-P1LN-ZQ`). This is the default, and it is what
  /// makes the KDF's strength close to irrelevant: there is nothing to guess.
  ///
  /// 128 bits is 26 base32 characters, so the last group is a pair rather than a
  /// fourth character. Keeping all 128 bits beats a tidier line.
  static func generateRecoveryKey() throws -> String {
    var bytes = [UInt8](repeating: 0, count: 16)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      throw Failure.randomFailed
    }
    let encoded = base32(bytes)
    let groups = stride(from: 0, to: encoded.count, by: 4).map { start in
      String(encoded.dropFirst(start).prefix(4))
    }
    return groups.joined(separator: "-")
  }

  private static func base32(_ bytes: [UInt8]) -> String {
    var out = ""
    var buffer = 0
    var bits = 0
    for byte in bytes {
      buffer = (buffer << 8) | Int(byte)
      bits += 8
      while bits >= 5 {
        bits -= 5
        out.append(alphabet[(buffer >> bits) & 31])
      }
    }
    if bits > 0 { out.append(alphabet[(buffer << (5 - bits)) & 31]) }
    return out
  }

  /// Separators a transcribed key is plausibly written with. Anything else — a
  /// comma, an apostrophe, a colon — is a character a passphrase chose, not a
  /// gap between groups.
  private static let separators: Set<Unicode.Scalar> = [" ", "-"]

  /// Folds a transcribed recovery key back to the exact characters it was
  /// derived from — case, dashes, spaces and the 0/O, 1/I/L confusions all
  /// vanish.
  ///
  /// **The check is on the whole input, not on a stripped residue.** Every
  /// character has to be either a separator or, after the O→0 and I/L→1 folds, a
  /// letter of the Crockford alphabet; one character outside that set and the
  /// string is returned completely untouched. Counting only the alphanumerics
  /// that survived stripping was the old bug: `My!Secret!Passphrase!2026Zk9q`
  /// has 26 of them, so it was uppercased and folded, and every variation of the
  /// user's case and punctuation opened the same file.
  ///
  /// Applied identically on both sides, so a passphrase that really is
  /// key-shaped — 26 Crockford characters and nothing else — still round-trips;
  /// the cost is that two such passphrases differing only by case or spacing
  /// open each other's files. That is inherent to sniffing the shape at all.
  ///
  /// ponytail: shape sniffing rather than a flag in the file. A flag would say
  /// out loud which files are protected by a typed passphrase and therefore
  /// worth guessing at.
  private static func canonical(_ passphrase: String) -> String {
    var folded = ""
    for scalar in passphrase.uppercased().unicodeScalars {
      switch scalar {
      case _ where separators.contains(scalar): continue
      case "O": folded.append("0")
      case "I", "L": folded.append("1")
      default:
        guard alphabet.contains(Character(scalar)) else { return passphrase }
        folded.unicodeScalars.append(scalar)
      }
    }
    guard folded.count == 26 else { return passphrase }
    return folded
  }

  // MARK: - Key derivation

  // ponytail: PBKDF2 because macOS ships no Argon2id and NFR-3 has no dependency
  // budget left. Swap if that ever changes — memory-hard is materially better
  // against GPU cracking.
  //
  // Blocking and deliberately slow, so every caller reaches it through a
  // detached task rather than the main actor.
  private static func derive(passphrase: String, salt: Data, iterations: Int) -> SymmetricKey? {
    let password = Array(canonical(passphrase).utf8)
    guard !password.isEmpty, !salt.isEmpty else { return nil }

    var derived = [UInt8](repeating: 0, count: keyCount)
    let status: Int32 = password.withUnsafeBufferPointer { pw in
      salt.withUnsafeBytes { (saltRaw: UnsafeRawBufferPointer) in
        CCKeyDerivationPBKDF(
          CCPBKDFAlgorithm(kCCPBKDF2),
          UnsafeRawPointer(pw.baseAddress!).assumingMemoryBound(to: Int8.self),
          pw.count,
          saltRaw.bindMemory(to: UInt8.self).baseAddress!,
          salt.count,
          CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
          UInt32(iterations),
          &derived,
          derived.count
        )
      }
    }
    guard status == kCCSuccess else { return nil }

    let key = SymmetricKey(data: Data(derived))
    derived.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) }
    return key
  }

  private static func deriveOffMain(passphrase: String, salt: Data, iterations: Int) async -> SymmetricKey? {
    await Task.detached(priority: .userInitiated) {
      derive(passphrase: passphrase, salt: salt, iterations: iterations)
    }.value
  }

  // MARK: - File, without touching the database

  /// Seals a list of secrets into the file's bytes. Split out from `export()` so
  /// the format can be exercised without a Keychain or a database anywhere near
  /// it — that is the self-check's fourth assertion.
  static func makeFile(entries: [Entry], passphrase: String) async throws -> Data {
    guard passphrase.count >= minimumPassphraseLength else { throw Failure.passphraseTooShort }

    var saltBytes = [UInt8](repeating: 0, count: saltCount)
    guard SecRandomCopyBytes(kSecRandomDefault, saltBytes.count, &saltBytes) == errSecSuccess else {
      throw Failure.randomFailed
    }
    let salt = Data(saltBytes)

    guard let key = await deriveOffMain(passphrase: passphrase, salt: salt, iterations: iterations) else {
      throw Failure.malformed
    }
    let payload = try JSONEncoder().encode(entries)
    guard let sealed = try AES.GCM.seal(payload, using: key).combined else { throw Failure.malformed }

    let envelope = Envelope(
      format: formatID,
      version: formatVersion,
      kdf: kdfID,
      iterations: iterations,
      salt: salt.base64EncodedString(),
      sealed: sealed.base64EncodedString()
    )
    return try JSONEncoder().encode(envelope)
  }

  /// Opens the file's bytes. Every failure past the header check reports as
  /// `wrongPassphrase`, because from outside they are indistinguishable and
  /// saying more would be a hint.
  static func readFile(_ data: Data, passphrase: String) async throws -> [Entry] {
    guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
      throw Failure.malformed
    }
    // Rejected before any work — a file claiming a million iterations of an
    // algorithm we do not have should cost nothing to refuse.
    guard envelope.format == formatID, envelope.version == formatVersion, envelope.kdf == kdfID else {
      throw Failure.unsupportedFormat
    }
    guard (100_000...2_000_000).contains(envelope.iterations) else { throw Failure.unsupportedFormat }
    guard let salt = Data(base64Encoded: envelope.salt), salt.count == saltCount,
          let sealed = Data(base64Encoded: envelope.sealed)
    else { throw Failure.malformed }

    guard let key = await deriveOffMain(passphrase: passphrase, salt: salt, iterations: envelope.iterations),
          let box = try? AES.GCM.SealedBox(combined: sealed),
          let payload = try? AES.GCM.open(box, using: key)
    else { throw Failure.wrongPassphrase }

    // The tag verified, so the passphrase was right and this really is our
    // plaintext — broken JSON at this point is a damaged file, not a bad guess.
    guard let entries = try? JSONDecoder().decode([Entry].self, from: payload) else {
      throw Failure.malformed
    }
    return entries
  }

  /// `clipflow-vault-2026-08-11.clipflowvault`.
  static func defaultFilename(date: Date = Date()) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return "clipflow-vault-\(formatter.string(from: date)).\(fileExtension)"
  }

  // MARK: - The vault, in and out

  /// Decrypts every entry and re-seals the lot under the passphrase. Requires an
  /// unlocked session for the obvious reason: this reads every secret there is.
  ///
  /// The caller writes the returned bytes wherever the save panel said, and is
  /// responsible for having shown the recovery key and collected the
  /// acknowledgement *first* — a file whose passphrase was never written down is
  /// indistinguishable from a deleted one.
  @MainActor
  static func export(passphrase: String) async throws -> Data {
    guard VaultSession.shared.isUnlocked else { throw Failure.locked }
    guard let rows = VaultRepository.all() else { throw Failure.vaultUnreadable }
    let nameKey = try VaultKeys.nameKey()

    var entries: [Entry] = []
    entries.reserveCapacity(rows.count)
    for row in rows {
      // A corrupt row stops the export. Skipping it would produce a backup that
      // is silently short one secret, and the user would find out at the worst
      // possible moment.
      guard let name = try? VaultCrypto.open(row.sealedName, using: nameKey),
            let value = try? VaultSession.shared.open(row.sealedValue)
      else { throw Failure.corruptEntry }
      entries.append(Entry(name: name, value: value, createdAt: row.createdAt))
    }
    return try await makeFile(entries: entries, passphrase: passphrase)
  }

  /// Opens a file and merges it into this machine's vault, re-sealing every
  /// entry under *this* machine's keys.
  ///
  /// **Merge, never replace.** An entry whose decrypted name *and* value both
  /// match one already here is skipped; nothing is ever deleted or overwritten.
  /// The rule exists so that opening the wrong file, or the right file twice,
  /// cannot damage a good vault.
  @MainActor
  static func importFile(_ data: Data, passphrase: String) async throws -> ImportResult {
    guard VaultSession.shared.isUnlocked else { throw Failure.locked }
    let incoming = try await readFile(data, passphrase: passphrase)

    // Read the existing vault before writing anything. Nil is not "empty" here:
    // without the existing rows the duplicate check cannot run, and importing
    // blind would duplicate the whole vault.
    guard let existing = VaultRepository.all() else { throw Failure.vaultUnreadable }
    let nameKey = try VaultKeys.nameKey()

    var seen = Set<[String]>()
    for row in existing {
      // A row that will not open cannot be compared against. Ignoring it risks a
      // duplicate; refusing the import would let one damaged row block a
      // restore, which is worse.
      guard let name = try? VaultCrypto.open(row.sealedName, using: nameKey),
            let value = try? VaultSession.shared.open(row.sealedValue)
      else { continue }
      seen.insert([name, value])
    }

    var result = ImportResult(imported: 0, skipped: 0)
    var failed = 0
    let now = Int64(Date().timeIntervalSince1970 * 1000)
    for entry in incoming {
      // Also catches duplicates *within* the file, so a doubled export imports
      // once.
      guard seen.insert([entry.name, entry.value]).inserted else {
        result.skipped += 1
        continue
      }
      var row = VaultEntry(
        id: nil,
        sealedName: try VaultCrypto.seal(entry.name, using: nameKey),
        sealedValue: try VaultSession.shared.seal(entry.value),
        createdAt: entry.createdAt,
        updatedAt: now
      )
      if VaultRepository.save(&row) {
        result.imported += 1
      } else {
        failed += 1
      }
    }

    // Counts only — never a name, never a value.
    NSLog("ClipFlow: vault import wrote \(result.imported), skipped \(result.skipped) duplicates, failed \(failed)")
    if failed > 0 { throw Failure.saveFailed }
    return result
  }
}
