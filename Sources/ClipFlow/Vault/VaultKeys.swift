import CryptoKit
import Foundation
// Error codes only — `LAError.userCancel` and friends are how a CryptoKit
// Secure Enclave failure says "the user dismissed the sheet". There is
// deliberately no `LAContext` and no `evaluatePolicy` anywhere in this file; see
// the note on V-3 below.
import LocalAuthentication
import Security

/// The two symmetric keys the vault is built on, each wrapped to a Secure
/// Enclave key that never leaves the SEP.
///
/// The split is V-1: entry *names* are sealed under a key whose Enclave key has
/// no user-presence requirement, so a locked vault can still draw a real list,
/// while entry *values* are sealed under a key whose Enclave key carries a
/// `.userPresence` access control. The database file on its own therefore
/// reveals neither, and the running app reveals names without authenticating and
/// values only after.
///
/// **The authentication is the Secure Enclave's access control and nothing
/// else** (V-3). Unwrapping the value master key performs an ECDH key agreement
/// *inside the SEP*, and that operation is what raises the Touch ID sheet: the
/// Enclave refuses to compute the shared secret until the user authenticates, so
/// a failed authentication is a *missing key*, not a `false`. There is
/// deliberately no `LAContext.evaluatePolicy` gate — a boolean return is one
/// patched branch away from unlocking the vault, and a key that never leaves the
/// Enclave's custody is not.
///
/// **Why not the Keychain** (V-6, reversed 2026-08-11). The data-protection
/// keychain is the textbook home for this and it is unusable here: `SecItemAdd`
/// returns `errSecMissingEntitlement` (-34018) for a command-line `codesign`
/// build, and the entitlements that would fix it are restricted ones needing an
/// embedded provisioning profile — adding them SIGKILLs the app at launch. The
/// legacy file keychain is worse than useless: the add succeeds, and
/// `SecItemCopyMatching` then hands back the key data with **no prompt at all**,
/// silently accepting and ignoring the `.userPresence` access control. That path
/// is a vault that looks gated and is not, so it is not taken under any
/// circumstances. See the design doc's Unit A correction.
enum VaultKeys {
  /// `userCancelled` is separated out because a cancelled Touch ID sheet is the
  /// user changing their mind, not a fault: callers dismiss quietly rather than
  /// putting an alert on screen. `unavailable` covers the cases where the
  /// Enclave will not talk to us at all — no Secure Enclave on this Mac (pre-T2
  /// Intel), no biometry or password credential enrolled, or a headless/
  /// non-interactive process where the ACL cannot be satisfied.
  ///
  /// `keychain(OSStatus)` keeps its name for source compatibility with existing
  /// callers; it now carries whatever code the underlying Security or
  /// LocalAuthentication error reported, and means "something unclassified went
  /// wrong", which every caller alerts on.
  ///
  /// `keyLost` is the one that is permanent: the wrapped key blob is not on disk
  /// but `vault_entries` has rows in it, so the key those rows were sealed under
  /// is gone and nothing can open them again. It is separate from
  /// `keychain(OSStatus)` because that one means "try again later" and this one
  /// never does, and separate from `userCancelled` because the user did not
  /// choose it. Callers must say the true thing rather than "couldn't read that
  /// entry".
  enum Failure: LocalizedError {
    case userCancelled
    case unavailable
    case keychain(OSStatus)
    case keyLost

    /// `LocalizedError` because every caller reaches for `localizedDescription`,
    /// and a bare `Error` renders that as `The operation couldn't be completed.
    /// (ClipFlow.VaultKeys.Failure error 1.)` — which is what the most common
    /// non-happy path in the vault, pressing Cancel on the Touch ID sheet, used
    /// to put in front of the user.
    ///
    /// `.keychain`'s status code is deliberately not in the sentence: it is in
    /// the log lines above, and a number nobody can act on only makes the
    /// advice that follows it look less trustworthy.
    var errorDescription: String? {
      switch self {
      case .userCancelled:
        "Unlocking was cancelled. The vault is still locked."
      case .unavailable:
        "macOS wouldn't unlock the vault — Touch ID or a login password has to be set up."
      case .keychain:
        "Couldn't reach the vault's keys. Nothing has been lost — quit and reopen ClipFlow, then try again."
      case .keyLost:
        "The key this Mac sealed your vault entries with is gone, so those entries cannot be opened again. A vault export made earlier is the only way to get them back."
      }
    }
  }

  /// Beside the database, in Application Support. These blobs are useless on any
  /// other machine — the private half lives in this Mac's SEP and cannot be
  /// extracted — but they are still treated as secrets: created `0600`, never
  /// logged, never named in a log line.
  private static let nameFile = "vault-name.key"
  private static let valueFile = "vault-value.key"

  /// Domain separation for the key-wrapping HKDF, so the derived wrapping key is
  /// bound to this purpose and this format version.
  private static let wrapInfo = Data("com.jayyy044.clipflow.vault.keywrap.v1".utf8)

  /// What actually sits in the file. `JSONEncoder` base64s `Data`, which is why
  /// this is three fields and no hand-rolled framing.
  ///
  /// `sepKey` is the Enclave key's `.dataRepresentation` — an opaque, SEP-sealed
  /// blob, not a private key. `ephemeralPublicKey` and `wrappedMasterKey` are the
  /// ECIES envelope around the 256-bit master key.
  private struct Wrapped: Codable {
    var sepKey: Data
    var ephemeralPublicKey: Data
    var wrappedMasterKey: Data
  }

  /// Seals and opens entry names. No prompt, by design — see V-1.
  static func nameKey() throws -> SymmetricKey {
    // `.privateKeyUsage` and nothing more: the Enclave will use this key without
    // asking anyone anything. The accessibility class still keeps it off any
    // other machine and out of a backup.
    guard let control = SecAccessControlCreateWithFlags(
      nil,
      kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
      .privateKeyUsage,
      nil
    ) else {
      NSLog("ClipFlow: vault name key access control could not be created")
      throw Failure.unavailable
    }
    return try masterKey(file: nameFile, control: control)
  }

  /// Seals and opens entry values. **Raises Touch ID, falling back to the Mac
  /// password**, because the Enclave will not perform the key agreement that
  /// unwraps this master key without it.
  ///
  /// Blocks the calling thread until the user answers the sheet, so this is
  /// never called on the main actor — `VaultSession.unlock()` is the one caller
  /// and it hops off first. One prompt per unlock, not per entry: the session
  /// caches what comes back.
  static func valueKey() throws -> SymmetricKey {
    // `.privateKeyUsage` is not optional here and its absence is not a subtlety:
    // `.userPresence` alone says *who* may use the key and never grants the use,
    // so every agreement threw LocalAuthentication -1009, "Operation is not
    // allowed". That failure was read as the Enclave enforcing the gate. It was
    // the Enclave refusing an operation the ACL had never permitted, which looks
    // identical from the outside if the only thing checked is that it failed —
    // and it is why this vault shipped with no working authentication at all.
    guard let control = SecAccessControlCreateWithFlags(
      nil,
      kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
      [.privateKeyUsage, .userPresence],
      nil
    ) else {
      // No enrolled biometry *and* no password credential, or a policy that
      // forbids both. Creating the key without the ACL would produce a vault
      // that is silently not gated, which is worse than one that will not open.
      NSLog("ClipFlow: vault value key needs a user-presence access control and the system refused to make one")
      throw Failure.unavailable
    }
    return try masterKey(file: valueFile, control: control)
  }

  /// Whether the value key exists, which is how a caller tells "the vault was
  /// never set up" from "the vault is locked". Does **not** prompt: it only asks
  /// whether the wrapped blob is on disk, and the access control is evaluated
  /// only when the Enclave is asked to unwrap it.
  static var isConfigured: Bool {
    FileManager.default.fileExists(atPath: Database.directory.appending(path: valueFile).path)
  }

  /// Loads the wrapped master key if it is there, otherwise generates one — but
  /// only on genuine first use, see below.
  ///
  /// Lazy rather than at launch, as before: a user who never opens the vault
  /// never gets a key file, and the value key's creation is also the moment the
  /// ACL is attached. Generation itself never prompts — wrapping uses the
  /// Enclave key's *public* half — so the first Touch ID sheet a user sees is
  /// the first time they unlock, not the moment they create the vault.
  ///
  /// That last property is exactly why a missing key file cannot be allowed to
  /// mint silently: creating the Enclave key and wrapping under its public half
  /// both succeed with no prompt, so with the file gone (a partial restore, a
  /// Migration Assistant run, anyone tidying Application Support) an Unlock
  /// would raise no sheet at all, report success, and then fail to open every
  /// existing row with a generic error. The file's absence is the whole
  /// difference between authenticated and not, so it is only treated as first
  /// use when the vault is genuinely empty.
  private static func masterKey(file: String, control: SecAccessControl) throws -> SymmetricKey {
    guard SecureEnclave.isAvailable else {
      NSLog("ClipFlow: no Secure Enclave on this Mac — the vault cannot be opened here")
      throw Failure.unavailable
    }

    let url = Database.directory.appending(path: file)
    if let blob = FileManager.default.contents(atPath: url.path) {
      return try unwrap(blob)
    }

    // No key file. The count below decides whether this is first use, so it has
    // to be a count of the real database: when `Database.shared` fell back to
    // its in-memory queue the user's vault is untouched on disk and entirely
    // invisible, and `count()` answers a truthful zero about a database that
    // holds nothing. Minting on that zero is the silent overwrite this whole
    // guard exists to prevent, so an unreadable vault is not an empty one.
    //
    // Transient, not `.keyLost`: the disk may be fine on the next launch and
    // nothing has been lost yet.
    guard !Database.isEphemeral else {
      NSLog("ClipFlow: vault key file is missing and the database is the in-memory fallback — not minting a key")
      throw Failure.keychain(errSecIO)
    }

    // `count()` is nil for a *failed* read, never zero for one, so an unknown
    // answer refuses to mint too — it just reports as the transient error it
    // might be, rather than as permanent loss.
    guard let entries = VaultRepository.count() else {
      NSLog("ClipFlow: vault key file is missing and the entry count could not be read — not minting a key")
      throw Failure.keychain(errSecIO)
    }
    guard entries == 0 else {
      NSLog("ClipFlow: vault key file is missing while \(entries) entries exist — those entries cannot be opened again")
      throw Failure.keyLost
    }

    try? FileManager.default.createDirectory(at: Database.directory, withIntermediateDirectories: true)

    do {
      let enclaveKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: control)
      let master = SymmetricKey(size: .bits256)

      // ECIES: an ephemeral keypair agrees with the Enclave key's public half,
      // so nothing here needs the Enclave to *do* anything and nothing prompts.
      // The reverse direction — the Enclave holding the static private key — is
      // what costs an authentication.
      let ephemeral = P256.KeyAgreement.PrivateKey()
      let ephemeralPublic = ephemeral.publicKey.x963Representation
      let shared = try ephemeral.sharedSecretFromKeyAgreement(with: enclaveKey.publicKey)
      let box = try AES.GCM.seal(
        master.withUnsafeBytes { Data($0) },
        using: wrappingKey(shared, salt: ephemeralPublic)
      )
      guard let combined = box.combined else { throw Failure.keychain(errSecDecode) }

      let blob = try JSONEncoder().encode(Wrapped(
        sepKey: enclaveKey.dataRepresentation,
        ephemeralPublicKey: ephemeralPublic,
        wrappedMasterKey: combined
      ))

      // Two callers raced to first use. The file that landed is the real key and
      // ours is thrown away unused; re-reading is the only correct answer, since
      // overwriting would orphan whatever the winner already sealed. `O_EXCL` is
      // the whole interlock — no lock is held across a Touch ID sheet.
      guard try writeExclusively(blob, to: url) else {
        guard let existing = FileManager.default.contents(atPath: url.path) else {
          throw Failure.keychain(errSecIO)
        }
        return try unwrap(existing)
      }
      return master
    } catch let failure as Failure {
      throw failure
    } catch {
      throw self.failure(error)
    }
  }

  /// Reverses the wrap. For the value key this is where the Touch ID sheet comes
  /// up: `sharedSecretFromKeyAgreement` runs inside the Enclave against a key
  /// whose ACL demands user presence, and it simply fails if nobody is there.
  private static func unwrap(_ blob: Data) throws -> SymmetricKey {
    guard let stored = try? JSONDecoder().decode(Wrapped.self, from: blob) else {
      NSLog("ClipFlow: vault key file is not readable as a wrapped key")
      throw Failure.keychain(errSecDecode)
    }
    do {
      // Supplies the sentence macOS puts in its own authentication sheet, and
      // nothing else. This is NOT the `evaluatePolicy` gate V-3 forbids: nothing
      // here asks whether the user authenticated and then decides. The Enclave
      // still refuses the agreement on its own, and without a reason string the
      // system has no wording to draw a sheet with.
      let context = LAContext()
      context.localizedReason = "unlock your ClipFlow vault"
      let enclaveKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(
        dataRepresentation: stored.sepKey, authenticationContext: context)
      let ephemeral = try P256.KeyAgreement.PublicKey(x963Representation: stored.ephemeralPublicKey)
      let shared = try enclaveKey.sharedSecretFromKeyAgreement(with: ephemeral)
      let sealed = try AES.GCM.SealedBox(combined: stored.wrappedMasterKey)
      let master = try AES.GCM.open(sealed, using: wrappingKey(shared, salt: stored.ephemeralPublicKey))
      guard master.count == 32 else { throw Failure.keychain(errSecDecode) }
      return SymmetricKey(data: master)
    } catch let failure as Failure {
      throw failure
    } catch {
      throw self.failure(error)
    }
  }

  private static func wrappingKey(_ shared: SharedSecret, salt: Data) -> SymmetricKey {
    shared.hkdfDerivedSymmetricKey(
      using: SHA256.self, salt: salt, sharedInfo: wrapInfo, outputByteCount: 32
    )
  }

  /// Creates the file with `0600` in the same syscall that creates it, so there
  /// is no window where the blob exists at the umask's permissions. False means
  /// the file already existed — the caller reads it instead of clobbering it.
  private static func writeExclusively(_ data: Data, to url: URL) throws -> Bool {
    let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
    if descriptor < 0 {
      if errno == EEXIST { return false }
      NSLog("ClipFlow: could not create vault key file, errno \(errno)")
      throw Failure.keychain(errSecIO)
    }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    do {
      try handle.write(contentsOf: data)
    } catch {
      // A half-written blob is unrecoverable and would look like a corrupt key
      // forever, so it does not get to stay.
      try? FileManager.default.removeItem(at: url)
      throw Failure.keychain(errSecIO)
    }
    return true
  }

  /// Self-check only, reached from `--vault-self-check`. Creates the *name* key
  /// through the same code path the app uses, confirms the blob landed with the
  /// right mode, reconstructs it from disk in-process, and confirms the two
  /// agree by sealing with one and opening with the other — which is the only
  /// honest way to answer whether the Secure Enclave design works for this app
  /// as signed.
  ///
  /// The name key and not the value key, deliberately: the name key has no
  /// user-presence ACL, so this raises no sheet and can run headless. The value
  /// key's Touch ID path **cannot** be verified this way and this function does
  /// not pretend to.
  ///
  /// Refuses to run outside a scratch data directory, so it can never create a
  /// key in the user's real Application Support.
  ///
  /// Returns nil on success, or a short reason.
  static func probeSecureEnclave() -> String? {
    guard SecureEnclave.isAvailable else { return "SecureEnclave.isAvailable is false" }
    guard Database.isScratchDirectory else { return "not a scratch data directory — refusing to run" }
    do {
      let created = try nameKey()
      let path = Database.directory.appending(path: nameFile).path
      guard FileManager.default.fileExists(atPath: path) else { return "no key blob was written" }
      let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
      guard mode?.int32Value == 0o600 else {
        return "key blob mode is \(String(mode?.int32Value ?? -1, radix: 8)), expected 600"
      }
      // Second call reads the blob back and rebuilds the Enclave key from its
      // data representation — a different object, and it must produce the same
      // master key or every existing entry would be unreadable after a restart.
      let reconstructed = try nameKey()
      let probe = "clipflow self-check"
      let sealed = try VaultCrypto.seal(probe, using: created)
      guard try VaultCrypto.open(sealed, using: reconstructed) == probe else {
        return "reconstructed key did not open what the created key sealed"
      }
      return nil
    } catch {
      return "\(error)"
    }
  }

  /// Maps whatever CryptoKit and the Security framework hand back into the three
  /// cases callers know about.
  ///
  /// Classified by domain first, because LocalAuthentication's codes are small
  /// negatives that collide with unrelated `OSStatus` values. Anything
  /// unrecognised falls through to `.keychain`, which callers alert on — the
  /// safe direction, since silently treating an unknown failure as "the user
  /// changed their mind" would hide a broken vault.
  private static func failure(_ error: Error) -> Failure {
    let nsError = error as NSError
    var code = Int32(truncatingIfNeeded: nsError.code)
    var domain = nsError.domain
    if case CryptoKitError.underlyingCoreCryptoError(let underlying) = error {
      code = underlying
      domain = NSOSStatusErrorDomain
    }

    if domain == LAErrorDomain || domain.contains("LocalAuthentication") {
      switch code {
      case Int32(LAError.userCancel.rawValue),
           Int32(LAError.systemCancel.rawValue),
           Int32(LAError.appCancel.rawValue),
           Int32(LAError.userFallback.rawValue):
        return .userCancelled
      case Int32(LAError.authenticationFailed.rawValue):
        // Deliberately folded into cancellation, and this is a real trade rather
        // than a tidy-up.
        //
        // A genuine authentication failure — biometry exhausted, then a wrong
        // Mac password — is treated as "the user changed their mind". The sheet
        // closes, the vault stays locked, and **no alert is shown**: the user is
        // told nothing and has to notice for themselves that it did not open.
        // Retrying is the whole remedy, and the failed attempt did happen in
        // front of them, so this is judged the smaller harm than an error dialog
        // every time someone presses Escape — which reports as a cancel on some
        // macOS versions and as this on others, a premise recorded in Unit A
        // that has NOT been verified here across a version matrix.
        //
        // The log line below is the compensation: silent to the user, never
        // silent in the record. To reverse this, add a distinct `Failure` case —
        // do not reroute it into `.keychain`, which every caller alerts on.
        NSLog("ClipFlow: vault authentication failed — treated as cancellation, no alert shown")
        return .userCancelled
      case Int32(LAError.passcodeNotSet.rawValue),
           Int32(LAError.biometryNotAvailable.rawValue),
           Int32(LAError.biometryNotEnrolled.rawValue),
           Int32(LAError.invalidContext.rawValue),
           Int32(LAError.notInteractive.rawValue),
           -1009:
        // -1009 has no `LAError` name. It is what the Enclave reports when the
        // ACL cannot be satisfied at all — "ACL operation is not allowed" — and
        // is exactly what a headless process gets for the value key. That is the
        // gate working, not a fault, so it reports as unavailable rather than as
        // an error with a status code the user cannot act on.
        NSLog("ClipFlow: vault Secure Enclave unavailable, code \(code)")
        return .unavailable
      default:
        NSLog("ClipFlow: vault Secure Enclave error, code \(code)")
        return .keychain(code)
      }
    }

    switch code {
    case errSecUserCanceled:
      return .userCancelled
    case errSecAuthFailed:
      NSLog("ClipFlow: vault authentication returned errSecAuthFailed — treated as cancellation, no alert shown")
      return .userCancelled
    case errSecInteractionNotAllowed, errSecInteractionRequired, errSecNotAvailable:
      NSLog("ClipFlow: vault Secure Enclave unavailable, OSStatus \(code)")
      return .unavailable
    default:
      NSLog("ClipFlow: vault key error, OSStatus \(code)")
      return .keychain(code)
    }
  }
}
