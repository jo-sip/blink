import AppKit

/// A plugin is a script whose JSON output becomes rows. Two kinds:
/// - Blink plugins: any executable in ~/.config/blink/plugins. The filename is the keyword; the query is $1.
/// - Alfred workflows: Script Filters from imported `.alfredworkflow` files (see `AlfredWorkflows`).
/// Both may print Blink's format or Alfred's Script Filter format:
///   {"items":[{"title":..,"subtitle":..,"icon":..,"open"|"copy"|"run":..,"actions":[..]}]}
///   {"items":[{"uid":..,"title":..,"subtitle":..,"arg":..,"icon":{"path":..,"type":"fileicon"},
///              "valid":..,"autocomplete":..,"mods":{"cmd":{"arg":..}},"text":{"copy":..}}]}
final class ScriptProvider: Provider {
    /// What ↩ does with an Alfred item's `arg`.
    enum ArgAction {
        case auto                                   // open it if it's a URL or path, otherwise copy it
        case openURL(String)                        // URL template with {query}
        case copy(String)                           // text template with {query}
        case script(launch: [String], body: String, argv: Bool, dir: URL, env: [String: String])
    }

    let name: String
    let keyword: String?
    let isAsync = true
    let icon: Icon
    let source: String  // where it came from, for Settings
    private let launch: [String]           // executable + fixed arguments
    private let passQuery: (String) -> [String]
    private let workingDir: URL
    private let env: [String: String]
    private let argAction: ArgAction
    private let lock = NSLock()
    private var running: Process?

    init(name: String, keyword: String, launch: [String], passQuery: @escaping (String) -> [String], workingDir: URL,
         env: [String: String] = [:], icon: Icon = .symbol("terminal"), argAction: ArgAction = .auto, source: String) {
        self.name = name
        self.keyword = keyword.lowercased()
        self.launch = launch
        self.passQuery = passQuery
        self.workingDir = workingDir
        self.env = env
        self.icon = icon
        self.argAction = argAction
        self.source = source
    }

    /// A Blink plugin file.
    convenience init(path: String) {
        let kw = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent.lowercased()
        self.init(name: kw.prefix(1).uppercased() + kw.dropFirst(), keyword: kw, launch: [path], passQuery: { [$0] },
                  workingDir: URL(fileURLWithPath: path).deletingLastPathComponent(), source: path)
    }

    static func discover() -> [ScriptProvider] {
        let fm = FileManager.default
        let dir = Config.pluginsDir.path
        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        return entries.sorted().compactMap { e in
            let p = dir + "/" + e
            var isDir: ObjCBool = false
            guard !e.hasPrefix("."), fm.fileExists(atPath: p, isDirectory: &isDir), !isDir.boolValue,
                  fm.isExecutableFile(atPath: p) else { return nil }
            return ScriptProvider(path: p)
        }
    }

    // MARK: Running

    private func message(_ title: String, _ subtitle: String) -> [Item] {
        [Item(id: "plugin.msg", title: title, subtitle: subtitle, icon: .symbol("exclamationmark.triangle"))]
    }

    static func run(_ launch: [String], args: [String], dir: URL, env: [String: String], stdin: String? = nil,
                    timeout: TimeInterval = 5, track: ((Process) -> Bool)? = nil) -> (Data, Bool)? {
        guard let exe = launch.first else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.arguments = Array(launch.dropFirst()) + args
        proc.currentDirectoryURL = dir
        proc.environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new }
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        if let track { guard track(proc) else { return nil } } else { guard (try? proc.run()) != nil else { return nil } }
        let killer = DispatchWorkItem { if proc.isRunning { proc.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        killer.cancel()
        return (data, proc.terminationReason == .uncaughtSignal)
    }

    func search(_ query: String) -> [Item] {
        var failure: String?
        let result = ScriptProvider.run(launch, args: passQuery(query), dir: workingDir, env: env) { [self] proc in
            // A newer keystroke supersedes the old run. Only ever signal a process that has launched.
            lock.lock()
            defer { lock.unlock() }
            if let old = running, old.isRunning { old.terminate() }
            do { try proc.run() } catch { failure = error.localizedDescription; running = nil; return false }
            running = proc
            return true
        }
        if let failure { return message("Plugin failed to start", failure) }
        guard let (data, killed) = result, !killed else { return [] }
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            return data.isEmpty ? [] : message("Plugin output is not valid JSON", source)
        }
        let raw = (json as? [String: Any])?["items"] as? [[String: Any]] ?? json as? [[String: Any]] ?? []
        return raw.enumerated().compactMap { i, d in parse(d, index: i) }
    }

    // MARK: Parsing (Blink and Alfred formats)

    func parse(_ d: [String: Any], index: Int) -> Item? {
        guard let title = d["title"] as? String else { return nil }
        let kw = keyword ?? ""
        let uid = d["uid"] as? String ?? d["id"] as? String ?? String(index)
        var item = Item(id: "plugin.\(kw).\(uid)", title: title, subtitle: d["subtitle"] as? String ?? "", icon: icon)
        if let b = d["badge"] as? String { item.badge = b }
        item.icon = parseIcon(d["icon"]) ?? icon

        if let a = ScriptProvider.blinkAction(d) {
            item.action = a
        } else if (d["valid"] as? Bool) == false {
            // Alfred: not actionable; ↩ fills in the autocomplete text instead.
            if let ac = d["autocomplete"] as? String { item.action = .complete(kw + " " + ac) }
        } else if let arg = ScriptProvider.argString(d["arg"]) {
            item.action = action(for: arg)
        } else if let ac = d["autocomplete"] as? String {
            item.action = .complete(kw + " " + ac)
        }

        if let mods = d["mods"] as? [String: Any], let cmd = mods["cmd"] as? [String: Any],
           (cmd["valid"] as? Bool) != false, let arg = ScriptProvider.argString(cmd["arg"]) {
            item.altAction = action(for: arg)
        }
        for extra in d["actions"] as? [[String: Any]] ?? [] {
            if let t = extra["title"] as? String, let a = ScriptProvider.blinkAction(extra) { item.actions.append(ItemAction(t, a)) }
        }
        if item.actions.isEmpty, let copy = (d["text"] as? [String: Any])?["copy"] as? String {
            item.actions = [ItemAction("Open", item.action), ItemAction("Copy", .copy(copy))]
        }
        return item
    }

    private func parseIcon(_ value: Any?) -> Icon? {
        if let s = value as? String { return s.hasPrefix("/") ? .file(s) : .symbol(s) }
        guard let d = value as? [String: Any], let path = d["path"] as? String else { return nil }
        let full = path.hasPrefix("/") ? path : workingDir.appendingPathComponent(path).path
        switch d["type"] as? String {
        case "fileicon": return .file(full)
        case "filetype": return .symbol("doc")
        default: return FileManager.default.fileExists(atPath: full) ? .thumbnail(full) : nil
        }
    }

    static func argString(_ value: Any?) -> String? {
        if let s = value as? String { return s }
        if let list = value as? [String] { return list.joined(separator: "\t") }
        return nil
    }

    private static func blinkAction(_ d: [String: Any]) -> Action? {
        if let o = d["open"] as? String {
            let expanded = (o as NSString).expandingTildeInPath
            if expanded.hasPrefix("/") { return .open(URL(fileURLWithPath: expanded)) }
            return URL(string: o).map { .open($0) }
        }
        if let c = d["copy"] as? String { return .copy(c) }
        if let r = d["run"] as? String {
            return .run {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/sh")
                p.arguments = ["-c", r]
                try? p.run()
            }
        }
        return nil
    }

    func action(for arg: String) -> Action {
        switch argAction {
        case .auto:
            let expanded = (arg as NSString).expandingTildeInPath
            if expanded.hasPrefix("/"), FileManager.default.fileExists(atPath: expanded) { return .open(URL(fileURLWithPath: expanded)) }
            if let u = URL(string: arg), let scheme = u.scheme, !scheme.isEmpty, arg.contains(":") { return .open(u) }
            return .copy(arg)
        case .openURL(let template):
            let enc = arg.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? arg
            let filled = template.isEmpty ? arg : template.replacingOccurrences(of: "{query}", with: enc)
            return URL(string: filled).map { .open($0) } ?? .copy(arg)
        case .copy(let template):
            return .copy(template.isEmpty ? arg : template.replacingOccurrences(of: "{query}", with: arg))
        case .script(let launch, let body, let argv, let dir, let env):
            return .run {
                let script = argv ? body : body.replacingOccurrences(of: "{query}", with: arg)
                DispatchQueue.global().async {
                    _ = ScriptProvider.run(launch + ["-c", script] + (argv ? ["blink", arg] : []), args: [], dir: dir, env: env, timeout: 60)
                }
            }
        }
    }
}

/// Imports Alfred workflows: each Script Filter becomes a Blink keyword, and ↩ follows the workflow's
/// next step when it's one Blink understands (open URL, copy to clipboard, run script).
enum AlfredWorkflows {
    static let dir = Config.dir.appendingPathComponent("workflows")

    /// Alfred's script languages → how to launch them with an inline script.
    static func interpreter(_ type: Int) -> [String]? {
        switch type {
        case 0: return ["/bin/bash"]
        case 1: return ["/usr/bin/php"]
        case 2: return ["/usr/bin/ruby"]
        case 3, 9: return ["/usr/bin/python3"]
        case 4: return ["/usr/bin/perl"]
        case 5: return ["/bin/zsh"]
        case 6: return ["/usr/bin/osascript", "-l", "JavaScript"]
        case 7: return ["/usr/bin/osascript"]
        default: return nil
        }
    }

    /// Unzips a downloaded .alfredworkflow into ~/.config/blink/workflows.
    static func importFile(_ file: URL) -> Bool {
        let target = dir.appendingPathComponent(file.deletingPathExtension().lastPathComponent)
        try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", file.path, target.path]
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        let ok = p.terminationStatus == 0 && FileManager.default.fileExists(atPath: target.appendingPathComponent("info.plist").path)
        Log.write("alfred workflow import \(ok ? "ok" : "failed"): \(file.lastPathComponent)")
        return ok
    }

    /// Workflows imported into Blink, plus Alfred's own if Alfred is set up with workflows.
    static func discover() -> [ScriptProvider] {
        let alfred = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Alfred/Alfred.alfredpreferences/workflows")
        return [dir, alfred].flatMap { root -> [ScriptProvider] in
            let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            return folders.sorted { $0.path < $1.path }.flatMap(load)
        }
    }

    static func load(_ folder: URL) -> [ScriptProvider] {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("info.plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              (plist["disabled"] as? Bool) != true else { return [] }
        let objects = plist["objects"] as? [[String: Any]] ?? []
        let connections = plist["connections"] as? [String: [[String: Any]]] ?? [:]
        let bundle = plist["bundleid"] as? String ?? folder.lastPathComponent
        let workflowName = plist["name"] as? String ?? folder.lastPathComponent
        let support = Paths.data.appendingPathComponent("workflows")
        var env = (plist["variables"] as? [String: String]) ?? [:]
        env["alfred_workflow_bundleid"] = bundle
        env["alfred_workflow_name"] = workflowName
        env["alfred_workflow_uid"] = folder.lastPathComponent
        env["alfred_workflow_data"] = support.appendingPathComponent(bundle + "/data").path
        env["alfred_workflow_cache"] = support.appendingPathComponent(bundle + "/cache").path
        env["alfred_version"] = "5.5"
        env["alfred_version_build"] = "2257"
        for key in ["alfred_workflow_data", "alfred_workflow_cache"] {
            try? FileManager.default.createDirectory(atPath: env[key]!, withIntermediateDirectories: true)
        }
        let iconPath = folder.appendingPathComponent("icon.png").path
        let icon: Icon = FileManager.default.fileExists(atPath: iconPath) ? .thumbnail(iconPath) : .symbol("puzzlepiece.extension")
        let byUID = Dictionary(objects.compactMap { o in (o["uid"] as? String).map { ($0, o) } }, uniquingKeysWith: { a, _ in a })

        return objects.compactMap { o -> ScriptProvider? in
            guard o["type"] as? String == "alfred.workflow.input.scriptfilter",
                  let config = o["config"] as? [String: Any],
                  let keyword = (config["keyword"] as? String)?.trimmingCharacters(in: .whitespaces), !keyword.isEmpty,
                  let uid = o["uid"] as? String else { return nil }
            let argv = (config["argumenttype"] as? Int ?? 0) != 2 && (config["scriptargtype"] as? Int ?? 0) == 1
            let type = config["type"] as? Int ?? 0
            let launch: [String]
            let passQuery: (String) -> [String]
            if type == 8, let file = config["scriptfile"] as? String {
                launch = [folder.appendingPathComponent(file).path]
                passQuery = { [$0] }
            } else if let interp = interpreter(type), let script = config["script"] as? String {
                let escape = config["escaping"] as? Int ?? 0
                launch = interp
                let isAppleScript = interp.first == "/usr/bin/osascript"
                passQuery = { q in
                    if argv { return isAppleScript ? ["-e", script, q] : ["-c", script, "blink", q] }
                    // "with input as {query}": Alfred pastes the query into the script, escaped for the language.
                    let quoted = escape == 0 ? q : q.replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "$", with: "\\$")
                    let filled = script.replacingOccurrences(of: "{query}", with: quoted)
                    return isAppleScript ? ["-e", filled] : ["-c", filled]
                }
            } else {
                return nil
            }
            // What the next step in the workflow does with the chosen item's arg.
            var argAction = ScriptProvider.ArgAction.auto
            if let next = connections[uid]?.first?["destinationuid"] as? String, let dest = byUID[next],
               let destConfig = dest["config"] as? [String: Any] {
                switch dest["type"] as? String {
                case "alfred.workflow.action.openurl":
                    argAction = .openURL(destConfig["url"] as? String ?? "")
                case "alfred.workflow.output.clipboard":
                    argAction = .copy(destConfig["clipboardtext"] as? String ?? "{query}")
                case "alfred.workflow.action.script":
                    if let body = destConfig["script"] as? String, let interp = interpreter(destConfig["type"] as? Int ?? 0) {
                        argAction = .script(launch: interp, body: body, argv: (destConfig["scriptargtype"] as? Int ?? 0) == 1,
                                            dir: folder, env: env)
                    }
                default: break
                }
            }
            let title = (config["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? workflowName
            return ScriptProvider(name: title, keyword: keyword, launch: launch, passQuery: passQuery, workingDir: folder,
                                  env: env, icon: icon, argAction: argAction, source: "Alfred: \(workflowName)")
        }
    }
}
