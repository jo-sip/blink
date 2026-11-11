import Foundation

struct SearchEngine: Codable, Equatable, Hashable {
    var keyword: String
    var name: String
    var url: String  // {query} is replaced
    /// Open in this app (e.g. "Google Chrome") instead of the default browser.
    var app: String? = nil
}

/// Where Blink keeps its files. BLINK_CONFIG_DIR / BLINK_DATA_DIR point tests and the smoke script
/// at throwaway folders so they never touch your real config, pins or usage history.
enum Paths {
    static let config: URL = {
        if let dir = ProcessInfo.processInfo.environment["BLINK_CONFIG_DIR"] { return URL(fileURLWithPath: dir) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/blink")
    }()

    static let data: URL = {
        if let dir = ProcessInfo.processInfo.environment["BLINK_DATA_DIR"] { return URL(fileURLWithPath: dir) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Blink")
    }()
}

struct FilesConfig: Codable, Equatable {
    /// Type this, then a space, to search files: "f invoice".
    var keyword = "f"
    /// Folders to search (everything beneath them).
    var scopes = ["~"]
    /// Folder names to skip anywhere in a path.
    var excludes = ["Library", "node_modules", ".git", ".Trash"]
    var maxResults = 20
    /// Also show file matches under apps for ordinary queries (3+ characters).
    var includeInDefaultResults = false
    var defaultResultsLimit = 5

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = FilesConfig()
        keyword = try c.decodeIfPresent(String.self, forKey: .keyword) ?? d.keyword
        scopes = try c.decodeIfPresent([String].self, forKey: .scopes) ?? d.scopes
        excludes = try c.decodeIfPresent([String].self, forKey: .excludes) ?? d.excludes
        maxResults = try c.decodeIfPresent(Int.self, forKey: .maxResults) ?? d.maxResults
        includeInDefaultResults = try c.decodeIfPresent(Bool.self, forKey: .includeInDefaultResults) ?? d.includeInDefaultResults
        defaultResultsLimit = try c.decodeIfPresent(Int.self, forKey: .defaultResultsLimit) ?? d.defaultResultsLimit
    }
}

struct ClipboardConfig: Codable, Equatable {
    var enabled = true
    /// Its code: "v" then Tab (or a space) searches clipboard history.
    var keyword = "v"
    /// Opens Blink straight into clipboard history.
    var hotkey = "cmd+option+c"
    var maxItems = 200
    /// Never record copies made in these apps (bundle identifiers).
    var ignoreApps = ["com.1password.1password", "com.agilebits.onepassword7", "com.apple.keychainaccess",
                      "com.bitwarden.desktop", "com.lastpass.LastPass", "com.apple.Passwords"]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ClipboardConfig()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        keyword = try c.decodeIfPresent(String.self, forKey: .keyword) ?? d.keyword
        hotkey = try c.decodeIfPresent(String.self, forKey: .hotkey) ?? d.hotkey
        maxItems = try c.decodeIfPresent(Int.self, forKey: .maxItems) ?? d.maxItems
        ignoreApps = try c.decodeIfPresent([String].self, forKey: .ignoreApps) ?? d.ignoreApps
    }
}

struct Config: Codable, Equatable {
    var hotkey = "cmd+space"
    var launchAtLogin = true
    var clipboard = ClipboardConfig()
    /// Most results any query returns (the list scrolls).
    var maxResults = 40
    /// Rows shown before the list scrolls.
    var visibleRows = 8
    var files = FilesConfig()
    /// Messages' code: "m" then Tab (or a space).
    var messagesKeyword = "m"
    /// Extra codes on top of each scope's own one: extra code → existing code, e.g. "msg" → "m".
    var shortcuts: [String: String] = [:]
    /// Messages files chats from people you have never replied to under "Unknown Senders"; most are spam or codes.
    var messagesIncludeUnknownSenders = false
    /// Unread messages newer than this many minutes are pinned as "Reply to …" when Blink opens (0 turns it off).
    var messagesPinMinutes = 15
    var extraAppDirs: [String] = []
    /// Folders that show up in every search by name (missing ones are skipped).
    var places = ["~", "~/Desktop", "~/Downloads", "~/Documents", "~/Library/Mobile Documents/com~apple~CloudDocs",
                  "/Applications", "~/Pictures", "~/Movies", "~/Music", "~/Code", "~/.Trash"]
    var searches: [SearchEngine] = [
        SearchEngine(keyword: "g", name: "Google", url: "https://www.google.com/search?q={query}"),
        SearchEngine(keyword: "c", name: "Google in Chrome", url: "https://www.google.com/search?q={query}", app: "Google Chrome"),
        SearchEngine(keyword: "yt", name: "YouTube", url: "https://www.youtube.com/results?search_query={query}"),
        SearchEngine(keyword: "gh", name: "GitHub", url: "https://github.com/search?q={query}"),
        SearchEngine(keyword: "wiki", name: "Wikipedia", url: "https://en.wikipedia.org/w/index.php?search={query}"),
    ]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        hotkey = try c.decodeIfPresent(String.self, forKey: .hotkey) ?? d.hotkey
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
        clipboard = try c.decodeIfPresent(ClipboardConfig.self, forKey: .clipboard) ?? d.clipboard
        maxResults = try c.decodeIfPresent(Int.self, forKey: .maxResults) ?? d.maxResults
        visibleRows = try c.decodeIfPresent(Int.self, forKey: .visibleRows) ?? d.visibleRows
        files = try c.decodeIfPresent(FilesConfig.self, forKey: .files) ?? d.files
        messagesKeyword = try c.decodeIfPresent(String.self, forKey: .messagesKeyword) ?? d.messagesKeyword
        messagesIncludeUnknownSenders = try c.decodeIfPresent(Bool.self, forKey: .messagesIncludeUnknownSenders) ?? d.messagesIncludeUnknownSenders
        messagesPinMinutes = try c.decodeIfPresent(Int.self, forKey: .messagesPinMinutes) ?? d.messagesPinMinutes
        shortcuts = try c.decodeIfPresent([String: String].self, forKey: .shortcuts) ?? d.shortcuts
        places = try c.decodeIfPresent([String].self, forKey: .places) ?? d.places
        extraAppDirs = try c.decodeIfPresent([String].self, forKey: .extraAppDirs) ?? d.extraAppDirs
        searches = try c.decodeIfPresent([SearchEngine].self, forKey: .searches) ?? d.searches
    }

    /// Called when loading renames a scope's code (the app moves pins along with it).
    static var onKeywordRename: ((String, String) -> Void)?

    static let dir = Paths.config
    static let file = dir.appendingPathComponent("config.json")
    static let pluginsDir = dir.appendingPathComponent("plugins")

    /// Older configs had long keywords ("mes", "clip") plus short codes pointing at them ("m", "v").
    /// Now each scope has just one code, so a code that only pointed at a keyword becomes that keyword.
    /// Returns the renames (old keyword → new), so pins can follow.
    @discardableResult
    mutating func migrateCodes() -> [String: String] {
        var renames: [String: String] = [:]
        // Only the two old long defaults; anything you chose yourself is left alone.
        func fold(_ keyword: inout String, legacy: String) {
            guard keyword == legacy else { return }
            let codes = shortcuts.filter { $0.value == legacy }.keys.sorted { $0.count < $1.count }
            guard let code = codes.first else { return }
            shortcuts[code] = nil
            renames[legacy] = code
            keyword = code
            // Any other extra codes for it now point at the new one.
            for other in codes.dropFirst() { shortcuts[other] = code }
        }
        fold(&messagesKeyword, legacy: "mes")
        fold(&clipboard.keyword, legacy: "clip")
        return renames
    }

    static let encoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return enc
    }()

    /// Writes the config (the Settings window saves through this).
    func save() {
        try? FileManager.default.createDirectory(at: Config.dir, withIntermediateDirectories: true)
        try? Config.encoder.encode(self).write(to: Config.file, options: .atomic)
    }

    /// Loads the config, writing the defaults on first run.
    static func load() -> Config {
        let fm = FileManager.default
        try? fm.createDirectory(at: pluginsDir, withIntermediateDirectories: true)
        let enc = Config.encoder
        if let data = try? Data(contentsOf: file) {
            do {
                var cfg = try JSONDecoder().decode(Config.self, from: data)
                for (old, new) in cfg.migrateCodes() {
                    Log.write("config: code “\(old)” is now “\(new)”")
                    Config.onKeywordRename?(old, new)
                }
                // Write back so settings added in newer versions show up in the file.
                if let out = try? enc.encode(cfg), out != data { try? out.write(to: file, options: .atomic) }
                return cfg
            } catch {
                FileHandle.standardError.write("blink: bad config.json (\(error.localizedDescription)); using defaults\n".data(using: .utf8)!)
                return Config()
            }
        }
        let cfg = Config()
        try? enc.encode(cfg).write(to: file)
        return cfg
    }
}

/// Remembers what you pick so frequent choices rank higher.
final class Usage {
    static let shared = Usage(url: Paths.data.appendingPathComponent("usage.json"))
    private struct Entry: Codable { var count: Int; var last: Double }
    private var entries: [String: Entry] = [:]
    private let url: URL
    private let io = DispatchQueue(label: "blink.usage")

    init(url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        self.url = url
        if let d = try? Data(contentsOf: url), let e = try? JSONDecoder().decode([String: Entry].self, from: d) { entries = e }
    }

    func bonus(_ id: String) -> Int {
        guard let e = entries[id] else { return 0 }
        let age = Date().timeIntervalSince1970 - e.last
        return min(e.count, 30) * 6 + (age < 86_400 ? 40 : age < 604_800 ? 20 : 0)
    }

    func record(_ id: String) {
        var e = entries[id] ?? Entry(count: 0, last: 0)
        e.count += 1
        e.last = Date().timeIntervalSince1970
        entries[id] = e
        let snapshot = entries, url = self.url
        io.async { try? JSONEncoder().encode(snapshot).write(to: url, options: .atomic) }
    }
}

/// Items you pinned: shown when Blink opens, and ranked first when they match what you type.
final class Pins {
    static let shared = Pins(url: Paths.data.appendingPathComponent("pins.json"))
    private(set) var ids: [String] = []
    private let url: URL

    init(url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        self.url = url
        if let d = try? Data(contentsOf: url), let list = try? JSONDecoder().decode([String].self, from: d) { ids = list }
    }

    /// The id a row is pinned under, or nil if that kind of row can't be pinned.
    static func key(for itemID: String) -> String? {
        if itemID.hasPrefix("mes.pin.") { return "mes." + itemID.dropFirst(8) }  // "Reply to …" is the same chat
        if itemID.hasPrefix("mes.new.") { return nil }
        for prefix in ["app.", "file.", "keyword.", "mes.", "clip."] where itemID.hasPrefix(prefix) { return itemID }
        return nil
    }

    func contains(_ key: String) -> Bool { ids.contains(key) }

    /// A scope's code changed ("mes" → "m"): keep its pin.
    func renameKeyword(_ old: String, to new: String) {
        guard let i = ids.firstIndex(of: "keyword." + old) else { return }
        ids[i] = "keyword." + new
        try? JSONEncoder().encode(ids).write(to: url, options: .atomic)
    }
    func index(_ key: String) -> Int? { ids.firstIndex(of: key) }

    func toggle(_ key: String) {
        if let i = ids.firstIndex(of: key) { ids.remove(at: i) } else { ids.append(key) }
        try? JSONEncoder().encode(ids).write(to: url, options: .atomic)
        Log.write("pins: \(ids.count) pinned")
    }
}
