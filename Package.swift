// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "ClipFlow",
  platforms: [.macOS(.v15)],
  dependencies: [
    .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
    .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.0.0"),
  ],
  targets: [
    .executableTarget(
      name: "ClipFlow",
      dependencies: [
        .product(name: "GRDB", package: "GRDB.swift"),
        "KeyboardShortcuts",
      ],
      // ponytail: Swift 5 language mode. Vision/CGImage are Sendable-hostile and
      // fighting strict concurrency now costs more than it catches (DECISIONS S-18).
      // Flip to .v6 once the OCR queue in Phase 7 is settled.
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    // A second executable purely so Vision's model is unloaded by exiting
    // (DECISIONS D-9). The Makefile puts it inside the .app next to the main
    // binary; the app finds it relative to its own executable, never by path.
    //
    // Same Swift 5 language mode and the same reason (S-18): this is precisely
    // the code that touches the Sendable-hostile Vision types.
    .executableTarget(
      name: "ClipFlowOCR",
      swiftSettings: [.swiftLanguageMode(.v5)]
    ),
  ]
)
