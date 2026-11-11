import SQLite3
import XCTest
@testable import Blink

/// Builds a small chat.db with the columns Blink reads, filled with made-up conversations.
final class FakeChatDB {
    let path: String
    private var db: OpaquePointer?
    private var nextMessage: Int64 = 1
    private static let appleEpoch: Double = 978_307_200

    init() {
        path = makeTempDir().appendingPathComponent("chat.db").path
        sqlite3_open(path, &db)
        exec("""
            CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, guid TEXT, chat_identifier TEXT, display_name TEXT,
                               style INTEGER, is_filtered INTEGER DEFAULT 0);
            CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT);
            CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
            CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER, message_date INTEGER);
            CREATE TABLE message (ROWID INTEGER PRIMARY KEY, text TEXT, attributedBody BLOB, is_from_me INTEGER,
                cache_has_attachments INTEGER DEFAULT 0, item_type INTEGER DEFAULT 0, is_read INTEGER DEFAULT 1,
                is_finished INTEGER DEFAULT 1, is_system_message INTEGER DEFAULT 0, date INTEGER, handle_id INTEGER,
                associated_message_type INTEGER DEFAULT 0, is_sent INTEGER DEFAULT 0, is_delivered INTEGER DEFAULT 0,
                date_read INTEGER DEFAULT 0, error INTEGER DEFAULT 0);
            """)
    }

    deinit { sqlite3_close(db) }

    private func exec(_ sql: String) {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            XCTFail("fixture SQL failed: \(String(cString: err!))")
        }
    }

    static func nanos(_ d: Date) -> Int64 { Int64((d.timeIntervalSince1970 - appleEpoch) * 1_000_000_000) }

    /// A one-to-one chat with `handle`. `filtered` = Messages' "Unknown Senders".
    @discardableResult
    func chat(_ id: Int64, handle: String, filtered: Int = 0, group: String? = nil) -> Int64 {
        let style = group == nil ? 45 : 43
        exec("INSERT INTO chat VALUES (\(id), 'guid-\(id)', '\(handle)', '\(group ?? "")', \(style), \(filtered))")
        exec("INSERT INTO handle VALUES (\(id), '\(handle)')")
        exec("INSERT INTO chat_handle_join VALUES (\(id), \(id))")
        return id
    }

    func message(chat: Int64, _ text: String, fromMe: Bool, at date: Date, read: Bool = true,
                 delivered: Bool = false, readAt: Date? = nil, error: Int = 0, sent: Bool = true) {
        let n = FakeChatDB.nanos(date)
        let id = nextMessage
        nextMessage += 1
        let escaped = text.replacingOccurrences(of: "'", with: "''")
        exec("""
            INSERT INTO message (ROWID, text, is_from_me, is_read, date, handle_id, is_sent, is_delivered, date_read, error)
            VALUES (\(id), '\(escaped)', \(fromMe ? 1 : 0), \(read || fromMe ? 1 : 0), \(n), \(chat),
                    \(sent ? 1 : 0), \(delivered ? 1 : 0), \(readAt.map(FakeChatDB.nanos) ?? 0), \(error))
            """)
        exec("INSERT INTO chat_message_join VALUES (\(chat), \(id), \(n))")
    }
}

final class MessagesProviderTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var db: FakeChatDB!

    override func setUp() { db = FakeChatDB() }

    func provider(pinMinutes: Int = 15, includeUnknown: Bool = false) -> MessagesProvider {
        let contacts = ContactIndex()
        let n = ContactIndex.normalize
        contacts.byHandle = [n("+15550001"): "Kate Bell", n("+15550002"): "Sam Hill", n("+15550003"): "Leo Collins"]
        contacts.idByHandle = [n("+15550003"): "contact-leo"]
        contacts.extraWords = ["contact-leo": ["brother"]]
        let fixed = now
        return MessagesProvider(keyword: "mes", includeUnknown: includeUnknown, pinMinutes: pinMinutes,
                                dbPath: db.path, loadContacts: { contacts }, now: { fixed })
    }

    func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

    func testOrdersByLastMessageReceived() {
        db.chat(1, handle: "+15550001")
        db.chat(2, handle: "+15550002")
        db.message(chat: 1, "from Kate", fromMe: false, at: ago(60))
        db.message(chat: 1, "my reply", fromMe: true, at: ago(1))  // sending doesn't move Kate up
        db.message(chat: 2, "from Sam", fromMe: false, at: ago(30))
        XCTAssertEqual(provider().search("").map(\.title), ["Sam Hill", "Kate Bell"])
    }

    func testHidesUnknownSendersUnlessAskedTo() {
        db.chat(1, handle: "+15550001")
        db.chat(2, handle: "+15559999", filtered: 1)
        db.message(chat: 1, "hi", fromMe: false, at: ago(10))
        db.message(chat: 2, "WIN A PRIZE", fromMe: false, at: ago(5))
        XCTAssertEqual(provider().search("").count, 1)
        XCTAssertEqual(provider(includeUnknown: true).search("").count, 2)
    }

    func testFiltersByNameAndNickname() {
        db.chat(1, handle: "+15550001")
        db.chat(3, handle: "+15550003")
        db.message(chat: 1, "a", fromMe: false, at: ago(10))
        db.message(chat: 3, "b", fromMe: false, at: ago(20))
        let p = provider()
        XCTAssertEqual(p.search("kat").map(\.title), ["Kate Bell"])
        XCTAssertEqual(p.search("brother").map(\.title), ["Leo Collins"])
        XCTAssertEqual(p.search("ell").map(\.title), [], "matches word starts, not the middle of names")
    }

    func testPreviewAndUnreadBadge() {
        db.chat(1, handle: "+15550001")
        db.message(chat: 1, "first", fromMe: false, at: ago(10), read: false)
        db.message(chat: 1, "second", fromMe: false, at: ago(5), read: false)
        let row = provider().search("").first
        XCTAssertEqual(row?.badge, "2")
        XCTAssertTrue(row?.subtitle.hasSuffix("second") ?? false)
        XCTAssertEqual(row?.actions.map(\.title), ["Reply", "Open in Messages"])
    }

    func testPinsRecentUnansweredUnread() {
        db.chat(1, handle: "+15550001")  // unread 5 min ago: pinned
        db.chat(2, handle: "+15550002")  // unread an hour ago: too old
        db.chat(3, handle: "+15550003")  // unread, but I replied: not pinned
        db.message(chat: 1, "you there?", fromMe: false, at: ago(5), read: false)
        db.message(chat: 2, "old news", fromMe: false, at: ago(60), read: false)
        db.message(chat: 3, "dinner?", fromMe: false, at: ago(4), read: false)
        db.message(chat: 3, "yes!", fromMe: true, at: ago(2))
        let pinned = provider().pinned()
        XCTAssertEqual(pinned.map(\.title), ["Reply to Kate Bell"])
        XCTAssertTrue(pinned.first?.pinned ?? false)
        XCTAssertTrue(provider(pinMinutes: 0).providesPinned == false)
    }

    func history(_ p: MessagesProvider, _ query: String = "") -> [ContextMessage] {
        guard case .prompt(let prompt)? = p.search(query).first?.action, let context = prompt.context else {
            XCTFail("row has no reply prompt")
            return []
        }
        XCTAssertTrue(prompt.live)
        return context()
    }

    func testReplyHistoryShowsTheLatestStatusOnly() {
        db.chat(1, handle: "+15550001")
        db.message(chat: 1, "earlier", fromMe: true, at: ago(30), delivered: true)
        db.message(chat: 1, "hey", fromMe: false, at: ago(20))
        db.message(chat: 1, "on my way", fromMe: true, at: ago(1), delivered: true, readAt: ago(0.5))
        let h = history(provider())
        XCTAssertEqual(h.map(\.text), ["earlier", "hey", "on my way"])
        XCTAssertNil(h[0].status)
        XCTAssertTrue(h[2].status?.hasPrefix("Read ") ?? false)
    }

    func testStatusWording() {
        let cases: [(String, Bool, Bool, Int, String)] = [
            ("sending", false, false, 0, "Sending…"),
            ("sent", true, false, 0, "Sent"),
            ("delivered", true, true, 0, "Delivered"),
            ("failed", true, false, 22, "Not delivered"),
        ]
        for (i, c) in cases.enumerated() {
            let id = Int64(10 + i)
            db.chat(id, handle: "+1555000\(i)")
            db.message(chat: id, c.0, fromMe: true, at: ago(Double(i)), delivered: c.2, error: c.3, sent: c.1)
        }
        let p = provider()
        for (i, c) in cases.enumerated() {
            let rows = p.search("")
            guard let row = rows.first(where: { $0.id == "mes.guid-\(10 + i)" }),
                  case .prompt(let prompt) = row.action else { return XCTFail("missing \(c.0)") }
            XCTAssertEqual(prompt.context?().last?.status, c.4, c.0)
        }
    }

    func testStatusHiddenOnceTheyReply() {
        db.chat(1, handle: "+15550001")
        db.message(chat: 1, "you coming?", fromMe: true, at: ago(5), delivered: true)
        db.message(chat: 1, "yep", fromMe: false, at: ago(1))
        XCTAssertTrue(history(provider()).allSatisfy { $0.status == nil })
    }

    func testMissingDatabaseAsksForFullDiskAccess() {
        let p = MessagesProvider(keyword: "mes", includeUnknown: false, pinMinutes: 15,
                                 dbPath: "/nonexistent/chat.db", loadContacts: { nil })
        XCTAssertEqual(p.search("").first?.id, "mes.access")
        XCTAssertTrue(p.pinned().isEmpty, "no error rows among pinned replies")
    }
}
