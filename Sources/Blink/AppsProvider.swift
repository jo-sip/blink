import AppKit

final class AppsProvider: Provider {
    let name = "Applications"
    private struct App { let name: String; let path: String; let key: Searchable }
    private var apps: [App] = []
    private var lastScan = Date.distantPast
    private var scanning = false
    private let extraDirs: [String]
    /// Called on the main thread when a background scan changes the app list.
    var onReindex: (() -> Void)?

    init(extraDirs: [String]) { self.extraDirs = extraDirs }

    private static func scan(_ extra: [String]) -> [App] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let dirs = ["/Applications", "/System/Applications", home + "/Applications",
                    "/System/Library/CoreServices/Applications"] + extra.map { ($0 as NSString).expandingTildeInPath }
        var seen = Set<String>()
        var out: [App] = []
        func add(_ path: String) {
            guard !path.hasSuffix("/Blink.app"), seen.insert(path).inserted else { return }
            var n = fm.displayName(atPath: path)
            if n.hasSuffix(".app") { n.removeLast(4) }
            out.append(App(name: n, path: path, key: Searchable(n)))
        }
        func walk(_ dir: String, depth: Int) {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return }
            for e in entries where !e.hasPrefix(".") {
                let p = dir + "/" + e
                if e.hasSuffix(".app") { add(p) } else if depth > 0 {
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue { walk(p, depth: depth - 1) }
                }
            }
        }
        dirs.forEach { walk($0, depth: 1) }
        add("/System/Library/CoreServices/Finder.app")
        return out
    }

    func scanNow() {
        apps = AppsProvider.scan(extraDirs)
        lastScan = Date()
    }

    /// Re-scan in the background at most once a minute.
    func refresh() {
        guard !scanning, Date().timeIntervalSince(lastScan) > 60 else { return }
        scanning = true
        let extra = extraDirs
        DispatchQueue.global(qos: .userInitiated).async {
            let found = AppsProvider.scan(extra)
            DispatchQueue.main.async {
                self.apps = found
                self.lastScan = Date()
                self.scanning = false
                self.onReindex?()
            }
        }
    }

    private func item(_ a: App, _ score: Int) -> Item {
        let open = Action.open(URL(fileURLWithPath: a.path))
        return Item(id: "app." + a.path, title: a.name, subtitle: a.path, icon: .file(a.path), score: score,
                    action: open, altAction: revealAction(a.path),
                    actions: [ItemAction("Open", open), ItemAction("Show in Finder", revealAction(a.path)),
                              ItemAction("Copy Path", .copy(a.path))])
    }

    func favorites(_ ids: [String]) -> [Item] {
        let wanted = Set(ids.filter { $0.hasPrefix("app.") }.map { String($0.dropFirst(4)) })
        return apps.filter { wanted.contains($0.path) }.map { item($0, 0) }
    }

    func search(_ query: String) -> [Item] {
        if query.isEmpty {
            // Nothing typed yet: show what you launch most.
            return apps.compactMap { a -> Item? in
                let b = Usage.shared.bonus("app." + a.path)
                return b > 0 ? item(a, b) : nil
            }.sorted { $0.score > $1.score }.prefix(7).map { var i = $0; i.score = 0; return i }
        }
        let q = fuzzyQuery(query)
        var out: [Item] = []
        for a in apps {
            if let s = fuzzyScore(q, a.key) { out.append(item(a, s)) }
        }
        return out
    }
}
