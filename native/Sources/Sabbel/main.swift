import AppKit

// A menu bar app: no Dock icon, no main window. (`--e2e` is reserved for Task 13.)
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
