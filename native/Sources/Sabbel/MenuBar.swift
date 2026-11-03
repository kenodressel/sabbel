import AppKit
import SabbelCore
import SabbelEngine
import SabbelSystem

/// The status item and its menu; the coordinator's `SabbelUI`.
///
/// Menu order matches the Python app: Status, History ▸, Microphone ▸, Show
/// Live Text, the update item (not on dev builds), Copy diagnostics, then the
/// version and Quit.
@MainActor final class MenuBar: NSObject, SabbelUI, NSMenuDelegate {
    weak var coordinator: TakeCoordinator?

    private let version: String
    private let paths: SabbelPaths
    private let historyMaxBytes: Int
    private let notifier: Notifier
    private let updates: UpdateChecker?
    private let log: @Sendable (String) -> Void
    private let livePanel = LivePanel()

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let statusLine = NSMenuItem(title: "Status: Starting", action: nil, keyEquivalent: "")
    private let historyToggle = NSMenuItem(title: "Save history", action: nil, keyEquivalent: "")
    private let micMenu = NSMenu(title: "Microphone")
    private var updateItem: NSMenuItem?
    private var latestVersion: String?

    private static let spinnerFrames = ["◐", "◓", "◑", "◒"]
    private var spinner: Timer?
    private var spinnerIndex = 0

    init(version: String, paths: SabbelPaths, historyEnabled: Bool, historyMaxBytes: Int,
         notifier: Notifier, updates: UpdateChecker?, log: @escaping @Sendable (String) -> Void) {
        self.version = version
        self.paths = paths
        self.historyMaxBytes = historyMaxBytes
        self.notifier = notifier
        self.updates = updates
        self.log = log
        super.init()
        historyToggle.state = historyEnabled ? .on : .off
        buildMenu()
        statusItem.button?.title = "🎙"
    }

    private func item(_ title: String, _ action: Selector?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func buildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        statusLine.isEnabled = false
        menu.addItem(statusLine)

        let history = NSMenu(title: "History")
        historyToggle.target = self
        historyToggle.action = #selector(toggleHistory)
        history.addItem(historyToggle)
        history.addItem(item("Open log", #selector(openHistory)))
        history.addItem(item("Clear log", #selector(clearHistory)))
        let historyItem = NSMenuItem(title: "History", action: nil, keyEquivalent: "")
        historyItem.submenu = history
        menu.addItem(historyItem)

        // Rebuilt every time it opens, so hot-plugged mics show up.
        micMenu.delegate = self
        micMenu.autoenablesItems = false
        let micItem = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        micItem.submenu = micMenu
        menu.addItem(micItem)

        menu.addItem(item("Show Live Text", #selector(showLiveText)))
        if updates != nil {
            let update = item("Check for updates", #selector(updateClicked))
            updateItem = update
            menu.addItem(update)
        }
        menu.addItem(item("Copy diagnostics", #selector(copyDiagnostics)))
        menu.addItem(.separator())
        let versionItem = NSMenuItem(title: "v\(version)", action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)
        menu.addItem(item("Quit", #selector(quit)))
        statusItem.menu = menu
        rebuildMicMenu()
    }

    // MARK: SabbelUI

    func show(_ icon: IconState, status: String) {
        statusLine.title = "Status: \(status)"
        if icon == .working {
            startSpinner()
            return
        }
        stopSpinner()
        switch icon {
        case .idle: statusItem.button?.title = "🎙"
        case .recording: statusItem.button?.title = "🔴"
        case .error(let text): statusItem.button?.title = "⚠️ \(text)"
        case .failed: statusItem.button?.title = "⚠️"
        case .working: break
        }
    }

    func notify(_ notice: Notice) { notifier.post(notice) }

    func live(_ text: LiveText, masked: Bool) { livePanel.update(text, masked: masked) }

    // MARK: icon spinner

    private func startSpinner() {
        guard spinner == nil else { return }
        spinnerIndex = 0
        statusItem.button?.title = Self.spinnerFrames[0]
        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // .common: keep spinning while the menu is open.
        RunLoop.main.add(timer, forMode: .common)
        spinner = timer
    }

    private func tick() {
        spinnerIndex = (spinnerIndex + 1) % Self.spinnerFrames.count
        statusItem.button?.title = Self.spinnerFrames[spinnerIndex]
    }

    private func stopSpinner() {
        spinner?.invalidate()
        spinner = nil
    }

    // MARK: updates

    /// Called when the update check found a newer release.
    func announceUpdate(_ latest: String) {
        latestVersion = latest
        updateItem?.title = "Update v\(latest) available"
        notifier.post(.updateAvailable(latest))
    }

    /// Opens the release page once an update is known; otherwise checks now,
    /// regardless of the daily throttle.
    @objc private func updateClicked() {
        if let latestVersion {
            NSWorkspace.shared.open(Endpoints.releasePage(latestVersion))
            return
        }
        guard let updates else { return }
        Task {
            if let latest = await updates.check(force: true) { announceUpdate(latest) }
        }
    }

    // MARK: history

    @objc private func toggleHistory() {
        guard let coordinator else { return }
        let enabled = !coordinator.historyEnabled
        coordinator.historyEnabled = enabled
        historyToggle.state = enabled ? .on : .off
        do {
            try Preferences.save("history_enabled", enabled, at: paths.preferencesJSON)
        } catch {
            log("Failed to save history_enabled: \(error)")
        }
    }

    @objc private func openHistory() {
        let fm = FileManager.default
        let url = fm.fileExists(atPath: paths.historyLog.path) ? paths.historyLog : paths.configDir
        NSWorkspace.shared.open(url)
    }

    @objc private func clearHistory() {
        do {
            try HistoryLog(url: paths.historyLog, maxBytes: historyMaxBytes).clear()
            notifier.post(.historyCleared)
        } catch {
            log("Failed to clear history: \(error)")
        }
    }

    // MARK: microphone

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === micMenu else { return }
        rebuildMicMenu()
    }

    private func rebuildMicMenu() {
        micMenu.removeAllItems()
        let entries = MicMenu.entries(devices: MicCapture.inputDeviceNames(), selected: coordinator?.audioDevice)
        for entry in entries {
            switch entry {
            case .separator:
                micMenu.addItem(.separator())
            case .offline(let label):
                let header = NSMenuItem(title: label, action: nil, keyEquivalent: "")
                header.isEnabled = false
                micMenu.addItem(header)
            case .device(let name, let label, let checked):
                let choice = item(label, #selector(chooseMic(_:)))
                choice.representedObject = name
                choice.state = checked ? .on : .off
                micMenu.addItem(choice)
            }
        }
    }

    @objc private func chooseMic(_ sender: NSMenuItem) {
        guard let coordinator else { return }
        let name = sender.representedObject as? String
        guard name != coordinator.audioDevice else { return }
        coordinator.audioDevice = name
        do {
            try Preferences.save("audio_device", name, at: paths.preferencesJSON)
        } catch {
            log("Failed to save audio_device: \(error)")
        }
        log("Microphone set to \(name ?? "System Default")")
        rebuildMicMenu()
    }

    // MARK: other items

    @objc private func showLiveText() { livePanel.show() }

    /// Everything a bug report needs, on the clipboard as an ordinary
    /// (non-transient) item so clipboard managers keep it.
    @objc private func copyDiagnostics() {
        let text = buildDiagnostics(version: version, status: coordinator?.status ?? "unknown",
                                    macOS: ProcessInfo.processInfo.operatingSystemVersionString,
                                    engine: EngineInfo.description, configURL: paths.configTOML,
                                    logURL: RuntimeLog.defaultURL)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let copied = pasteboard.setString(text, forType: .string)
        notifier.post(.diagnosticsCopied(copied))
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
