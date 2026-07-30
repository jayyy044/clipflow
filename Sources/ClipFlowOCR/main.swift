import Foundation
import Vision

/// One image path in, recognised text out, then exit.
///
/// It exists only so that it can die: Vision's recognition model peaks at 113 MB
/// and leaves ~25 MB resident for the life of whatever process loads it, which
/// pushed the app from 24 MB to 46–54 MB against a 60 MB budget (DECISIONS D-9).
/// Nothing here is stateful and nothing is reused between images — that is the
/// point, and it is why this is a plain executable read over a pipe rather than
/// an XPC service, which would keep a process alive to amortise a cost we are
/// trying not to pay.
///
/// Exit codes are the protocol: 0 with the text on stdout, 1 for a recognition
/// failure, 2 for a bad invocation. The caller turns anything non-zero into
/// FR-4.3's terminal `failed`.

guard CommandLine.arguments.count == 2 else {
  FileHandle.standardError.write(Data("usage: ClipFlowOCR <image-path>\n".utf8))
  exit(2)
}

let url = URL(fileURLWithPath: CommandLine.arguments[1])

do {
  // Settings moved verbatim from the app, chosen by running all three
  // configurations over ground-truth screenshots (DECISIONS D-8). Do not tune
  // them here:
  //
  // - `usesLanguageCorrection = false` **overrides FR-4.2, deliberately**.
  //   Correction rewrote `jsonpath={.data}` as `jsonpath={•data}` and split
  //   `NSURLSession.dataTask(with:` into two tokens with a stray space. Code and
  //   logs are what this app is searched for, and dictionary priors are wrong
  //   about both.
  // - `.accurate` measured 0.22–0.40 s per image against a 1.5 s budget, so
  //   `.fast` would trade recall for nothing.
  // - Language pinned rather than detected: on a terminal screenshot, automatic
  //   detection is a coin flip.
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
  let text = observations
    .compactMap { $0.topCandidates(1).first?.string }
    .joined(separator: "\n")
  FileHandle.standardOutput.write(Data(text.utf8))
} catch {
  FileHandle.standardError.write(Data("ClipFlowOCR: \(error)\n".utf8))
  exit(1)
}
