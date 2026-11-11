import AppKit

// MARK: - Calculator

/// Small recursive-descent parser: + - * / % ^, brackets, a few functions and constants.
private struct Calc {
    private let s: [Character]
    private var i = 0
    private(set) var sawOperator = false

    init(_ text: String) { s = Array(text) }

    mutating func parse() -> Double? {
        guard let v = expr() else { return nil }
        skip()
        return i == s.count ? v : nil
    }

    private mutating func skip() { while i < s.count, s[i] == " " { i += 1 } }
    private mutating func eat(_ c: Character) -> Bool {
        skip()
        if i < s.count, s[i] == c { i += 1; return true }
        return false
    }

    private mutating func expr() -> Double? {
        guard var v = term() else { return nil }
        while true {
            if eat("+") { guard let r = term() else { return nil }; v += r; sawOperator = true }
            else if eat("-") { guard let r = term() else { return nil }; v -= r; sawOperator = true }
            else { return v }
        }
    }

    private mutating func term() -> Double? {
        guard var v = unary() else { return nil }
        while true {
            if eat("*") || eat("×") { guard let r = unary() else { return nil }; v *= r; sawOperator = true }
            else if eat("/") || eat("÷") { guard let r = unary() else { return nil }; v /= r; sawOperator = true }
            else if eat("%") { guard let r = unary() else { return nil }; v = v.truncatingRemainder(dividingBy: r); sawOperator = true }
            else { return v }
        }
    }

    private mutating func unary() -> Double? {
        if eat("-") { return unary().map { -$0 } }
        if eat("+") { return unary() }
        return power()
    }

    private mutating func power() -> Double? {
        guard let base = primary() else { return nil }
        if eat("^") { guard let e = unary() else { return nil }; sawOperator = true; return pow(base, e) }
        return base
    }

    private mutating func primary() -> Double? {
        skip()
        guard i < s.count else { return nil }
        if eat("(") {
            guard let v = expr(), eat(")") else { return nil }
            return v
        }
        if s[i].isNumber || s[i] == "." {
            let start = i
            while i < s.count, s[i].isASCII, s[i].isNumber || s[i] == "." { i += 1 }
            return Double(String(s[start..<i]))
        }
        if s[i].isLetter {
            let start = i
            while i < s.count, s[i].isLetter { i += 1 }
            let word = String(s[start..<i]).lowercased()
            if word == "pi" { return Double.pi }
            if word == "e" { return M_E }
            guard eat("("), let a = expr(), eat(")") else { return nil }
            sawOperator = true
            switch word {
            case "sqrt": return a.squareRoot()
            case "sin": return sin(a)
            case "cos": return cos(a)
            case "tan": return tan(a)
            case "ln": return log(a)
            case "log": return log10(a)
            case "abs": return abs(a)
            case "round": return a.rounded()
            case "floor": return a.rounded(.down)
            case "ceil": return a.rounded(.up)
            default: return nil
            }
        }
        return nil
    }
}

final class CalculatorProvider: Provider {
    let name = "Calculator"
    private let pretty: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 10
        return f
    }()
    private let plain: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.usesGroupingSeparator = false
        f.maximumFractionDigits = 10
        return f
    }()

    func search(_ query: String) -> [Item] {
        guard query.contains(where: { $0.isNumber }) else { return [] }
        var c = Calc(query)
        guard let v = c.parse(), c.sawOperator, v.isFinite else { return [] }
        let n = NSNumber(value: v)
        guard let shown = pretty.string(from: n), let copy = plain.string(from: n) else { return [] }
        return [Item(id: "calc", title: shown, subtitle: "Press ↩ to copy the result", icon: .symbol("equal.square.fill"),
                     score: 10_000, action: .copy(copy))]
    }
}

// MARK: - URLs

final class URLProvider: Provider {
    let name = "URL"

    static func url(from text: String) -> URL? {
        let q = text.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, !q.contains(" ") else { return nil }
        if q.contains("://") {
            guard let u = URL(string: q), u.scheme != nil else { return nil }
            return u
        }
        let lower = q.lowercased()
        if lower == "localhost" || lower.hasPrefix("localhost:") || lower.hasPrefix("localhost/") {
            return URL(string: "http://" + q)
        }
        var host = lower.prefix(while: { $0 != "/" && $0 != "?" })
        if let colon = host.lastIndex(of: ":") {
            guard host[host.index(after: colon)...].allSatisfy(\.isNumber) else { return nil }
            host = host[..<colon]
        }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, let tld = parts.last, tld.count >= 2, tld.allSatisfy({ $0.isLetter && $0.isASCII }) else { return nil }
        for p in parts {
            guard !p.isEmpty, p.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return nil }
        }
        return URL(string: "https://" + q)
    }

    func search(_ query: String) -> [Item] {
        guard let u = URLProvider.url(from: query) else { return [] }
        return [Item(id: "url", title: "Open " + u.absoluteString, subtitle: "Opens in your default browser",
                     icon: .symbol("globe"), score: 3000, action: .open(u))]
    }
}

// MARK: - Web searches

private let queryAllowed: CharacterSet = {
    var s = CharacterSet.urlQueryAllowed
    s.remove(charactersIn: "&+=?#/")
    return s
}()

private func searchURL(_ e: SearchEngine, _ text: String) -> URL? {
    guard let enc = text.addingPercentEncoding(withAllowedCharacters: queryAllowed) else { return nil }
    return URL(string: e.url.replacingOccurrences(of: "{query}", with: enc))
}

/// Finds an installed app by name, e.g. "Google Chrome".
func appPath(named name: String) -> String? {
    let fm = FileManager.default
    let dirs = ["/Applications", "/System/Applications", NSHomeDirectory() + "/Applications", "/System/Applications/Utilities"]
    return dirs.map { "\($0)/\(name).app" }.first { fm.fileExists(atPath: $0) }
}

/// One search engine: "g cats", or "g" then Tab.
final class SearchEngineProvider: Provider {
    let name: String
    let keyword: String?
    let icon: Icon
    private let engine: SearchEngine
    private let appURL: URL?

    init(engine: SearchEngine) {
        self.engine = engine
        name = engine.name
        keyword = engine.keyword.lowercased()
        let path = engine.app.flatMap(appPath(named:))
        appURL = path.map { URL(fileURLWithPath: $0) }
        icon = path.map { .file($0) } ?? .symbol("magnifyingglass")
    }

    func search(_ query: String) -> [Item] {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else {
            return [Item(id: "web.hint", title: "Search \(name)…", subtitle: "Type what to search for", icon: icon)]
        }
        guard let u = searchURL(engine, text) else { return [] }
        let open: Action
        if let appURL {
            open = .run { NSWorkspace.shared.open([u], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration()) }
        } else {
            open = .open(u)
        }
        return [Item(id: "web." + engine.keyword, title: "Search \(engine.name) for “\(text)”",
                     subtitle: engine.app.map { "Opens in \($0)" } ?? "", icon: icon, action: open,
                     actions: [ItemAction("Search", open), ItemAction("Copy Link", .copy(u.absoluteString))])]
    }
}

/// "Search Google for …" at the bottom of every query.
final class WebFallbackProvider: Provider {
    let name = "Web Search"
    private let engine: SearchEngine?

    init(engine: SearchEngine?) { self.engine = engine }

    func search(_ query: String) -> [Item] {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard let engine, !text.isEmpty, let u = searchURL(engine, text) else { return [] }
        return [Item(id: "web.fallback", title: "Search \(engine.name) for “\(text)”", icon: .symbol("magnifyingglass"),
                     score: -100, action: .open(u))]
    }
}

// MARK: - Places

/// Everyday folders (Downloads, Desktop, …), matched in every search.
final class PlacesProvider: Provider {
    let name = "Places"
    private struct Place { let path: String; let title: String; let key: Searchable }
    private let places: [Place]

    init(paths: [String]) {
        let fm = FileManager.default
        places = paths.compactMap { raw in
            let path = (raw as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }
            var title = fm.displayName(atPath: path)
            if path == NSHomeDirectory() { title = "Home (\(title))" }
            // "Home" and the folder's real name both match.
            return Place(path: path, title: title, key: Searchable(title + " " + (path as NSString).lastPathComponent))
        }
    }

    private func item(_ p: Place, _ score: Int) -> Item {
        let url = URL(fileURLWithPath: p.path)
        let home = NSHomeDirectory()
        let shown = p.path.hasPrefix(home) ? "~" + p.path.dropFirst(home.count) : p.path
        return Item(id: "file." + p.path, title: p.title, subtitle: shown, icon: .file(p.path), score: score,
                    action: .open(url), altAction: revealAction(p.path),
                    actions: [ItemAction("Open", .open(url)), ItemAction("Show in Finder", revealAction(p.path)),
                              ItemAction("Copy Path", .copy(p.path))])
    }

    func favorites(_ ids: [String]) -> [Item] {
        places.filter { ids.contains("file." + $0.path) }.map { item($0, 0) }
    }

    func search(_ query: String) -> [Item] {
        guard query.count >= 2 else { return [] }
        let q = fuzzyQuery(query)
        return places.compactMap { p in fuzzyScore(q, p.key).map { item(p, $0) } }
    }
}
