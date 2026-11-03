import AppKit

// A menu bar app: no Dock icon, no main window. `--e2e` runs the end-to-end
// check instead (`make test-e2e`, see E2E.swift).
let app = NSApplication.shared
let delegate: NSApplicationDelegate = CommandLine.arguments.contains("--e2e") ? E2ERun() : AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
