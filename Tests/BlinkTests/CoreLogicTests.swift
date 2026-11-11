import XCTest
@testable import Blink

final class FuzzyTests: XCTestCase {
    func score(_ q: String, _ t: String) -> Int? { fuzzyScore(fuzzyQuery(q), Searchable(t)) }

    func testMatchesSubsequencesOnly() {
        XCTAssertNotNil(score("vsc", "Visual Studio Code"))
        XCTAssertNotNil(score("chr", "Google Chrome"))
        XCTAssertNil(score("xyz", "Google Chrome"))
        XCTAssertNil(score("chromez", "Chrome"))
    }

    func testWordStartsAndPrefixesRankHigher() {
        // "vsc" hits three word starts in Visual Studio Code, but is scattered in "Advanced Scheduler".
        XCTAssertGreaterThan(score("vsc", "Visual Studio Code")!, score("vsc", "Advanced Scheduler")!)
        XCTAssertGreaterThan(score("saf", "Safari")!, score("saf", "Screen Sharing Safety")!)
        XCTAssertGreaterThan(score("calc", "Calculator")!, score("calc", "Chess Calcium")!)
    }

    func testCaseInsensitiveAndCamelCase() {
        XCTAssertNotNil(score("TP", "TablePlus"))
        XCTAssertGreaterThan(score("tp", "TablePlus")!, score("tp", "Settings Panel Stuff")! - 1000)
    }
}

final class CalculatorTests: XCTestCase {
    let calc = CalculatorProvider()
    func result(_ q: String) -> String? { calc.search(q).first?.title }

    func testArithmetic() {
        XCTAssertEqual(result("12*(3+4)/2"), "42")
        XCTAssertEqual(result("2^10 + sqrt(16)"), "1,028")
        XCTAssertEqual(result("-3 + 5"), "2")
        XCTAssertEqual(result("10 % 4"), "2")
        XCTAssertEqual(result("1/4"), "0.25")
    }

    func testCopiesPlainNumber() {
        guard case .copy(let text)? = calc.search("1000*3").first?.action else { return XCTFail("no copy action") }
        XCTAssertEqual(text, "3000")
    }

    func testIgnoresThingsThatArentSums() {
        XCTAssertNil(result("2024"))        // a bare number isn't a calculation
        XCTAssertNil(result("hello"))
        XCTAssertNil(result("chrome 2"))
        XCTAssertNil(result("1/0"))         // infinity isn't shown
        XCTAssertNil(result("(1+2"))
    }
}

final class URLDetectionTests: XCTestCase {
    func url(_ s: String) -> String? { URLProvider.url(from: s)?.absoluteString }

    func testRecognisesAddresses() {
        XCTAssertEqual(url("github.com/foo"), "https://github.com/foo")
        XCTAssertEqual(url("localhost:3000"), "http://localhost:3000")
        XCTAssertEqual(url("https://example.org/a?b=c"), "https://example.org/a?b=c")
        XCTAssertEqual(url("sub.example.co.uk"), "https://sub.example.co.uk")
    }

    func testIgnoresPlainText() {
        XCTAssertNil(url("hello world"))
        XCTAssertNil(url("1.5"))
        XCTAssertNil(url("foo.c"))
        XCTAssertNil(url("readme"))
    }
}

final class NameMatchingTests: XCTestCase {
    func matches(_ q: String, _ name: String, extra: [String] = []) -> Bool {
        MessagesProvider.nameMatches(MessagesProvider.words(q), MessagesProvider.words(name) + extra)
    }

    func testWordStartsOnly() {
        XCTAssertTrue(matches("may", "Maya Collins 🌹❤️"))
        XCTAssertTrue(matches("maya col", "Maya Collins"))
        XCTAssertTrue(matches("col", "Maya Collins"))
        XCTAssertFalse(matches("ya", "Maya Collins"))
        XCTAssertFalse(matches("maya", "Ramayana Ivanov"))  // letters in order, but not word starts
    }

    func testAccentsAndCase() {
        XCTAssertTrue(matches("zoe", "Zoë Brown"))
        XCTAssertTrue(matches("ZO", "zoë brown"))
    }

    func testNicknamesAndRelationships() {
        XCTAssertTrue(matches("brother", "Leo Collins", extra: ["brother"]))
        XCTAssertTrue(matches("bro", "Leo Collins", extra: ["brother"]))
        XCTAssertFalse(matches("brother", "Leo Collins"))
    }
}

final class AttributedBodyTests: XCTestCase {
    /// Builds a blob shaped like the typedstream Messages stores.
    func blob(_ text: String) -> Data {
        var d = Data([0x04, 0x0B]) + Data("streamtyped".utf8) + Data([0x81, 0xE8, 0x03, 0x84, 0x01, 0x40, 0x84, 0x84, 0x84])
        d += Data("NSString".utf8) + Data([0x01, 0x94, 0x84, 0x01, 0x2B])
        let bytes = Array(text.utf8)
        if bytes.count < 0x80 {
            d.append(UInt8(bytes.count))
        } else {
            d.append(0x81)
            d.append(UInt8(bytes.count & 0xFF))
            d.append(UInt8(bytes.count >> 8))
        }
        return d + Data(bytes) + Data([0x86, 0x84])
    }

    func testShortText() {
        XCTAssertEqual(MessagesProvider.decodeAttributedBody(blob("See you at 2")), "See you at 2")
    }

    func testLongTextUsesTwoByteLength() {
        let long = String(repeating: "abcdefghij", count: 30)
        XCTAssertEqual(MessagesProvider.decodeAttributedBody(blob(long)), long)
    }

    func testEmojiAndGarbage() {
        XCTAssertEqual(MessagesProvider.decodeAttributedBody(blob("🔥 nice")), "🔥 nice")
        XCTAssertNil(MessagesProvider.decodeAttributedBody(Data("nothing here".utf8)))
        XCTAssertNil(MessagesProvider.decodeAttributedBody(Data("NSString".utf8)))  // truncated
    }
}

final class PinsTests: XCTestCase {
    func testWhichRowsCanBePinned() {
        XCTAssertEqual(Pins.key(for: "app./Applications/Safari.app"), "app./Applications/Safari.app")
        XCTAssertEqual(Pins.key(for: "file./Users/x/Downloads"), "file./Users/x/Downloads")
        XCTAssertEqual(Pins.key(for: "keyword.mes"), "keyword.mes")
        XCTAssertEqual(Pins.key(for: "mes.pin.iMessage;-;+1555"), "mes.iMessage;-;+1555")  // "Reply to" = same chat
        XCTAssertNil(Pins.key(for: "mes.new.+1555"))
        XCTAssertNil(Pins.key(for: "calc"))
        XCTAssertNil(Pins.key(for: "web.fallback"))
    }

    func testToggleSavesToDiskInOrder() {
        let file = makeTempDir().appendingPathComponent("pins.json")
        let pins = Pins(url: file)
        pins.toggle("app.a")
        pins.toggle("app.b")
        pins.toggle("app.c")
        pins.toggle("app.b")  // unpin
        XCTAssertEqual(Pins(url: file).ids, ["app.a", "app.c"])
        XCTAssertEqual(pins.index("app.c"), 1)
    }
}

final class PendingSendTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testShowsSendingUntilTheDatabaseHasIt() {
        let history = [ContextMessage(text: "hi", fromMe: false, date: t0)]
        let (shown, remaining) = mergePendingSends(history: history, pending: [PendingSend(text: "hey", sentAt: t0)])
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(shown.last?.text, "hey")
        XCTAssertEqual(shown.last?.status, "Sending…")
    }

    func testDropsTheEchoOnceSaved() {
        let history = [ContextMessage(text: "hey", fromMe: true, status: "Delivered", date: t0.addingTimeInterval(1))]
        let (shown, remaining) = mergePendingSends(history: history, pending: [PendingSend(text: "hey", sentAt: t0)])
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertEqual(shown, history)
    }

    func testAnOldIdenticalMessageDoesntCount() {
        let old = ContextMessage(text: "ok", fromMe: true, status: "Read 9:00", date: t0.addingTimeInterval(-3600))
        let (shown, remaining) = mergePendingSends(history: [old], pending: [PendingSend(text: "ok", sentAt: t0)])
        XCTAssertEqual(remaining.count, 1)
        XCTAssertNil(shown.first?.status, "the newest status belongs to the new send")
        XCTAssertEqual(shown.last?.status, "Sending…")
    }

    func testFailuresStayAndSayWhy() {
        let failed = PendingSend(text: "yo", sentAt: t0, error: "Messages isn't signed in")
        let (shown, remaining) = mergePendingSends(history: [], pending: [failed])
        XCTAssertEqual(remaining, [failed])
        XCTAssertEqual(shown.last?.status, "Not sent: Messages isn't signed in")
        XCTAssertTrue(shown.last!.failed)
    }

    func testOnlyTheLatestSendSaysSending() {
        let (shown, _) = mergePendingSends(history: [], pending: [PendingSend(text: "a", sentAt: t0), PendingSend(text: "b", sentAt: t0)])
        XCTAssertEqual(shown.map(\.status), [nil, "Sending…"])
    }
}

final class HotKeyTests: XCTestCase {
    func testParsing() {
        XCTAssertEqual(HotKey.parse("cmd+space")?.key, 49)
        XCTAssertEqual(HotKey.parse("cmd+space")?.mods, 256)
        XCTAssertEqual(HotKey.parse("ctrl+option+space")?.mods, 4096 | 2048)
        XCTAssertNil(HotKey.parse("space"), "a hotkey needs a modifier")
        XCTAssertNil(HotKey.parse("cmd+banana"))
    }
}
