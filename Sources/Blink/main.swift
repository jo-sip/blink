import AppKit

/// BLINK_MESSAGES_DB / BLINK_FAKE_CONTACTS swap in a made-up Messages database and contacts
/// (scripts/screenshots.sh uses them, so screenshots never show real conversations).
func makeMessages(_ config: Config) -> MessagesProvider {
    let env = ProcessInfo.processInfo.environment
    guard let db = env["BLINK_MESSAGES_DB"] else {
        return MessagesProvider(keyword: config.messagesKeyword, includeUnknown: config.messagesIncludeUnknownSenders,
                                pinMinutes: config.messagesPinMinutes)
    }
    let contacts = env["BLINK_FAKE_CONTACTS"]
    return MessagesProvider(keyword: config.messagesKeyword, includeUnknown: config.messagesIncludeUnknownSenders,
                            pinMinutes: config.messagesPinMinutes, dbPath: db, loadContacts: { ContactIndex.fake(from: contacts) })
}

func makeProviders(_ config: Config, clipboard: ClipboardHistory? = nil) -> (all: [Provider], apps: AppsProvider) {
    let apps = AppsProvider(extraDirs: config.extraAppDirs)
    var all: [Provider] = [
        apps,
        CalculatorProvider(),
        PlacesProvider(paths: config.places),
        URLProvider(),
        WebFallbackProvider(engine: config.searches.first),
        FilesProvider(config: config.files),
        makeMessages(config),
    ]
    if config.clipboard.enabled, let clipboard {
        all.append(ClipboardProvider(keyword: config.clipboard.keyword, history: clipboard))
    }
    all += config.searches.map { SearchEngineProvider(engine: $0) } as [Provider]
    all += ScriptProvider.discover() as [Provider]
    all += AlfredWorkflows.discover() as [Provider]
    return (all, apps)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var launcher: Launcher!
    private var hotKey: HotKey?
    private var clipHotKey: HotKey?
    private var status: NSStatusItem!
    private var config = Config()
    private var providers: [Provider] = []
    private let settings = SettingsWindow()
    private lazy var clipboard: ClipboardHistory = {
        let h = ClipboardHistory(url: Paths.data.appendingPathComponent("clipboard.json"))
        h.keep = { Pins.shared.contains($0) }
        return h
    }()

    private var conflictTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.installCrashHandler()
        Config.onKeywordRename = { Pins.shared.renameKeyword($0, to: $1) }
        Log.write("launched \(Bundle.main.bundlePath)")
        buildEditMenu()
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "Blink")
        reload()
        if let i = CommandLine.arguments.firstIndex(of: "--show") {
            // Debug aid: open the launcher at startup, optionally with a query.
            let arg = CommandLine.arguments.dropFirst(i + 1).first ?? ""
            if arg.hasPrefix("settings") {
                openSettings(tab: arg.hasPrefix("settings:") ? String(arg.dropFirst(9)) : nil)
            } else if arg == "demo-live" {
                launcher.demoLive()
            } else if arg.hasPrefix("mode:") {
                launcher.showMode(String(arg.dropFirst(5)))
            } else if arg.hasPrefix("type:") {
                launcher.typeSequence(arg.dropFirst(5).split(separator: ",").map(String.init))
            } else if arg == "demo-prompt" { launcher.demoPrompt() } else if arg == "demo-pinned" {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.launcher.demoPinned() }
            } else { launcher.show(query: arg) }
        }
    }

    @objc private func reload() {
        config = Config.load()
        clipboard.maxItems = config.clipboard.maxItems
        clipboard.ignoreApps = Set(config.clipboard.ignoreApps)
        if config.clipboard.enabled { clipboard.start() } else { clipboard.stop() }
        let p = makeProviders(config, clipboard: clipboard)
        providers = p.all
        launcher?.hide()
        launcher = Launcher(engine: Engine(providers: p.all, maxResults: config.maxResults, globalLimit: config.files.defaultResultsLimit, aliases: config.shortcuts), maxRows: config.visibleRows)
        launcher.onOpenSettings = { [weak self] in self?.openSettings(tab: nil) }
        p.apps.onReindex = { [weak self] in self?.launcher.dataChanged() }
        p.apps.refresh()
        registerHotkeys()
        LaunchAtLogin.apply(config.launchAtLogin)
        buildMenu()
        conflictTimer?.invalidate()
        conflictTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.buildMenu() }
    }

    private func registerHotkeys() {
        hotKey = nil  // releasing the old ones unregisters them
        clipHotKey = nil
        hotKey = HotKey(spec: config.hotkey) { [weak self] in
            Log.write("hotkey pressed")
            self?.launcher.toggle()
        }
        Log.write(hotKey != nil ? "hotkey \(config.hotkey) registered" : "hotkey \(config.hotkey) could NOT be registered")
        if config.clipboard.enabled {
            let kw = config.clipboard.keyword
            clipHotKey = HotKey(spec: config.clipboard.hotkey) { [weak self] in self?.launcher.showMode(kw) }
            if clipHotKey == nil { Log.write("clipboard hotkey \(config.clipboard.hotkey) could NOT be registered") }
        }
    }

    /// While a shortcut is being recorded in Settings, Blink's own hotkeys stand aside.
    private func suspendHotkeys(_ suspended: Bool) {
        if suspended {
            hotKey = nil
            clipHotKey = nil
        } else {
            registerHotkeys()
        }
    }

    private var settingsModel: SettingsModel?

    @objc private func openSettingsFromMenu() { openSettings(tab: nil) }

    private func openSettings(tab: String?) {
        launcher.hide()
        let plugins = providers.compactMap { $0 as? ScriptProvider }.map { ($0.name, $0.keyword ?? "", $0.source) }
        let model = SettingsModel(
            config: config, plugins: plugins,
            save: { [weak self] new in
                new.save()
                Log.write("settings saved")
                self?.reload()
            },
            suspendHotkeys: { [weak self] in self?.suspendHotkeys($0) },
            clearClipboard: { [weak self] in self?.clipboard.clear() },
            importWorkflow: { [weak self] url in
                let ok = AlfredWorkflows.importFile(url)
                if ok { self?.reload() }
                return ok
            })
        if let tab { model.initialTab = tab }
        settingsModel = model
        settings.show(model: model)
    }

    @objc private func clearClipboard() {
        let alert = NSAlert()
        alert.messageText = "Clear clipboard history?"
        alert.informativeText = "Pinned entries are kept. This can’t be undone."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { clipboard.clear() }
    }

    private var lastConflict: Bool?

    /// Spotlight takes ⌘Space first when its own shortcut is on, so say so in the menu bar.
    private var hasSpotlightConflict: Bool {
        guard let parsed = HotKey.parse(config.hotkey) else { return false }
        return parsed.key == 49 && parsed.mods == 256 && spotlightUsesCmdSpace()  // space, cmd
    }

    private func buildMenu() {
        let conflict = hasSpotlightConflict
        if conflict != lastConflict {
            Log.write(conflict ? "Spotlight's ⌘Space shortcut is on, so it gets the key before Blink" : "no Spotlight shortcut conflict")
            lastConflict = conflict
        }
        status.button?.image = NSImage(systemSymbolName: conflict ? "exclamationmark.triangle.fill" : "bolt.fill",
                                       accessibilityDescription: "Blink")
        let menu = NSMenu()
        if conflict {
            menu.addItem(withTitle: "⚠︎ Spotlight is using ⌘Space, so Blink can’t. Fix…", action: #selector(openShortcuts), keyEquivalent: "").target = self
            menu.addItem(.separator())
        }
        let title = hotKey != nil ? "Show Blink (\(HotKey.display(config.hotkey)))" : "Show Blink (hotkey “\(config.hotkey)” unavailable)"
        menu.addItem(withTitle: title, action: #selector(showLauncher), keyEquivalent: "").target = self
        if config.clipboard.enabled {
            menu.addItem(withTitle: "Clipboard History (\(HotKey.display(config.clipboard.hotkey)))", action: #selector(showClipboard), keyEquivalent: "").target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettingsFromMenu), keyEquivalent: ",").target = self
        if config.clipboard.enabled {
            menu.addItem(withTitle: "Clear Clipboard History…", action: #selector(clearClipboard), keyEquivalent: "").target = self
        }
        menu.addItem(withTitle: "Open Config Folder", action: #selector(openConfig), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Open Log", action: #selector(openLog), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Reload Config and Plugins", action: #selector(reload), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Blink", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        status.menu = menu
    }

    @objc private func showLauncher() { launcher.show() }
    @objc private func showClipboard() { launcher.showMode(config.clipboard.keyword) }
    @objc private func openConfig() { NSWorkspace.shared.open(Config.dir) }
    @objc private func openLog() { NSWorkspace.shared.open(Log.url) }
    @objc private func openShortcuts() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
    }

    /// An agent app has no visible menu bar, but cut/copy/paste shortcuts still route through the main menu.
    private func buildEditMenu() {
        let main = NSMenu()
        let item = NSMenuItem()
        main.addItem(item)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        item.submenu = edit
        NSApp.mainMenu = main
    }
}

// `Blink --query "text"` prints results without the UI; `--bench` times the per-keystroke path.
let args = CommandLine.arguments
if let i = args.firstIndex(of: "--query"), i + 1 < args.count {
    let p = makeProviders(Config.load(), clipboard: ClipboardHistory(url: Paths.data.appendingPathComponent("clipboard.json")))
    p.apps.scanNow()
    let cfg = Config.load()
    let engine = Engine(providers: p.all, maxResults: cfg.maxResults, globalLimit: cfg.files.defaultResultsLimit, aliases: cfg.shortcuts)
    let start = DispatchTime.now()
    let results = engine.resultsSync(args[i + 1])
    let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
    for r in results { print("\(r.score)\t\(r.title)\t\(r.badge ?? "")\t\(r.subtitle)") }
    FileHandle.standardError.write(String(format: "%d results in %.3f ms\n", results.count, ms).data(using: .utf8)!)
    if args.contains("--bench") {
        let runs = 2000
        let t = DispatchTime.now()
        for _ in 0..<runs { _ = engine.resultsSync(args[i + 1]) }
        let each = Double(DispatchTime.now().uptimeNanoseconds - t.uptimeNanoseconds) / 1_000 / Double(runs)
        FileHandle.standardError.write(String(format: "bench: %.1f µs per query\n", each).data(using: .utf8)!)
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
