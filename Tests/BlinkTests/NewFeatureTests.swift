import XCTest
@testable import Blink

final class ClipboardTests: XCTestCase {
    var board: NSPasteboard!
    var history: ClipboardHistory!

    override func setUp() {
        board = NSPasteboard(name: NSPasteboard.Name("blink-test-\(UUID().uuidString)"))
        history = ClipboardHistory(url: makeTempDir().appendingPathComponent("clipboard.json"), pasteboard: board,
                                   maxItems: 3, ignoreApps: ["com.1password.1password"])
    }

    override func tearDown() { board.releaseGlobally() }

    func copy(_ text: String, private: Bool = false) {
        board.clearContents()
        board.setString(text, forType: .string)
        if `private` { board.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) }
    }

    func testRecordsTextWithTheAppItCameFrom() {
        copy("hello world")
        history.capture(bundleID: "com.apple.Notes", appName: "Notes")
        XCTAssertEqual(history.entries.map(\.value), ["hello world"])
        XCTAssertEqual(history.entries.first?.app, "Notes")
    }

    func testSkipsPasswordsAndIgnoredApps() {
        copy("hunter2", private: true)
        history.capture(bundleID: "com.apple.Safari", appName: "Safari")
        copy("secret from 1Password")
        history.capture(bundleID: "com.1password.1password", appName: "1Password")
        copy("   \n ")
        history.capture(bundleID: nil, appName: nil)
        XCTAssertTrue(history.entries.isEmpty)
    }

    func testCopyingAgainMovesToTopAndOldOnesDropOff() {
        for t in ["a", "b", "c", "a", "d"] {
            copy(t)
            history.capture(bundleID: nil, appName: nil)
        }
        XCTAssertEqual(history.entries.map(\.value), ["d", "a", "c"], "newest first, no duplicates, only 3 kept")
    }

    func testPinnedEntriesSurviveTrimmingAndClearing() {
        copy("keep me")
        history.capture(bundleID: nil, appName: nil)
        let pinned = "clip." + history.entries[0].id
        history.keep = { $0 == pinned }
        for t in ["1", "2", "3", "4"] {
            copy(t)
            history.capture(bundleID: nil, appName: nil)
        }
        XCTAssertTrue(history.entries.contains { $0.value == "keep me" })
        history.clear()
        XCTAssertEqual(history.entries.map(\.value), ["keep me"])
    }

    func testHistoryIsSavedToDisk() {
        let file = makeTempDir().appendingPathComponent("clipboard.json")
        let h = ClipboardHistory(url: file, pasteboard: board)
        copy("persist")
        h.capture(bundleID: nil, appName: nil)
        let saved = expectation(description: "saved")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { saved.fulfill() }
        wait(for: [saved], timeout: 2)
        XCTAssertEqual(ClipboardHistory(url: file, pasteboard: board).entries.map(\.value), ["persist"])
    }

    func testWritingBackDoesntCreateADuplicate() {
        copy("x")
        history.capture(bundleID: nil, appName: "Notes")
        copy("y")
        history.capture(bundleID: nil, appName: nil)
        history.write(history.entries[1])
        history.poll()  // the change Blink made itself isn't recorded again
        XCTAssertEqual(history.entries.map(\.value), ["x", "y"])
        XCTAssertEqual(board.string(forType: .string), "x")
    }

    func testProviderSearchAndActions() {
        for (t, app) in [("brew install fd", "Terminal"), ("https://example.com", "Chrome"), ("Line one\nLine two", "Notes")] {
            copy(t)
            history.capture(bundleID: nil, appName: app)
        }
        let p = ClipboardProvider(keyword: "clip", history: history)
        XCTAssertEqual(p.search("").count, 3)
        XCTAssertEqual(p.search("brew").map(\.title), ["brew install fd"])
        XCTAssertEqual(p.search("chrome").map(\.title), ["https://example.com"], "matches the source app too")
        let multi = p.search("line").first
        XCTAssertEqual(multi?.title, "Line one")
        XCTAssertTrue(multi?.subtitle.contains("2 lines") ?? false)
        XCTAssertEqual(multi?.actions.map(\.title), ["Paste", "Copy", "Delete"])
        XCTAssertEqual(Pins.key(for: multi!.id), multi!.id, "clipboard entries can be pinned")
    }
}

final class AlfredCompatibilityTests: XCTestCase {
    let dir = makeTempDir()

    func provider(_ action: ScriptProvider.ArgAction = .auto) -> ScriptProvider {
        ScriptProvider(name: "Test", keyword: "t", launch: ["/bin/echo"], passQuery: { [$0] }, workingDir: dir,
                       argAction: action, source: "test")
    }

    func testArgOpensURLsAndPathsOtherwiseCopies() {
        let p = provider()
        guard case .open(let u)? = p.parse(["title": "Site", "arg": "https://example.com"], index: 0)?.action else { return XCTFail() }
        XCTAssertEqual(u.absoluteString, "https://example.com")
        guard case .open(let f)? = p.parse(["title": "Apps", "arg": "/Applications"], index: 0)?.action else { return XCTFail() }
        XCTAssertEqual(f.path, "/Applications")
        guard case .copy(let c)? = p.parse(["title": "Word", "arg": "hello"], index: 0)?.action else { return XCTFail() }
        XCTAssertEqual(c, "hello")
    }

    func testInvalidItemsAutocompleteAndModsBecomeAltActions() {
        let p = provider()
        let item = p.parse(["uid": "x", "title": "More…", "valid": false, "autocomplete": "deeper "], index: 0)
        guard case .complete(let text)? = item?.action else { return XCTFail("valid:false should autocomplete") }
        XCTAssertEqual(text, "t deeper ")
        XCTAssertEqual(item?.id, "plugin.t.x")
        let withMod = p.parse(["title": "A", "arg": "one", "mods": ["cmd": ["arg": "https://alt.example"]]], index: 0)
        guard case .open(let alt)? = withMod?.altAction else { return XCTFail("cmd mod should be the ⌘↩ action") }
        XCTAssertEqual(alt.host, "alt.example")
    }

    func testWorkflowNextStepDecidesWhatArgDoes() {
        guard case .open(let u)? = provider(.openURL("https://duck.com/?q={query}")).parse(["title": "x", "arg": "a b"], index: 0)?.action
        else { return XCTFail() }
        XCTAssertEqual(u.absoluteString, "https://duck.com/?q=a%20b")
        guard case .copy(let c)? = provider(.copy("Result: {query}")).parse(["title": "x", "arg": "42"], index: 0)?.action
        else { return XCTFail() }
        XCTAssertEqual(c, "Result: 42")
    }

    func testIconsAndTextCopy() {
        let p = provider()
        let item = p.parse(["title": "x", "arg": "y", "icon": ["type": "fileicon", "path": "/Applications/Safari.app"],
                            "text": ["copy": "copied text"]], index: 0)
        guard case .file(let path)? = item?.icon else { return XCTFail("fileicon should use the file's icon") }
        XCTAssertEqual(path, "/Applications/Safari.app")
        XCTAssertEqual(item?.actions.map(\.title), ["Open", "Copy"])
    }

    /// A real (tiny) workflow: a bash Script Filter whose results open a URL.
    func testImportsAndRunsAWorkflow() throws {
        let folder = dir.appendingPathComponent("user.workflow.TEST")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "bundleid": "com.example.test", "name": "Test Workflow",
            "objects": [
                ["uid": "SF", "type": "alfred.workflow.input.scriptfilter",
                 "config": ["keyword": "tw", "type": 0, "scriptargtype": 1, "title": "Test Search",
                            "script": #"echo "{\"items\":[{\"title\":\"You typed $1\",\"arg\":\"$1\"}]}""#]],
                ["uid": "URL", "type": "alfred.workflow.action.openurl", "config": ["url": "https://example.com/?q={query}"]],
            ],
            "connections": ["SF": [["destinationuid": "URL"]]],
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: folder.appendingPathComponent("info.plist"))
        let loaded = AlfredWorkflows.load(folder)
        XCTAssertEqual(loaded.map(\.keyword), ["tw"])
        XCTAssertEqual(loaded.first?.name, "Test Search")
        let results = loaded.first?.search("cats") ?? []
        XCTAssertEqual(results.map(\.title), ["You typed cats"])
        guard case .open(let u)? = results.first?.action else { return XCTFail("should follow the Open URL step") }
        XCTAssertEqual(u.absoluteString, "https://example.com/?q=cats")
    }

    func testDisabledOrBrokenWorkflowsAreSkipped() throws {
        let broken = dir.appendingPathComponent("broken")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("not a plist".utf8).write(to: broken.appendingPathComponent("info.plist"))
        XCTAssertTrue(AlfredWorkflows.load(broken).isEmpty)
        XCTAssertTrue(AlfredWorkflows.load(dir.appendingPathComponent("missing")).isEmpty)
    }
}

final class ConfigAndHotKeyTests: XCTestCase {
    func testOldConfigFilesGetNewDefaults() throws {
        let old = #"{"hotkey": "ctrl+option+space", "shortcuts": {"m": "mes"}}"#
        let c = try JSONDecoder().decode(Config.self, from: Data(old.utf8))
        XCTAssertEqual(c.hotkey, "ctrl+option+space")
        XCTAssertTrue(c.launchAtLogin)
        XCTAssertTrue(c.clipboard.enabled)
        XCTAssertEqual(c.clipboard.hotkey, "cmd+option+c")
        XCTAssertEqual(c.shortcuts, ["m": "mes"], "your own short codes are kept as they are")
    }

    func testConfigRoundTrips() throws {
        var c = Config()
        c.clipboard.maxItems = 500
        c.searches.append(SearchEngine(keyword: "ddg", name: "DuckDuckGo", url: "https://duck.com/?q={query}"))
        let back = try JSONDecoder().decode(Config.self, from: Config.encoder.encode(c))
        XCTAssertEqual(back, c)
    }

    func testShortcutRecorderSpellingRoundTrips() {
        let spec = HotKey.spec(keyCode: 9, flags: [.command, .shift])  // V
        XCTAssertEqual(spec, "shift+cmd+v")
        XCTAssertEqual(HotKey.parse(spec!)?.key, 9)
        XCTAssertNil(HotKey.spec(keyCode: 9, flags: []), "a bare key isn't a global shortcut")
        XCTAssertEqual(HotKey.display("cmd+option+c"), "⌥⌘C")
        XCTAssertEqual(HotKey.display("cmd+space"), "⌘Space")
    }
}

final class SettingsModelTests: XCTestCase {
    func testAddingAShortCodeSavesIt() {
        var saved: [Config] = []
        let model = SettingsModel(config: Config(), plugins: [], save: { saved.append($0) },
                                  suspendHotkeys: { _ in }, clearClipboard: {}, importWorkflow: { _ in true })
        model.config.shortcuts["gh"] = "gh"
        model.config.shortcuts["y"] = "yt"  // two quick edits → one save
        let done = expectation(description: "debounced save")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { done.fulfill() }
        wait(for: [done], timeout: 3)
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.last?.shortcuts["gh"], "gh")
        XCTAssertEqual(saved.last?.shortcuts["y"], "yt")
        XCTAssertTrue(model.keywords.contains("yt"), "short codes can point at any search keyword")
    }
}

final class CodeMigrationTests: XCTestCase {
    func testOldLongKeywordsBecomeTheirShortCodes() throws {
        let old = #"{"messagesKeyword": "mes", "clipboard": {"keyword": "clip"}, "shortcuts": {"m": "mes", "v": "clip", "x": "g", "msg": "mes"}}"#
        var c = try JSONDecoder().decode(Config.self, from: Data(old.utf8))
        let renames = c.migrateCodes()
        XCTAssertEqual(c.messagesKeyword, "m")
        XCTAssertEqual(c.clipboard.keyword, "v")
        XCTAssertEqual(c.shortcuts, ["x": "g", "msg": "m"], "your own extra codes stay, pointing at the new code")
        XCTAssertEqual(renames, ["mes": "m", "clip": "v"])
        XCTAssertEqual(c.searches.first?.keyword, "g", "searches are never renamed")
    }

    func testNothingToDoForNewOrCustomConfigs() throws {
        var fresh = Config()
        XCTAssertTrue(fresh.migrateCodes().isEmpty)
        XCTAssertEqual(fresh.messagesKeyword, "m")
        var custom = try JSONDecoder().decode(Config.self, from: Data(#"{"messagesKeyword": "text"}"#.utf8))
        XCTAssertTrue(custom.migrateCodes().isEmpty)
        XCTAssertEqual(custom.messagesKeyword, "text")
    }

    func testPinsFollowTheRename() {
        let pins = tempPins()
        pins.toggle("keyword.mes")
        pins.toggle("app.x")
        pins.renameKeyword("mes", to: "m")
        XCTAssertEqual(pins.ids, ["keyword.m", "app.x"])
    }
}
