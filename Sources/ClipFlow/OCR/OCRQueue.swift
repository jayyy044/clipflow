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

  // ponytail: one lock around a single bool, guaranteeing at most one drain in
  // flight. `OSAllocatedUnfairLock` rather than `NSLock` because this is taken
  // from an async context, where NSLock is unavailable.
  private let running = OSAllocatedUnfairLock(initialState: false)

  private init() {}

  /// Starts the drain if it isn't already going. Called on launch for leftover
  /// work (FR-4.5) and after each image capture for new work.
  func wake() {
    let started = running.withLock { running -> Bool in
      guard !running else { return false }
      running = true
      return true
    }
    guard started else { return }

    // Detached rather than a child task: the caller is the main actor, and a
    // task inheriting that context would put Vision on the UI thread. .utility
    // is what keeps a burst of screenshots from competing with the poller.
    Task.detached(priority: .utility) { [self] in
      while true {
        while let job = ItemRepository.nextPendingOCR() {
          // Standing down mid-drain leaves the row 'pending' — see `process`.
          // The lock has to be cleared on the way out or a later `wake()` would
          // see a drain that is no longer running and never start one.
          guard process(id: job.id, imagePath: job.imagePath) else {
            running.withLock { $0 = false }
            return
          }
        }
        // Re-check under the lock before standing down. A capture that commits
        // its row after the SELECT above but before `running` clears would see
        // running == true, return early, and strand that row until next launch.
        let more = running.withLock { running -> Bool in
          guard ItemRepository.nextPendingOCR() == nil else { return true }
          running = false
          return false
        }
        guard more else { return }
      }
    }
  }

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
  }

  private static let name = "ClipFlowOCR"

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

  // ponytail: blocking, not async. It is called from the one detached drain task
  // and there is never a second recognition in flight, so an async wrapper would
  // be plumbing around a queue that is already serial by construction.
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

    // terminate() closes the child's end of the pipe, which is what releases the
    // read below — without it a wedged helper blocks this thread indefinitely.
    let deadline = DispatchWorkItem { process.terminate() }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)

    // Read to EOF *before* waiting: a page of OCR text exceeds the pipe buffer,
    // and waiting first would deadlock against a helper blocked on write.
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    deadline.cancel()

    guard process.terminationStatus == 0 else {
      throw Failure.exited(code: process.terminationStatus)
    }
    return String(decoding: data, as: UTF8.self)
  }
}
