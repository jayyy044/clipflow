import AppKit
import CryptoKit
import Foundation

extension Notification.Name {
  /// Posted whenever the value key is dropped, for whatever reason. Anything
  /// showing a revealed secret listens for this and re-hides — the session
  /// cannot reach into the views itself, and a lock that leaves plaintext on
  /// screen is not a lock.
  static let clipFlowVaultLocked = Self("clipFlowVaultLocked")
}

/// AES-GCM in one place, because names are sealed under one key and values under
/// another and both need identical treatment.
///
/// `combined` is stored, so the nonce travels with the ciphertext and no schema
/// column has to carry it. GCM authenticates, which is the point: a row that was
/// edited in the database file fails to open rather than decrypting to garbage,
/// and callers get `Failure.corrupt` to draw as a corrupt entry.
enum VaultCrypto {
  enum Failure: Error {
    /// The session was locked, or was never unlocked. Not an error to report —
    /// the caller unlocks and retries.
    case locked
    /// The sealed blob failed its authentication tag or was not UTF-8. Never
    /// render this as empty text: an entry that silently reads as blank is one
    /// the user deletes as junk.
    case corrupt
  }

  static func seal(_ value: String, using key: SymmetricKey) throws -> Data {
    let box = try AES.GCM.seal(Data(value.utf8), using: key)
    // Only nil for a nonce size GCM cannot represent, which the sealing above
    // does not produce — but the schema stores this blob, so it is checked.
    guard let combined = box.combined else { throw Failure.corrupt }
    return combined
  }

  static func open(_ sealed: Data, using key: SymmetricKey) throws -> String {
    guard let box = try? AES.GCM.SealedBox(combined: sealed),
          let plaintext = try? AES.GCM.open(box, using: key),
          let text = String(data: plaintext, encoding: .utf8)
    else { throw Failure.corrupt }
    return text
  }
}

/// Holds the value key for as long as the vault is unlocked, so one Touch ID
/// prompt covers a whole visit rather than one per entry.
///
/// Everything about the lifetime here is a deliberate narrowing of the one thing
/// the threat model cannot defend: while the vault is unlocked, the key is in
/// this process's memory, and it has to be, or the app could not show you the
/// secret. So the window is kept short and closed by three independent things.
///
/// `applicationWillTerminate` is **not** one of them. It fires on
/// `NSApp.terminate` but not on `SIGTERM`, so a killed app would leave the
/// unlocked state to be decided by whether the process died politely. The idle
/// timer is the real backstop; the other two are convenience.
@MainActor
final class VaultSession: ObservableObject {
  static let shared = VaultSession()

  @Published private(set) var isUnlocked = false

  /// Five minutes of no vault interaction. Long enough to read a recovery code
  /// off the screen and type it somewhere, short enough that a walked-away-from
  /// machine is not holding the key all afternoon.
  static let idleTimeout: TimeInterval = 300

  private var key: SymmetricKey?
  private var idleTimer: Timer?

  /// Bumped by every `lock()`. An `unlock()` that started before the bump throws
  /// its result away instead of installing it: the screen can lock, or the panel
  /// can be closed from the status menu, while the Touch ID sheet is still up,
  /// and both of those fire `lock()` into a session that has no key yet. Without
  /// this the lock is a no-op — `lock()` returns early on `key == nil` — and the
  /// awaiting `unlock()` then installs the key anyway, leaving it in memory
  /// until the idle timeout with nothing on screen.
  private var generation = 0

  /// The unlock in flight, so two callers share one Touch ID sheet rather than
  /// stacking two. Cleared when it finishes and by `lock()`, so a cancelled
  /// sheet is never replayed to the next caller.
  private var unlocking: Task<SymmetricKey, Error>?

  private init() {
    // Same observer as `PasteboardMonitor.observeSleepAndLock()`:
    // `com.apple.screenIsLocked` is undocumented but stable and is the only
    // signal macOS gives for the screen locking. No matching unlock observer —
    // the vault does not reopen on its own, ever.
    DistributedNotificationCenter.default().addObserver(
      forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main
    ) { _ in
      Task { @MainActor in VaultSession.shared.lock() }
    }
  }

  /// Raises the Touch ID sheet by *reading the key*, and caches what comes back.
  ///
  /// Off the main actor because the Secure Enclave key agreement blocks its
  /// thread until
  /// the user answers, and blocking the main actor there would freeze the panel
  /// underneath the sheet.
  ///
  /// Already unlocked is a success that only resets the idle timer, so a caller
  /// can front every vault action with this and get exactly one prompt.
  func unlock() async throws {
    guard key == nil else { return touch() }
    let started = generation
    let task = unlocking ?? Task.detached(priority: .userInitiated) {
      try VaultKeys.valueKey()
    }
    unlocking = task
    // No lock is held across the await — this is a hop on the main actor, and
    // `lock()` is free to run in the gap. That is the case being handled.
    defer { if unlocking == task { unlocking = nil } }
    let unwrapped = try await task.value
    // Locked while the sheet was up. The key is dropped on the floor rather
    // than installed, and the user unlocks again. Reported as a cancellation
    // because that is the one failure callers dismiss without an alert, and
    // returning normally would tell them the vault is open when it is not.
    guard generation == started else { throw VaultKeys.Failure.userCancelled }
    key = unwrapped
    isUnlocked = true
    touch()
  }

  /// Drops the key and says so. Idempotent, because it is called from three
  /// unrelated triggers that can easily coincide — screen lock while the panel
  /// closes, for instance.
  ///
  /// The third trigger, the panel closing, is not observed here: nothing posts a
  /// panel-close notification, and `Panel`'s `onClose` belongs to the UI. The
  /// panel's own close handler calls this.
  func lock() {
    idleTimer?.invalidate()
    idleTimer = nil
    // Before the early return, so a lock that arrives while a sheet is up still
    // counts: that unlock discards its key instead of installing it.
    generation &+= 1
    unlocking = nil
    guard key != nil else { return }
    key = nil
    isUnlocked = false
    NotificationCenter.default.post(name: .clipFlowVaultLocked, object: nil)
  }

  /// Seals a value for storage. Requires the session to be unlocked, which is
  /// the same condition as having the key — there is no separate flag to get out
  /// of step with.
  func seal(_ value: String) throws -> Data {
    guard let key else { throw VaultCrypto.Failure.locked }
    touch()
    return try VaultCrypto.seal(value, using: key)
  }

  func open(_ sealed: Data) throws -> String {
    guard let key else { throw VaultCrypto.Failure.locked }
    touch()
    return try VaultCrypto.open(sealed, using: key)
  }

  /// Restarts the idle countdown. Called from every operation that touches the
  /// key, so the timeout measures idleness rather than time since unlocking.
  private func touch() {
    idleTimer?.invalidate()
    guard key != nil else { return }
    // `.common`, not `.default`: `Timer.scheduledTimer` adds to `.default`
    // only, so menu tracking or a modal loop would defer the lock for as long
    // as it ran. Same reason and same spelling as `PasteboardMonitor.start()`.
    let timer = Timer(timeInterval: Self.idleTimeout, repeats: false) { _ in
      Task { @MainActor in VaultSession.shared.lock() }
    }
    RunLoop.main.add(timer, forMode: .common)
    idleTimer = timer
  }
}
