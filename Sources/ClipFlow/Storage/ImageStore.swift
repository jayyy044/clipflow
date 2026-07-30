import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Where image payloads live. FR-2.2: the bytes go to disk and the database
/// stores only the path, relative to the support directory.
enum ImageStore {
  /// The `.noindex` suffix is load-bearing, not cosmetic: without it Spotlight
  /// indexes every clipboard screenshot into system-wide search
  /// (DECISIONS S-15).
  static let directory = Database.directory.appending(path: "images.noindex", directoryHint: .isDirectory)

  /// 96 pt at 2x, which covers a list row on a Retina display with room for a
  /// wide 16:9 screenshot. Small enough that a full list of them stays well
  /// inside the memory budget (DECISIONS D-6).
  private static let thumbnailMaxPixelSize = 192

  /// Thumbnails are read from disk on every render pass, so they get cached —
  /// but bounded, because 500 decoded thumbnails resident would eat the budget
  /// the on-disk cache was meant to protect.
  private static let thumbnails: NSCache<NSString, NSImage> = {
    let cache = NSCache<NSString, NSImage>()
    cache.countLimit = 80
    return cache
  }()

  struct Stored {
    let relativePath: String
    let pixelWidth: Int
    let pixelHeight: Int
  }

  static func url(for relativePath: String) -> URL {
    Database.directory.appending(path: relativePath)
  }

  /// Writes the PNG plus its thumbnail and returns the path to record on the row.
  /// The thumbnail is generated here, at insert time, rather than lazily in the
  /// list (PRD HP-5) and lands next to the original so it survives relaunch
  /// (DECISIONS S-14).
  static func save(png: Data) -> Stored? {
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let name = UUID().uuidString
    let relativePath = "\(directory.lastPathComponent)/\(name).png"
    let file = url(for: relativePath)
    guard (try? png.write(to: file)) != nil else { return nil }

    guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
          let size = pixelSize(of: source)
    else {
      try? FileManager.default.removeItem(at: file)
      return nil
    }

    writeThumbnail(from: source, to: thumbnailURL(for: relativePath))

    return Stored(relativePath: relativePath, pixelWidth: size.width, pixelHeight: size.height)
  }

  /// Dimensions from the file header — no pixels decoded, which is the point:
  /// FR-4.6 has to reject an oversized image *without* paying to open it.
  static func pixelSize(for relativePath: String) -> (width: Int, height: Int)? {
    guard let source = CGImageSourceCreateWithURL(url(for: relativePath) as CFURL, nil) else { return nil }
    return pixelSize(of: source)
  }

  private static func pixelSize(of source: CGImageSource) -> (width: Int, height: Int)? {
    guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int,
          let height = properties[kCGImagePropertyPixelHeight] as? Int
    else { return nil }
    return (width, height)
  }

  static func data(for relativePath: String) -> Data? {
    try? Data(contentsOf: url(for: relativePath))
  }

  /// What the list draws. Reads the cached thumbnail only — never the
  /// full-resolution file (FR-6.7).
  static func thumbnail(for relativePath: String) -> NSImage? {
    if let cached = thumbnails.object(forKey: relativePath as NSString) { return cached }
    guard let image = NSImage(contentsOf: thumbnailURL(for: relativePath)) else { return nil }
    thumbnails.setObject(image, forKey: relativePath as NSString)
    return image
  }

  /// Deleting a row and deleting its files are two operations, so a crash
  /// between them leaks bytes forever. Sweeping on launch is the cheap fix
  /// (DECISIONS S-17).
  static func sweepOrphans(referencedBy paths: Set<String>) {
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
    // A referenced original keeps its thumbnail alive, which is why the live set
    // is built from both names rather than matching the file list directly.
    let live = Set(paths.flatMap {
      [url(for: $0).lastPathComponent, thumbnailURL(for: $0).lastPathComponent]
    })
    for name in names where !live.contains(name) {
      try? FileManager.default.removeItem(at: directory.appending(path: name))
      NSLog("ClipFlow: swept orphaned image \(name)")
    }
  }

  private static func thumbnailURL(for relativePath: String) -> URL {
    let original = url(for: relativePath)
    return original
      .deletingLastPathComponent()
      .appending(path: "\(original.deletingPathExtension().lastPathComponent)_thumb.png")
  }

  /// `CGImageSourceCreateThumbnailAtIndex` decodes straight to the target size.
  /// Decoding a 6K screenshot full-res and then downscaling it is what blows the
  /// memory budget (PRD HP-5).
  private static func writeThumbnail(from source: CGImageSource, to file: URL) {
    guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: thumbnailMaxPixelSize,
    ] as CFDictionary),
    let destination = CGImageDestinationCreateWithURL(
      file as CFURL, UTType.png.identifier as CFString, 1, nil
    )
    else { return }
    CGImageDestinationAddImage(destination, thumbnail, nil)
    CGImageDestinationFinalize(destination)
  }
}
