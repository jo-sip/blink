import AppKit

/// File and folder search by name, backed by the Spotlight index (mdfind).
final class FilesProvider: Provider {
    let name = "Files"
    let keyword: String?
    let isAsync = true
    let icon: Icon = .symbol("doc.text.magnifyingglass")
    let includeInGlobal: Bool
    private let config: FilesConfig
    private let lock = NSLock()
    private var running: Process?
    private let home = NSHomeDirectory()

    init(config: FilesConfig) {
        self.config = config
        keyword = config.keyword.lowercased()
        includeInGlobal = config.includeInDefaultResults
    }

    private func item(_ path: String) -> Item {
        let url = URL(fileURLWithPath: path)
        let shown = path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
        return Item(id: "file." + path, title: url.lastPathComponent, subtitle: shown, icon: .file(path),
                    action: .open(url), altAction: revealAction(path),
                    actions: [ItemAction("Open", .open(url)), ItemAction("Show in Finder", revealAction(path)),
                              ItemAction("Copy Path", .copy(path))])
    }

    func favorites(_ ids: [String]) -> [Item] {
        ids.filter { $0.hasPrefix("file.") }.map { String($0.dropFirst(5)) }
            .filter { FileManager.default.fileExists(atPath: $0) }.map(item)
    }

    func search(_ query: String) -> [Item] {
        let words = query.split(separator: " ").map(String.init)
        guard query.trimmingCharacters(in: .whitespaces).count >= 2 else { return [] }

        // Every word must appear in the file name, case- and accent-insensitively.
        let clauses = words.map { w -> String in
            let esc = w.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "*", with: "\\*")
            return "kMDItemFSName == \"*\(esc)*\"cd"
        }
        var args: [String] = []
        for scope in config.scopes {
            args += ["-onlyin", (scope as NSString).expandingTildeInPath]
        }
        args.append(clauses.joined(separator: " && "))

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        // A newer keystroke supersedes the old search. Only ever signal a process that has launched.
        lock.lock()
        if let old = running, old.isRunning { old.terminate() }
        let started = (try? proc.run()) != nil
        running = started ? proc : nil
        lock.unlock()
        guard started else { return [] }

        // Stream hits, dropping excluded folders as they arrive, and stop Spotlight once there are
        // enough real candidates. Excluded folders (node_modules etc.) can be most of the raw output.
        let excludes = config.excludes.map { "/" + $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" }
        let want = max(config.maxResults, 1) * 5
        let q = fuzzyQuery(words.joined())
        var scored: [(path: String, score: Int)] = []
        var pending = Data()
        var seen = 0
        let handle = pipe.fileHandleForReading
        reading: while scored.count < want, seen < 50_000 {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            pending.append(chunk)
            while let nl = pending.firstIndex(of: 10) {
                let path = String(decoding: pending[pending.startIndex..<nl], as: UTF8.self)
                pending.removeSubrange(pending.startIndex...nl)
                seen += 1
                guard path.hasPrefix("/"), !excludes.contains(where: { (path + "/").contains($0) }) else { continue }
                let file = (path as NSString).lastPathComponent
                // Shallower paths win ties: they are usually the ones you mean.
                let depth = path.reduce(0) { $0 + ($1 == "/" ? 1 : 0) }
                scored.append((path, (fuzzyScore(q, Searchable(file)) ?? 0) - depth * 2))
                if scored.count >= want { break reading }
            }
        }
        if proc.isRunning { proc.terminate() }
        scored.sort { $0.score > $1.score }

        return scored.prefix(config.maxResults).map { item($0.path) }
    }
}
