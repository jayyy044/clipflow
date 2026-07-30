import Foundation
import ImageIO
import Vision
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
          await process(id: job.id, imagePath: job.imagePath)
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

  private func process(id: Int64, imagePath: String) async {
    let url = ImageStore.url(for: imagePath)

    // Header-only read. Decoding a pathological image to find out it is
    // pathological is exactly what FR-4.6 exists to avoid.
    guard let size = ImageStore.pixelSize(for: imagePath) else {
      ItemRepository.finishOCR(id: id, text: nil, status: .failed)
      return
    }
    guard max(size.width, size.height) <= Self.maxEdgePixels else {
      NSLog("ClipFlow: skipping OCR for \(size.width)×\(size.height) image (item \(id))")
      ItemRepository.finishOCR(id: id, text: nil, status: .failed)
      return
    }

    do {
      let text = try await VisionRecognizer.text(in: url)
      ItemRepository.finishOCR(id: id, text: text, status: .done)
    } catch {
      // FR-4.3: no retry. A file that Vision cannot read now will not become
      // readable, and a retry loop on a corrupt PNG is a background CPU leak.
      NSLog("ClipFlow: OCR failed for item \(id): \(error.localizedDescription)")
      ItemRepository.finishOCR(id: id, text: nil, status: .failed)
    }
  }
}

/// The Vision call, isolated so that adding a second recognizer behind an
/// availability check stays a change to this one function.
enum VisionRecognizer {
  /// Settings chosen by running all three configurations over ground-truth
  /// screenshots, not from the spec:
  ///
  /// - `usesLanguageCorrection = false` **overrides FR-4.2, deliberately**.
  ///   Correction rewrote `jsonpath={.data}` as `jsonpath={•data}` and split
  ///   `NSURLSession.dataTask(with:` into two tokens with a stray space. It lost
  ///   on two images, tied on the third, and was slower. Code and logs are what
  ///   this app is searched for, and dictionary priors are wrong about both.
  /// - `.accurate` measured 0.22–0.40 s per image against a 1.5 s budget, so
  ///   `.fast` would trade recall for nothing.
  /// - Language pinned rather than detected: on a terminal screenshot,
  ///   automatic detection is a coin flip.
  ///
  /// `RecognizeTextRequest` is the macOS 15 Swift-native form of
  /// `VNRecognizeTextRequest` named by FR-4.2 — same engine, async, Sendable.
  static func text(in url: URL) async throws -> String {
    var request = RecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = false
    request.automaticallyDetectsLanguage = false
    request.recognitionLanguages = [Locale.Language(identifier: "en-US")]

    // The original, never the thumbnail: 192 px of downscaled screenshot has no
    // legible text in it.
    let observations = try await ImageRequestHandler(url).perform(request)
    // `.transcript` would read better but is macOS 26; the floor is 15
    // (Package.swift), and the top candidate per observation is the same text.
    return observations
      .compactMap { $0.topCandidates(1).first?.string }
      .joined(separator: "\n")
  }
}
