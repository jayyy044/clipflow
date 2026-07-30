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
    )
  ]
)
