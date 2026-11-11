import Foundation

final class Engine {
    let providers: [Provider]
    /// (results, isRefinement). A refinement is slower results arriving for the same query.
    var onUpdate: (([Item], Bool) -> Void)?
    private let queue = DispatchQueue(label: "blink.async", attributes: .concurrent)
    private let maxResults: Int
    private let globalLimit: Int

    private var generation = 0
    private var lastQuery = ""
    private var ordered = false
    private var syncItems: [Item] = []
    private var sourceOrder: [String] = []
    private var sourceItems: [String: [Item]] = [:]

    /// The latest raw results of each slow source. While a new search for that source runs, these stand in
    /// for it, so the list doesn't collapse to the fast results and regrow on every keystroke.
    private var lastRaw: [String: (items: [Item], gen: Int, at: Date)] = [:]
    private let placeholderTTL: TimeInterval = 30
    private var pendingJobs = 0
    private var firstDraw: DispatchWorkItem?

    private struct Job {
        let source: String
        let base: Int?  // nil: keep provider order; otherwise score = base - index
        var limit: Int? = nil
        let run: () -> [Item]
    }

    /// Extra code → a scope's own code, e.g. "msg" → "m".
    let aliases: [String: String]

    private let usage: Usage
    private let pins: Pins
    /// How long to hold the first draw for slow sources (tests shorten or lengthen it).
    var firstDrawWait: TimeInterval = 0.06

    init(providers: [Provider], maxResults: Int = 40, globalLimit: Int = 5, aliases: [String: String] = [:],
         usage: Usage = .shared, pins: Pins = .shared) {
        self.providers = providers
        self.usage = usage
        self.pins = pins
        self.aliases = Dictionary(aliases.map { ($0.key.lowercased(), $0.value.lowercased()) }, uniquingKeysWith: { a, _ in a })
        self.maxResults = max(maxResults, 1)
        self.globalLimit = max(globalLimit, 1)
    }

    /// The provider a typed short code or exact keyword stands for ("m" → Messages).
    func modeProvider(for text: String) -> Provider? {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !t.isEmpty else { return nil }
        let kw = aliases[t] ?? t
        return providers.first { $0.keyword == kw }
    }

    func provider(keyword: String) -> Provider? { providers.first { $0.keyword == keyword } }

    func refresh() {
        providers.forEach { $0.refresh() }
        // Prefetch the list a provider shows when you type the start of its keyword, so "me" draws in one go.
        for p in providers where p.isAsync && p.expandsOnPrefix {
            let job = Engine.searchJob(p, "", base: nil)
            let gen = generation
            queue.async {
                let raw = job.run()
                DispatchQueue.main.async {
                    if (self.lastRaw[job.source]?.gen ?? -1) <= gen { self.lastRaw[job.source] = (raw, gen, Date()) }
                }
            }
        }
    }

    /// Drops stand-in results, e.g. after sending a reply that un-pins a conversation.
    func invalidate() { lastRaw.removeAll() }

    private static func source(_ p: Provider, _ kind: String) -> String {
        "\(ObjectIdentifier(p).hashValue):\(kind)"
    }

    private static func searchJob(_ p: Provider, _ q: String, base: Int?, limit: Int? = nil) -> Job {
        Job(source: source(p, "search"), base: base, limit: limit, run: { p.search(q) })
    }

    private func plan(_ raw: String) -> (items: [Item], jobs: [Job], ordered: Bool) {
        let q = String(raw.drop(while: { $0 == " " }))
        let lower = q.lowercased()

        // "<keyword> <query>": that provider only, in its own order.
        for p in providers {
            guard let kw = p.keyword, lower.hasPrefix(kw + " ") else { continue }
            let rest = String(q.dropFirst(kw.count + 1))
            if p.isAsync { return ([], [Engine.searchJob(p, rest, base: nil)], true) }
            return (p.search(rest), [], true)
        }

        var items: [Item] = []
        var jobs: [Job] = []
        for p in providers where p.keyword == nil { items += p.search(q) }

        if q.trimmingCharacters(in: .whitespaces).isEmpty {
            for p in providers where p.providesPinned {
                jobs.append(Job(source: Engine.source(p, "pinned"), base: 20_000, run: { p.pinned() }))
            }
            // Your pins, in the order you pinned them.
            let ids = pins.ids
            let pins = self.pins
            if !ids.isEmpty {
                for p in providers {
                    if p.isAsync {
                        jobs.append(Job(source: Engine.source(p, "favorites"), base: nil, run: { Engine.favoriteScores(p.favorites(ids), pins) }))
                    } else {
                        items += Engine.favoriteScores(p.favorites(ids), pins)
                    }
                }
                for id in ids where id.hasPrefix("keyword.") {
                    if let p = provider(keyword: String(id.dropFirst(8))), let kw = p.keyword {
                        items += Engine.favoriteScores([Item(id: id, title: p.name, subtitle: "Search \(p.name)", icon: p.icon, action: .mode(kw))], pins)
                    }
                }
            }
        }
        if lower.count >= 3 {
            // Slow sources that opted in to ordinary queries rank below real app matches.
            for p in providers where p.keyword != nil && p.includeInGlobal {
                jobs.append(Engine.searchJob(p, q, base: 60, limit: p.globalLimit ?? globalLimit))
            }
        }
        // Keyword rows. An exact short code or keyword goes on top; ↩ or Tab scopes the launcher to it.
        let exact = modeProvider(for: lower)
        for p in providers {
            guard let kw = p.keyword else { continue }
            let isExact = exact === p
            let isPrefix = lower.count >= 2 && (kw.hasPrefix(lower) || p.name.lowercased().hasPrefix(lower))
            guard isExact || isPrefix else { continue }
            let expands = p.expandsOnPrefix && isPrefix
            let code = aliases.first { $0.value == kw }?.key
            let hint = code.map { "“\($0)” or “\(kw)”" } ?? "“\(kw)”"
            items.append(Item(
                id: "keyword." + kw, title: p.name, subtitle: "Tab or ↩ to search · shortcut \(hint)",
                icon: p.icon, score: expands ? 5000 : isExact ? 4500 : 40, action: .mode(kw)))
            if expands {
                do {
                    if p.isAsync { jobs.append(Engine.searchJob(p, "", base: 4000)) } else {
                        items += Engine.rebase(p.search(""), 4000)
                    }
                }
            }
        }
        return (items, jobs, false)
    }

    private static func rebase(_ items: [Item], _ base: Int?) -> [Item] {
        guard let base else { return items }
        return items.enumerated().map { i, item in
            var it = item
            it.score = base - i
            return it
        }
    }

    /// Pinned items sit just under unread replies, in pin order.
    private static func favoriteScores(_ items: [Item], _ pins: Pins) -> [Item] {
        items.map { item in
            var it = item
            it.score = 15_000 - (Pins.key(for: item.id).flatMap(pins.index) ?? 0)
            return it
        }
    }

    /// Adds a Pin/Unpin action to every row that can be pinned.
    private func withPinAction(_ item: Item) -> Item {
        guard let key = Pins.key(for: item.id) else { return item }
        var it = item
        if it.actions.isEmpty {
            let label: String
            switch it.action {
            case .mode: label = "Search"
            case .prompt: label = "Reply"
            default: label = "Open"
            }
            it.actions = [ItemAction(label, it.action)]
        }
        it.actions.append(ItemAction(pins.contains(key) ? "Unpin" : "Pin", .togglePin(key)))
        return it
    }

    private static func shape(_ raw: [Item], _ job: Job) -> [Item] {
        rebase(Array(raw.prefix(job.limit ?? Int.max)), job.base)
    }

    private func rank(_ items: [Item], ordered: Bool) -> [Item] {
        if ordered { return Array(items.prefix(maxResults)).map(withPinAction) }
        let scored = items.enumerated().map { i, item -> (i: Int, item: Item, s: Int) in
            var bonus = 0
            if item.score >= 0 && item.score < 4000 {
                bonus = usage.bonus(item.id)
                // A pinned item that matches what you typed goes above other matches.
                if let key = Pins.key(for: item.id), pins.contains(key) { bonus += 300 }
            }
            return (i, item, item.score + bonus)
        }
        // The same thing can arrive twice (a pinned app that is also a recent one): keep the higher.
        var seen = Set<String>()
        var out: [Item] = []
        for entry in scored.sorted(by: { $0.s != $1.s ? $0.s > $1.s : $0.i < $1.i }) {
            guard seen.insert(Pins.key(for: entry.item.id) ?? entry.item.id).inserted else { continue }
            out.append(withPinAction(entry.item))
            if out.count == maxResults { break }
        }
        return out
    }

    private func publish(refinement: Bool) {
        let all = syncItems + sourceOrder.flatMap { sourceItems[$0] ?? [] }
        onUpdate?(rank(all, ordered: ordered), refinement)
    }

    /// Main thread. Publishes fast results immediately, slow ones as they arrive.
    func query(_ raw: String) {
        lastQuery = raw
        generation += 1
        let gen = generation
        let p = plan(raw)
        syncItems = p.items
        ordered = p.ordered
        sourceOrder = p.jobs.map(\.source)
        sourceItems = [:]
        firstDraw?.cancel()
        firstDraw = nil
        pendingJobs = p.jobs.count
        guard !p.jobs.isEmpty else {
            publish(refinement: false)
            return
        }

        // Stand-ins from the last run of each slow source, used only if it isn't back in time.
        let now = Date()
        var standIns: [String: [Item]] = [:]
        for job in p.jobs {
            if let prev = lastRaw[job.source], now.timeIntervalSince(prev.at) < placeholderTTL {
                standIns[job.source] = Engine.shape(prev.items, job)
            }
        }
        let draw = DispatchWorkItem { [weak self] in
            guard let self, gen == self.generation else { return }
            self.firstDraw = nil
            for (source, items) in standIns where self.sourceItems[source] == nil { self.sourceItems[source] = items }
            // Nothing to show yet but results are coming: keep the previous list up rather than flash empty.
            if self.syncItems.isEmpty, self.sourceItems.values.allSatisfy(\.isEmpty) { return }
            self.publish(refinement: false)
        }
        firstDraw = draw
        DispatchQueue.main.asyncAfter(deadline: .now() + firstDrawWait, execute: draw)

        for job in p.jobs {
            queue.async {
                let raw = job.run()
                DispatchQueue.main.async {
                    if (self.lastRaw[job.source]?.gen ?? -1) <= gen { self.lastRaw[job.source] = (raw, gen, Date()) }
                    guard gen == self.generation else { return }
                    self.sourceItems[job.source] = Engine.shape(raw, job)
                    self.pendingJobs -= 1
                    if let first = self.firstDraw {
                        // Still inside the wait: draw once everything is in.
                        guard self.pendingJobs == 0 else { return }
                        first.cancel()
                        self.firstDraw = nil
                        self.publish(refinement: false)
                    } else {
                        // A refinement after a skipped first draw is really the first draw of this query.
                        self.publish(refinement: true)
                    }
                }
            }
        }
    }

    /// Re-runs the last query after a provider's data changed.
    func requery() { query(lastQuery) }

    /// Blocking variant for the command-line mode.
    func resultsSync(_ raw: String) -> [Item] {
        let p = plan(raw)
        var items = p.items
        for job in p.jobs { items += Engine.shape(job.run(), job) }
        return rank(items, ordered: p.ordered)
    }
}
