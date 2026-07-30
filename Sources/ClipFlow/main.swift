import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Equivalent of LSUIElement, but works when running the bare SPM executable too:
// menu bar only, no Dock icon, no app menu.
app.setActivationPolicy(.accessory)
app.run()
