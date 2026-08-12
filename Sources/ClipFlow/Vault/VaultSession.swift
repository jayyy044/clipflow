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
  /// `LocalizedError` for the same reason `VaultKeys.Failure` is: callers show
  /// `localizedDescription`, and the default for a bare `Error` is Swift's debug
  /// rendering with an enum case number in it.
  enum Failure: LocalizedError {
    /// The session was locked, or was never unlocked. Not an error to report —
    /// the caller unlocks and retries.
    case locked
    /// The sealed blob failed its authentication tag or was not UTF-8. Never
    /// render this as empty text: an entry that silently reads as blank is one
    /// the user deletes as junk.
    case corrupt

    var errorDescription: String? {
      switch self {
      case .locked: "The vault locked. Unlock and try again."
      case .corrupt: "Couldn't read that entry."
      }
    }
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

  /// The longest the idle countdown may be held off by `suspendIdleTimer()`.
  /// See that method for why a cap exists at all.
  static let maximumSuspension: TimeInterval = 300

  private var key: SymmetricKey?
  private var idleTimer: Timer?

  /// Outstanding `suspendIdleTimer()` calls. A count rather than a flag so two
  /// nested modal sheets do not have the inner one's dismissal re-arm the timer
  /// under the outer one.
  private var suspensions = 0

  /// The bound on the above. Armed with the first suspension, and it ends the
  /// suspension outright when it fires.
  private var suspensionGuard: Timer?

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
    // A suspension never survives a lock. Whatever modal loop was holding the
    // countdown off, the vault is now closed, and a `resumeIdleTimer()` that
    // arrives afterwards must not be able to bring anything back — with the
    // count at zero it returns without touching a thing.
    suspensions = 0
    suspensionGuard?.invalidate()
    suspensionGuard = nil
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

  /// Holds the idle countdown off until a matching `resumeIdleTimer()`.
  ///
  /// **This exists because of modal run loops, and deleting it re-opens a real
  /// bug.** The idle timer is scheduled in `.common` so menu tracking cannot
  /// defer the lock — which also means it fires inside `.modalPanel`, the mode
  /// `NSAlert.runModal()` and `NSSavePanel.runModal()` spin. The vault could
  /// therefore auto-lock while the user was still copying their 32-character
  /// recovery key off a modal alert, and the export that alert belongs to then
  /// failed after they had already written the key down and pressed OK.
  ///
  /// Only the *countdown* is suspended. Screen lock, an explicit `lock()` and
  /// the panel closing all still lock the vault while suspended — this does not
  /// make the vault unlockable, it makes the clock stop.
  ///
  /// Nesting is counted, and calling it twice is safe. It is also bounded: an
  /// unbalanced call would otherwise leave an unlocked vault that never idles
  /// out, which is precisely the state the idle timer exists to prevent, so
  /// `maximumSuspension` ends it regardless of who forgot to resume.
  func suspendIdleTimer() {
    suspensions += 1
    idleTimer?.invalidate()
    idleTimer = nil
    guard suspensionGuard == nil else { return }
    let guardTimer = Timer(timeInterval: Self.maximumSuspension, repeats: false) { _ in
      Task { @MainActor in VaultSession.shared.endSuspension() }
    }
    RunLoop.main.add(guardTimer, forMode: .common)
    suspensionGuard = guardTimer
  }

  /// Balances one `suspendIdleTimer()`. The last one re-arms a **full fresh**
  /// interval rather than the remainder: the modal was in front of the user, so
  /// the time it was up was not idle time, and resuming with a few seconds left
  /// would lock the vault immediately after they dismissed it.
  ///
  /// Extra calls are ignored, so an unbalanced resume cannot drive the count
  /// negative and disable a later suspension.
  func resumeIdleTimer() {
    guard suspensions > 0 else { return }
    suspensions -= 1
    guard suspensions == 0 else { return }
    endSuspension()
  }

  private func endSuspension() {
    suspensions = 0
    suspensionGuard?.invalidate()
    suspensionGuard = nil
    // No-op on a locked session: `touch()` refuses to arm without a key.
    touch()
  }

  /// Restarts the idle countdown. Called from every operation that touches the
  /// key, so the timeout measures idleness rather than time since unlocking.
  private func touch() {
    idleTimer?.invalidate()
    idleTimer = nil
    // Suspended: the countdown stays stopped, and `resumeIdleTimer()` is what
    // starts it again. Vault work done while a modal is up still must not
    // re-arm behind the suspension's back.
    guard suspensions == 0 else { return }
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
