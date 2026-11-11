import XCTest
@testable import Blink

/// Ranking, scopes, pins and the one-draw-per-keystroke timing rules.
final class EngineTests: XCTestCase {
    var pins: Pins!

    override func setUp() {
        pins = tempPins()
    }

    func engine(_ providers: [Provider], aliases: [String: String] = [:]) -> Engine {
        Engine(providers: providers, aliases: aliases, usage: tempUsage(), pins: pins)
    }

    /// Runs `body`, then lets the main run loop turn for `seconds`, returning every draw the engine asked for.
    func draws(_ e: Engine, for seconds: TimeInterval, _ body: () -> Void) -> [(items: [Item], refinement: Bool)] {
        var out: [(items: [Item], refinement: Bool)] = []
        e.onUpdate = { out.append(($0, $1)) }
        body()
        let done = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { done.fulfill() }
        wait(for: [done], timeout: seconds + 5)
        return out
    }

    // MARK: Routing and ranking

    func testKeywordQueryOnlyAsksThatProvider() {
        let apps = FakeProvider(name: "Apps") { _ in [item("app.x", "Xcode")] }
        let google = FakeProvider(name: "Google", keyword: "g") { q in [item("web.g", "Search Google for \(q)")] }
        let results = engine([apps, google]).resultsSync("g cats")
        XCTAssertEqual(results.map(\.title), ["Search Google for cats"])
        XCTAssertTrue(apps.calls.isEmpty)
    }

    func testShortCodePutsItsScopeOnTop() {
        let apps = FakeProvider(name: "Apps") { _ in [item("app.mail", "Mail", score: 109)] }
        let messages = FakeProvider(name: "Messages", keyword: "mes", isAsync: true, expandsOnPrefix: true) { _ in [] }
        let e = engine([apps, messages], aliases: ["m": "mes"])
        let first = e.resultsSync("m").first
        XCTAssertEqual(first?.id, "keyword.mes")
        guard case .mode("mes")? = first?.action else { return XCTFail("short code row should enter the scope") }
        XCTAssertTrue(e.modeProvider(for: "m") === messages)
        XCTAssertTrue(e.modeProvider(for: "MES") === messages)
        XCTAssertNil(e.modeProvider(for: "x"))
    }

    func testTypingTheStartOfMessagesListsConversations() {
        let messages = FakeProvider(name: "Messages", keyword: "mes", isAsync: true, expandsOnPrefix: true) { _ in
            [item("mes.1", "Kate"), item("mes.2", "Sam")]
        }
        let titles = engine([messages]).resultsSync("me").map(\.title)
        XCTAssertEqual(titles, ["Messages", "Kate", "Sam"])
    }

    func testPinnedMatchesJumpAboveOthersAndGetAnUnpinAction() {
        let apps = FakeProvider(name: "Apps") { _ in [item("app.a", "Alpha", score: 150), item("app.b", "Beta", score: 100)] }
        pins.toggle("app.b")
        let results = engine([apps]).resultsSync("a")
        XCTAssertEqual(results.map(\.id), ["app.b", "app.a"])
        XCTAssertEqual(results[0].actions.last?.title, "Unpin")
        XCTAssertEqual(results[1].actions.last?.title, "Pin")
    }

    func testEmptyLauncherShowsPinsInOrderWithoutDuplicates() {
        let apps = FakeProvider(name: "Apps") { q in q.isEmpty ? [item("app.recent", "Recent", score: 0), item("app.z", "Zed", score: 0)] : [] }
        apps.favoritesResult = { ids in ids.map { item($0, $0) } }
        pins.toggle("app.z")
        pins.toggle("app.y")
        let ids = engine([apps]).resultsSync("").map(\.id)
        XCTAssertEqual(ids, ["app.z", "app.y", "app.recent"], "pins first, in pin order; Zed only once")
    }

    // MARK: Timing (flicker)

    func testQuickBackgroundResultsArriveInASingleDraw() {
        let messages = FakeProvider(name: "Messages", keyword: "mes", isAsync: true, expandsOnPrefix: true, delay: 0.005) { _ in
            [item("mes.1", "Kate")]
        }
        let e = engine([messages])
        e.firstDrawWait = 0.25
        let got = draws(e, for: 0.5) { e.query("me") }
        XCTAssertEqual(got.count, 1, "one draw, not fast results then slow ones")
        XCTAssertEqual(got.first?.items.map(\.title), ["Messages", "Kate"])
    }

    func testSlowResultsShowLastResultsWhileTheNewOnesLoad() {
        let messages = FakeProvider(name: "Messages", keyword: "mes", isAsync: true, expandsOnPrefix: true, delay: 0.25) { _ in
            [item("mes.1", "Kate"), item("mes.2", "Sam")]
        }
        let e = engine([messages])
        e.firstDrawWait = 0.02
        _ = draws(e, for: 0.5) { e.query("me") }  // warm up
        let got = draws(e, for: 0.6) { e.query("mes") }
        XCTAssertEqual(got.first?.items.count, 3, "the list keeps its rows instead of collapsing to just the Messages row")
        XCTAssertEqual(got.last?.items.map(\.title), ["Messages", "Kate", "Sam"])
    }

    func testNoEmptyFlashWhileAScopedSearchRuns() {
        let files = FakeProvider(name: "Files", keyword: "f", isAsync: true, delay: 0.2) { _ in [item("file.a", "a.pdf")] }
        let e = engine([files])
        e.firstDrawWait = 0.02
        let got = draws(e, for: 0.5) { e.query("f inv") }
        XCTAssertFalse(got.contains { $0.items.isEmpty }, "never draw an empty list while results are on the way")
        XCTAssertEqual(got.last?.items.map(\.title), ["a.pdf"])
    }

    func testResultsForAnOlderKeystrokeAreIgnored() {
        let files = FakeProvider(name: "Files", keyword: "f", isAsync: true) { q in [item("file.\(q)", q)] }
        files.delay = 0
        let slow = FakeProvider(name: "Slow", keyword: "s", isAsync: true, delay: 0.3) { q in [item("old.\(q)", "old \(q)")] }
        let e = engine([files, slow])
        e.firstDrawWait = 0.02
        let got = draws(e, for: 0.6) {
            e.query("s inv")   // slow, superseded
            e.query("f invo")  // fast, current
        }
        XCTAssertEqual(got.last?.items.map(\.title), ["invo"])
        XCTAssertFalse(got.contains { $0.items.contains { $0.title.hasPrefix("old") } })
    }
}
