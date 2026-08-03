// Generates Resources/AppIcon.icns. Not part of any SPM target — run by hand
// when the artwork changes:
//
//     swift Resources/make-icon.swift
//
// The .icns is committed, so a normal `make bundle` never runs this.
import SwiftUI
import AppKit

let canvas: CGFloat = 1024
// macOS icons are not full-bleed: the rounded square occupies 824 of a 1024
// canvas, with a continuous corner radius of ~22.37% of the square.
let inset: CGFloat = 100
let square = canvas - inset * 2

let art = ZStack {
  RoundedRectangle(cornerRadius: square * 0.2237, style: .continuous)
    .fill(LinearGradient(
      colors: [Color(red: 0.35, green: 0.55, blue: 1.0),
               Color(red: 0.30, green: 0.20, blue: 0.85)],
      startPoint: .top, endPoint: .bottom))
    .frame(width: square, height: square)
  Image(systemName: "list.clipboard.fill")
    .font(.system(size: square * 0.46, weight: .medium))
    .foregroundStyle(.white)
}
.frame(width: canvas, height: canvas)

// ImageRenderer is @MainActor; a script's top level is not. This runs on the
// main thread anyway, so assert that rather than spinning up a runloop.
let png = MainActor.assumeIsolated { () -> Data in
  let renderer = ImageRenderer(content: art)
  renderer.scale = 1
  guard let full = renderer.nsImage,
        let tiff = full.tiffRepresentation,
        let rep = NSBitmapImageRep(data: tiff),
        let data = rep.representation(using: .png, properties: [:]) else {
    fatalError("render failed")
  }
  return data
}

let fm = FileManager.default
let root = URL(fileURLWithPath: fm.currentDirectoryPath)
let iconset = root.appendingPathComponent("Resources/AppIcon.iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)

let master = iconset.appendingPathComponent("icon_512x512@2x.png")
try png.write(to: master)

// iconutil wants every size present; sips downsamples from the 1024 master.
for (size, name) in [(16, "icon_16x16"), (32, "icon_16x16@2x"), (32, "icon_32x32"),
                     (64, "icon_32x32@2x"), (128, "icon_128x128"), (256, "icon_128x128@2x"),
                     (256, "icon_256x256"), (512, "icon_256x256@2x"), (512, "icon_512x512")] {
  let p = Process()
  p.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
  p.arguments = ["-z", "\(size)", "\(size)", master.path,
                 "--out", iconset.appendingPathComponent("\(name).png").path]
  p.standardOutput = FileHandle.nullDevice
  try p.run()
  p.waitUntilExit()
}

let icns = Process()
icns.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
icns.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try icns.run()
icns.waitUntilExit()
try? fm.removeItem(at: iconset)
print(icns.terminationStatus == 0 ? "wrote Resources/AppIcon.icns" : "iconutil failed")
