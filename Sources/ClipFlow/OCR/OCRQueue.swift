import Foundation
import ImageIO
import os

/// Reads text out of stored screenshots so they answer the same search field as
/// typed text (G3). One image at a time, off the main thread, at a priority that
/// yields to everything the user can see (FR-4.4).
final class OCRQueue {
  static let shared = OCRQueue()

  /// FR-4.6. A 30000 px stitched panorama would hold a decoded surface far past
  /// the 60 MB budget for however long Vision took, and nobody searches one.
  private static let maxEdgePixels = 8000

  // ponytail: one lock around two bools, guaranteeing at most one drain in
  // flight without ever holding the lock across a SELECT. `running` is the
  // drain; `woken` records that someone asked for one since the current scan
  // began. Invariant: a `wake()` that lands after the drain's last SELECT
  // leaves `woken` set, so the drain rescans instead of standing down — the
  // stranded-row race the old re-check-under-the-lock closed, minus the I/O
  // inside the critical section (an unfair lock is a spinlock; SQLite is not
  // arbitrary-work-safe under one).
  private let state = OSAllocatedUnfairLock(initialState: (running: false, woken: false))

  /// The drain, off both the main thread and the cooperative pool. `process`
  /// blocks on a pipe read and `waitUntilExit` for up to 30 s, which is exactly
  /// what the cooperative pool's threads are not allowed to do. .utility keeps a
  /// burst of screenshots from competing with the poller (FR-4.4).
  private let queue = DispatchQueue(label: "com.clipflow.ocr", qos: .utility)

  private init() {}

  /// Starts the drain if it isn't already going. Called on launch for leftover
  /// work (FR-4.5) and after each image capture for new work.
  func wake() {
    let started = state.withLock { state -> Bool in
      state.woken = true
      guard !state.running else { return false }
      state.running = true
      return true
    }
    guard started else { return }

    queue.async { [self] in
      while true {
        // Consumed *before* the scan: anything that arrives from here on sets
        // it again and keeps the drain alive for another pass.
        state.withLock { $0.woken = false }
        while let job = ItemRepository.nextPendingOCR() {
          // Standing down mid-drain leaves the row 'pending' — see `process`.
          // `running` has to be cleared on the way out or a later `wake()` would
          // see a drain that is no longer running and never start one.
          guard process(id: job.id, imagePath: job.imagePath) else {
            state.withLock { $0.running = false }
            return
          }
        }
        let done = state.withLock { state -> Bool in
          guard !state.woken else { return false }
          state.running = false
          return true
        }
        guard !done else { return }
      }
    }
  }

  /// Kills any helper still running, and keeps the drain from starting another.
  ///
  /// A `Process` child outlives its parent on macOS, and the 30 s deadline is a
  /// `DispatchWorkItem` in *this* process — so quitting mid-recognition orphans
  /// the helper with no watchdog left, holding an open descriptor on an image
  /// out of the user's clipboard history. Must be called from
  /// `applicationWillTerminate`. Safe if never called, safe if called twice, and
  /// does not block: SIGTERM has been delivered by the time it returns.
  func shutdown() { OCRHelper.shutdown() }

  /// False means "stand down and leave this row pending" — the helper is not
  /// there at all, so no image can be read and burning the whole queue on
  /// FR-4.3's no-retry rule would be the wrong answer. Every other outcome,
  /// including a crash, is terminal for that one row.
  private func process(id: Int64, imagePath: String) -> Bool {
    let url = ImageStore.url(for: imagePath)

    // Header-only read. Decoding a pathological image to find out it is
    // pathological is exactly what FR-4.6 exists to avoid.
    guard let size = ImageStore.pixelSize(for: imagePath) else {
      ItemRepository.finishOCR(id: id, text: nil, status: .failed)
      return true
    }
    guard max(size.width, size.height) <= Self.maxEdgePixels else {
      NSLog("ClipFlow: skipping OCR for \(size.width)×\(size.height) image (item \(id))")
      ItemRepository.finishOCR(id: id, text: nil, status: .failed)
      return true
    }

    do {
      let text = try OCRHelper.text(in: url)
      ItemRepository.finishOCR(id: id, text: text, status: .done)
    } catch OCRHelper.Failure.cancelled {
      // Quitting is not the item's fault. FR-4.3's one-attempt rule is about
      // images Vision cannot read; failing this row would spend the attempt on
      // a helper we killed ourselves, so it stays 'pending' for FR-4.5.
      return false
    } catch OCRHelper.Failure.missing {
      // A build that shipped without the helper is a packaging mistake, and it
      // is fixable — unlike FR-4.3's `failed`, which is terminal. Marking every
      // queued screenshot unreadable because the binary was left out of the
      // bundle would destroy work the next build could still do, so the row
      // stays 'pending' and FR-4.5 picks it up on the next launch.
      NSLog("ClipFlow: OCR helper missing from the app bundle — item \(id) left pending")
      return false
    } catch {
      // FR-4.3: no retry. A file that Vision cannot read now will not become
      // readable, and a retry loop on a corrupt PNG is a background CPU leak.
      // A helper that crashed or hit the deadline lands here too, deliberately:
      // one attempt, ever, is the rule for the item — not for the queue.
      NSLog("ClipFlow: OCR failed for item \(id): \(error)")
      ItemRepository.finishOCR(id: id, text: nil, status: .failed)
    }
    return true
  }
}

/// Recognition, run in a short-lived child process rather than in-process.
///
/// Vision's model peaks at 113 MB and leaves ~25 MB resident for the life of
/// whatever loads it, against a 60 MB budget (DECISIONS D-9). Exiting is the
/// only thing that gives that back, so the work goes somewhere that can exit.
///
/// A pipe, not XPC: one path in, text out, nothing kept between images. XPC
/// would buy a service lifetime, which is exactly the cost being avoided.
enum OCRHelper {
  enum Failure: Error {
    /// The binary is not beside ours. Distinct from a failed recognition
    /// because the two deserve opposite treatment — see `OCRQueue.process`.
    case missing
    case exited(code: Int32)
    /// The app is quitting and we killed the helper. Leaves the row 'pending'
    /// for the same reason `missing` does — see `OCRQueue.process`.
    case cancelled
  }

  private static let name = "ClipFlowOCR"

  // The live child, so `shutdown()` can reach it. Swift 5 language mode (S-18),
  // and the only readers are the single drain queue and the terminating main
  // thread, so a lock and two vars beat any of the Sendable-shaped alternatives.
  private static let lock = NSLock()
  private static var current: Process?
  private static var shuttingDown = false

  /// Idempotent. Terminating a `Process` that was never launched raises an
  /// ObjC exception, so `text(in:)` only ever registers one after `run()`.
  static func shutdown() {
    lock.lock()
    shuttingDown = true
    let child = current
    lock.unlock()
    child?.terminate()
  }

  /// Generous against D-8's measured 0.22–0.40 s, because this also covers a
  /// process spawn and a cold model load. Its only job is to stop a wedged
  /// helper hanging the queue forever, so it is sized to never fire in normal
  /// use rather than to enforce FR-4.6's latency target.
  private static let timeout: TimeInterval = 30

  /// Beside our own executable, never an absolute path: inside the bundle that
  /// resolves to `Contents/MacOS/ClipFlowOCR`, and under `make debug` to
  /// `.build/debug/ClipFlowOCR`, with no build-time knowledge of either.
  static var url: URL? {
    guard let executable = Bundle.main.executableURL else { return nil }
    let helper = executable.deletingLastPathComponent().appending(path: name)
    return FileManager.default.isExecutableFile(atPath: helper.path) ? helper : nil
  }

  // ponytail: blocking, not async — and it must stay off the cooperative pool
  // for that reason. It is called from the one serial drain queue and there is
  // never a second recognition in flight, so an async wrapper would be plumbing
  // around a queue that is already serial by construction.
  static func text(in image: URL) throws -> String {
    guard let helper = url else { throw Failure.missing }

    let process = Process()
    process.executableURL = helper
    process.arguments = [image.path]
    let output = Pipe()
    process.standardOutput = output
    // Inherited rather than piped: the helper's diagnostics reach the same log
    // as ours, and a second pipe would need a second reader to avoid deadlocking
    // against the one below.
    process.standardError = FileHandle.standardError
    try process.run()

    // Registered after run(), never before. A shutdown that lands in the gap is
    // caught by the flag and terminated here instead.
    lock.lock()
    current = process
    let alreadyQuitting = shuttingDown
    lock.unlock()
    if alreadyQuitting { process.terminate() }

    // terminate() closes the child's end of the pipe, which is what releases the
    // read below — without it a wedged helper blocks this thread indefinitely.
    let deadline = DispatchWorkItem { process.terminate() }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)

    // Read to EOF *before* waiting: a page of OCR text exceeds the pipe buffer,
    // and waiting first would deadlock against a helper blocked on write.
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    deadline.cancel()

    lock.lock()
    current = nil
    let cancelled = shuttingDown
    lock.unlock()
    // Only when it did not finish on its own: a helper that exited 0 before the
    // quit landed produced real text, and throwing that away would be a loss.
    if cancelled && process.terminationStatus != 0 { throw Failure.cancelled }

    guard process.terminationStatus == 0 else {
      throw Failure.exited(code: process.terminationStatus)
    }
    return String(decoding: data, as: UTF8.self)
  }
}
