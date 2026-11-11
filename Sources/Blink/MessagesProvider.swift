import AppKit
import Contacts
import SQLite3

/// Maps phone numbers / emails to contact names, and lets you search people by name.
final class ContactIndex {
    var byHandle: [String: String] = [:]
    var idByHandle: [String: String] = [:]
    var people: [(name: String, key: Searchable, handle: String, id: String)] = []
    func searchWords(id: String) -> [String] { extraWords[id] ?? [] }
    var photos: [String: Data] = [:]
    /// Extra words a contact can be found by: nickname, middle name, company, and relationship labels
    /// ("brother") taken from related names on other cards.
    var extraWords: [String: [String]] = [:]

    static func normalize(_ handle: String) -> String {
        if handle.contains("@") { return handle.lowercased() }
        let digits = handle.filter(\.isNumber)
        return digits.count > 10 ? String(digits.suffix(10)) : digits
    }

    static func load() -> ContactIndex? {
        let store = CNContactStore()
        var status = CNContactStore.authorizationStatus(for: .contacts)
        if status == .notDetermined {
            // Asking without a usage description (e.g. the bare CLI binary) would kill the process.
            guard Bundle.main.object(forInfoDictionaryKey: "NSContactsUsageDescription") != nil else { return nil }
            let sem = DispatchSemaphore(value: 0)
            store.requestAccess(for: .contacts) { _, _ in sem.signal() }
            _ = sem.wait(timeout: .now() + 60)
            status = CNContactStore.authorizationStatus(for: .contacts)
        }
        guard status != .denied, status != .restricted, status != .notDetermined else { return nil }

        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey, CNContactOrganizationNameKey,
                    CNContactPhoneNumbersKey, CNContactEmailAddressesKey, CNContactThumbnailImageDataKey,
                    CNContactMiddleNameKey, CNContactRelationsKey] as [CNKeyDescriptor]
        let index = ContactIndex()
        var relations: [(label: String, name: String)] = []
        var idsByName: [String: String] = [:]
        do {
            try store.enumerateContacts(with: CNContactFetchRequest(keysToFetch: keys)) { c, _ in
                var name = [c.givenName, c.familyName].filter { !$0.isEmpty }.joined(separator: " ")
                if name.isEmpty { name = c.nickname.isEmpty ? c.organizationName : c.nickname }
                guard !name.isEmpty else { return }
                if let thumb = c.thumbnailImageData { index.photos[c.identifier] = thumb }
                let extra = [c.nickname, c.middleName, c.organizationName].flatMap(MessagesProvider.words)
                if !extra.isEmpty { index.extraWords[c.identifier] = extra }
                idsByName[name.lowercased()] = c.identifier
                if !c.givenName.isEmpty, idsByName[c.givenName.lowercased()] == nil { idsByName[c.givenName.lowercased()] = c.identifier }
                for r in c.contactRelations {
                    let label = CNLabeledValue<NSString>.localizedString(forLabel: r.label ?? "")
                    relations.append((label, r.value.name))
                }
                let phones = c.phoneNumbers.map { $0.value.stringValue }
                let emails = c.emailAddresses.map { $0.value as String }
                for h in phones + emails {
                    index.byHandle[normalize(h)] = name
                    index.idByHandle[normalize(h)] = c.identifier
                }
                let mobile = c.phoneNumbers.first { ($0.label ?? "").contains("Mobile") || ($0.label ?? "").contains("iPhone") }
                if let handle = mobile?.value.stringValue ?? phones.first ?? emails.first {
                    index.people.append((name, Searchable(name), handle, c.identifier))
                }
            }
        } catch { return nil }
        // "Brother: Leo" on one card makes Leo findable as "brother".
        for r in relations {
            guard let id = idsByName[r.name.lowercased()] else { continue }
            index.extraWords[id, default: []] += MessagesProvider.words(r.label)
        }
        return index
    }

    func name(for handle: String) -> String? { byHandle[ContactIndex.normalize(handle)] }

    /// Made-up contacts from a JSON file ({"+15550101": "Sarah Chen"}), for demos and screenshots.
    static func fake(from path: String?) -> ContactIndex? {
        guard let path, let data = FileManager.default.contents(atPath: path),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else { return nil }
        let index = ContactIndex()
        for (handle, name) in map {
            index.byHandle[normalize(handle)] = name
            index.people.append((name, Searchable(name), handle, "fake-" + handle))
        }
        return index
    }
    func contactID(for handle: String) -> String? { idByHandle[ContactIndex.normalize(handle)] }
}

final class MessagesProvider: Provider {
    let name = "Messages"
    let keyword: String?
    let isAsync = true
    let expandsOnPrefix = true
    /// People also show up in ordinary searches ("maya"), under apps.
    let includeInGlobal = true
    let globalLimit: Int? = 4
    let icon: Icon = .file("/System/Applications/Messages.app")

    private struct Conversation {
        var chatID: Int64
        var guid: String
        var identifier: String
        var displayName: String
        var isGroup: Bool
        var date: Int64
        var lastReceived: Int64 = 0
        var lastUnread: Int64 = 0
        var lastFromMe = false
        var unread = 0
        var preview = ""
        var handles: [String] = []
        var title = ""
        var key = Searchable("")
        var words: [String] = []
    }

    private struct DBError: Error { let message: String }

    private let lock = NSLock()
    private var cache: [Conversation] = []
    private var cacheTime = Date.distantPast
    private var contacts: ContactIndex?
    private let dbPath: String
    private let loadContacts: () -> ContactIndex?
    private let now: () -> Date
    private static let appleEpoch: Double = 978_307_200
    private static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    private static func date(_ appleNanos: Int64) -> Date {
        Date(timeIntervalSince1970: Double(appleNanos) / 1_000_000_000 + appleEpoch)
    }

    private let includeUnknown: Bool
    private let pinMinutes: Int
    var providesPinned: Bool { pinMinutes > 0 }

    init(keyword: String, includeUnknown: Bool, pinMinutes: Int,
         dbPath: String = NSHomeDirectory() + "/Library/Messages/chat.db",
         loadContacts: @escaping () -> ContactIndex? = ContactIndex.load,
         now: @escaping () -> Date = Date.init) {
        self.dbPath = dbPath
        self.loadContacts = loadContacts
        self.now = now
        self.keyword = keyword.lowercased()
        self.includeUnknown = includeUnknown
        self.pinMinutes = pinMinutes
    }

    /// Warm the cache as the launcher opens, so "mes" and pinned replies are ready sooner.
    func refresh() {
        DispatchQueue.global(qos: .userInitiated).async {
            self.lock.lock()
            _ = try? self.ensureCache(maxAge: 2)
            self.lock.unlock()
        }
    }

    /// Forget the cache, e.g. after sending, so the next open reflects the reply.
    func invalidate() {
        lock.lock()
        cacheTime = .distantPast
        lock.unlock()
    }

    /// Caller holds `lock`.
    /// The launcher refreshes this on every open, so while it is open a slightly older list is fine.
    private func ensureCache(maxAge: TimeInterval = 20) throws {
        if Date().timeIntervalSince(cacheTime) > maxAge {
            cache = try load()
            cacheTime = Date()
        }
    }

    // MARK: Database

    private func each(_ db: OpaquePointer, _ sql: String, _ body: (OpaquePointer) -> Void) throws {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let s = st else {
            throw DBError(message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(s) }
        while sqlite3_step(s) == SQLITE_ROW { body(s) }
    }

    private func str(_ s: OpaquePointer, _ col: Int32) -> String {
        sqlite3_column_text(s, col).map { String(cString: $0) } ?? ""
    }

    /// Newer macOS keeps message text in a typedstream blob rather than the `text` column.
    static func decodeAttributedBody(_ data: Data) -> String? {
        guard let r = data.range(of: Data("NSString".utf8)) else { return nil }
        var i = r.upperBound + 5
        guard i < data.count else { return nil }
        var length = Int(data[i])
        i += 1
        if length == 0x81 {
            guard i + 2 <= data.count else { return nil }
            length = Int(data[i]) | Int(data[i + 1]) << 8
            i += 2
        } else if length == 0x82 {
            guard i + 4 <= data.count else { return nil }
            length = Int(data[i]) | Int(data[i + 1]) << 8 | Int(data[i + 2]) << 16 | Int(data[i + 3]) << 24
            i += 4
        }
        guard length > 0, i + length <= data.count else { return nil }
        return String(data: data.subdata(in: i..<(i + length)), encoding: .utf8)
    }

    private func open() throws -> OpaquePointer {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = handle else {
            let msg = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            sqlite3_close(handle)
            throw DBError(message: msg)
        }
        sqlite3_busy_timeout(db, 250)
        return db
    }

    /// Message body from the `text` column, falling back to the blob, then to "Attachment".
    private func body(_ s: OpaquePointer, text: Int32, blob: Int32, attachments: Int32) -> String {
        var t = str(s, text)
        if t.isEmpty, let p = sqlite3_column_blob(s, blob) {
            t = MessagesProvider.decodeAttributedBody(Data(bytes: p, count: Int(sqlite3_column_bytes(s, blob)))) ?? ""
        }
        t = t.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty, sqlite3_column_int(s, attachments) != 0 { t = "Attachment" }
        return t
    }

    /// The last few messages of one conversation, oldest first.
    private func recent(chatID: Int64, isGroup: Bool) -> [ContextMessage] {
        lock.lock()
        defer { lock.unlock() }
        guard let db = try? open() else { return [] }
        defer { sqlite3_close(db) }
        var out: [ContextMessage] = []
        try? each(db, """
            SELECT m.text, m.attributedBody, m.is_from_me, m.cache_has_attachments, IFNULL(h.id, ''),
                   m.is_sent, m.is_delivered, m.date_read, m.error, m.date
            FROM chat_message_join j JOIN message m ON m.ROWID = j.message_id
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            WHERE j.chat_id = \(chatID) AND m.item_type = 0 AND m.associated_message_type = 0
            ORDER BY j.message_date DESC LIMIT 8
            """) { s in
            let text = body(s, text: 0, blob: 1, attachments: 3)
            guard !text.isEmpty else { return }
            let fromMe = sqlite3_column_int(s, 2) != 0
            var sender: String?
            if isGroup, !fromMe {
                let h = str(s, 4)
                sender = contacts?.name(for: h)?.split(separator: " ").first.map(String.init) ?? h
            }
            var m = ContextMessage(text: text, fromMe: fromMe, sender: sender,
                                   date: MessagesProvider.date(sqlite3_column_int64(s, 9)))
            if fromMe {
                let readAt = sqlite3_column_int64(s, 7)
                if sqlite3_column_int(s, 8) != 0 {
                    m.status = "Not delivered"
                    m.failed = true
                } else if readAt > 0 {
                    m.status = "Read " + MessagesProvider.timeFormat.string(from: MessagesProvider.date(readAt))
                } else if sqlite3_column_int(s, 6) != 0 {
                    m.status = "Delivered"
                } else if sqlite3_column_int(s, 5) != 0 {
                    m.status = "Sent"
                } else {
                    m.status = "Sending…"
                }
            }
            out.append(m)
        }
        out.reverse()
        // Like Messages: a status only under your most recent message, and only if nothing came after it.
        if let last = out.lastIndex(where: { $0.fromMe }) {
            for i in out.indices where i != last { out[i].status = nil }
            if last != out.count - 1, !out[last].failed { out[last].status = nil }
        }
        return out
    }

    private func load() throws -> [Conversation] {
        let db = try open()
        defer { sqlite3_close(db) }

        var chats: [Conversation] = []
        try each(db, """
            SELECT c.ROWID, c.guid, c.chat_identifier, IFNULL(c.display_name, ''), c.style, MAX(j.message_date)
            FROM chat c JOIN chat_message_join j ON j.chat_id = c.ROWID
            \(includeUnknown ? "WHERE c.is_filtered < 2" : "WHERE c.is_filtered = 0")
            GROUP BY c.ROWID ORDER BY 6 DESC LIMIT 150
            """) { s in
            chats.append(Conversation(chatID: sqlite3_column_int64(s, 0), guid: str(s, 1), identifier: str(s, 2),
                                      displayName: str(s, 3), isGroup: sqlite3_column_int(s, 4) == 43,
                                      date: sqlite3_column_int64(s, 5)))
        }
        var index: [Int64: Int] = [:]
        for (i, c) in chats.enumerated() { index[c.chatID] = i }

        // Unread = received, not read, from the last 60 days (older strays are usually stale rows).
        let cutoff = Int64((now().timeIntervalSince1970 - MessagesProvider.appleEpoch - 60 * 86_400) * 1_000_000_000)
        try each(db, """
            SELECT j.chat_id, COUNT(*), MAX(m.date) FROM message m JOIN chat_message_join j ON j.message_id = m.ROWID
            WHERE m.is_read = 0 AND m.is_from_me = 0 AND m.is_finished = 1 AND m.item_type = 0
              AND m.is_system_message = 0 AND m.date > \(cutoff)
            GROUP BY j.chat_id
            """) { s in
            if let i = index[sqlite3_column_int64(s, 0)] {
                chats[i].unread = Int(sqlite3_column_int(s, 1))
                chats[i].lastUnread = sqlite3_column_int64(s, 2)
            }
        }

        try each(db, "SELECT j.chat_id, h.id FROM chat_handle_join j JOIN handle h ON h.ROWID = j.handle_id") { s in
            if let i = index[sqlite3_column_int64(s, 0)] { chats[i].handles.append(str(s, 1)) }
        }

        // Latest message per conversation, for the preview line.
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
            SELECT m.text, m.attributedBody, m.is_from_me, m.cache_has_attachments
            FROM chat_message_join j JOIN message m ON m.ROWID = j.message_id
            WHERE j.chat_id = ? AND m.item_type = 0 ORDER BY j.message_date DESC LIMIT 1
            """, -1, &st, nil) == SQLITE_OK, let last = st else {
            throw DBError(message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(last) }
        var rs: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
            SELECT j.message_date FROM chat_message_join j JOIN message m ON m.ROWID = j.message_id
            WHERE j.chat_id = ? AND m.is_from_me = 0 AND m.item_type = 0 ORDER BY j.message_date DESC LIMIT 1
            """, -1, &rs, nil) == SQLITE_OK, let received = rs else {
            throw DBError(message: String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(received) }
        for i in chats.indices {
            sqlite3_reset(received)
            sqlite3_bind_int64(received, 1, chats[i].chatID)
            if sqlite3_step(received) == SQLITE_ROW { chats[i].lastReceived = sqlite3_column_int64(received, 0) }

            sqlite3_reset(last)
            sqlite3_bind_int64(last, 1, chats[i].chatID)
            guard sqlite3_step(last) == SQLITE_ROW else { continue }
            let text = body(last, text: 0, blob: 1, attachments: 3).replacingOccurrences(of: "\n", with: " ")
            chats[i].lastFromMe = sqlite3_column_int(last, 2) != 0
            chats[i].preview = (chats[i].lastFromMe ? "You: " : "") + text
        }

        if contacts == nil {
            contacts = loadContacts()
            ContactPhotos.shared.set(contacts?.photos ?? [:])
        }
        for i in chats.indices {
            let c = chats[i]
            var title: String
            if c.isGroup {
                title = c.displayName
                if title.isEmpty {
                    title = c.handles.map { h in contacts?.name(for: h)?.split(separator: " ").first.map(String.init) ?? h }
                        .joined(separator: ", ")
                }
                if title.isEmpty { title = "Group chat" }
            } else {
                title = contacts?.name(for: c.identifier) ?? c.identifier
            }
            chats[i].title = title
            chats[i].key = Searchable(title)
            chats[i].words = MessagesProvider.words(title)
            if !c.isGroup, let id = contacts?.contactID(for: c.identifier) { chats[i].words += contacts?.searchWords(id: id) ?? [] }
        }
        // Most recently received first; chats you only ever sent to fall back to their last message.
        func key(_ c: Conversation) -> Int64 { c.lastReceived > 0 ? c.lastReceived : c.date }
        return chats.sorted { key($0) > key($1) }
    }

    // MARK: Name matching

    static func words(_ name: String) -> [String] {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    /// Every typed word must start a word of the name: "may" and "maya col" match "Maya Collins", "ya" doesn't.
    /// (Loose letter-skipping matching, fine for app names, matches far too many people.)
    static func nameMatches(_ queryWords: [String], _ nameWords: [String]) -> Bool {
        queryWords.allSatisfy { q in nameWords.contains { $0.hasPrefix(q) } }
    }

    // MARK: Sending

    private static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func runScript(_ source: String) -> String? {
        var err: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&err)
        guard let err else { return nil }
        return err[NSAppleScript.errorMessage] as? String ?? "Messages refused the send"
    }

    private static func send(_ text: String, toChat guid: String) -> String? {
        runScript("tell application \"Messages\" to send \(quote(text)) to chat id \(quote(guid))")
    }

    private static func send(_ text: String, toHandle handle: String) -> String? {
        runScript("""
            tell application "Messages"
                set svc to 1st account whose service type = iMessage
                send \(quote(text)) to participant \(quote(handle)) of svc
            end tell
            """)
    }

    private static let messagesApp = URL(fileURLWithPath: "/System/Applications/Messages.app")

    /// The contact's photo when there is one.
    private func photo(handle: String) -> Icon? {
        guard let id = contacts?.contactID(for: handle), ContactPhotos.shared.has(id) else { return nil }
        return .contact(id)
    }

    private static func contactCard(_ id: String?) -> ItemAction? {
        guard let id, let url = URL(string: "addressbook://" + id) else { return nil }
        return ItemAction("Contact Card", .open(url))
    }

    private static func openThread(_ handle: String) -> Action {
        let enc = handle.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "@.+-_"))) ?? handle
        return .open(URL(string: "imessage://" + enc) ?? messagesApp)
    }

    // MARK: Items

    private func age(_ appleNanos: Int64) -> String {
        let secs = now().timeIntervalSince1970 - (Double(appleNanos) / 1_000_000_000 + MessagesProvider.appleEpoch)
        switch secs {
        case ..<60: return "now"
        case ..<3600: return "\(Int(secs / 60))m"
        case ..<86_400: return "\(Int(secs / 3600))h"
        default: return "\(Int(secs / 86_400))d"
        }
    }

    private func item(for c: Conversation, pinned: Bool) -> Item {
        let guid = c.guid, title = c.title, chatID = c.chatID, isGroup = c.isGroup
        let when = age(pinned ? c.lastUnread : (c.lastReceived > 0 ? c.lastReceived : c.date))
        let icon: Icon = c.isGroup ? .symbol("person.2.fill") : (photo(handle: c.identifier) ?? .symbol("person.crop.circle.fill"))
        let reply = Action.prompt(Prompt(
            title: title, placeholder: "Message \(title), ↩ to send", icon: icon,
            context: { [weak self] in self?.recent(chatID: chatID, isGroup: isGroup) ?? [] }, live: true
        ) { [weak self] text in
            defer { self?.invalidate() }
            return MessagesProvider.send(text, toChat: guid)
        })
        let openInMessages = c.isGroup ? Action.open(MessagesProvider.messagesApp) : MessagesProvider.openThread(c.identifier)
        var actions = [ItemAction("Reply", reply), ItemAction("Open in Messages", openInMessages)]
        if !c.isGroup, let card = MessagesProvider.contactCard(contacts?.contactID(for: c.identifier)) { actions.append(card) }
        return Item(
            id: (pinned ? "mes.pin." : "mes.") + c.guid, title: pinned ? "Reply to " + title : title,
            subtitle: when + " · " + c.preview,
            icon: icon,
            badge: c.unread > 0 ? String(c.unread) : nil,
            action: reply, altAction: openInMessages, pinned: pinned, actions: actions)
    }

    func favorites(_ ids: [String]) -> [Item] {
        let wanted = Set(ids.filter { $0.hasPrefix("mes.") }.map { String($0.dropFirst(4)) })
        guard !wanted.isEmpty else { return [] }
        lock.lock()
        defer { lock.unlock() }
        guard (try? ensureCache()) != nil else { return [] }
        return cache.filter { wanted.contains($0.guid) }.map { item(for: $0, pinned: false) }
    }

    /// Unread conversations whose latest message is recent and still unanswered.
    func pinned() -> [Item] {
        lock.lock()
        defer { lock.unlock() }
        guard (try? ensureCache()) != nil else { return [] }
        let cutoff = Int64((now().timeIntervalSince1970 - MessagesProvider.appleEpoch - Double(pinMinutes * 60)) * 1_000_000_000)
        return cache.filter { $0.unread > 0 && !$0.lastFromMe && $0.lastUnread > cutoff }
            .sorted { $0.lastUnread > $1.lastUnread }
            .prefix(3)
            .map { item(for: $0, pinned: true) }
    }

    func search(_ query: String) -> [Item] {
        lock.lock()
        defer { lock.unlock() }
        do { try ensureCache() } catch let e as DBError {
            return [Item(
                id: "mes.access", title: "Blink needs Full Disk Access to read Messages",
                subtitle: "Press ↩ to open System Settings (\(e.message))", icon: .symbol("lock.fill"),
                action: .open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!))]
        } catch { return [] }

        // Filter by name, but keep the most-recently-received order.
        let qWords = MessagesProvider.words(query)
        let matched = qWords.isEmpty ? cache : cache.filter { MessagesProvider.nameMatches(qWords, $0.words) }
        var items = matched.map { item(for: $0, pinned: false) }

        // People you haven't messaged recently.
        if !qWords.isEmpty, let contacts {
            let existing = Set(matched.map { $0.title })
            let q = fuzzyQuery(query.trimmingCharacters(in: .whitespaces))
            let people = contacts.people.compactMap { p -> (String, String, String, Int)? in
                guard !existing.contains(p.name), MessagesProvider.nameMatches(qWords, MessagesProvider.words(p.name) + contacts.searchWords(id: p.id)) else { return nil }
                return (p.name, p.handle, p.id, fuzzyScore(q, p.key) ?? 0)
            }.sorted { $0.3 > $1.3 }.prefix(5)
            for (name, handle, id, _) in people {
                let face: Icon = ContactPhotos.shared.has(id) ? .contact(id) : .symbol("square.and.pencil")
                let message = Action.prompt(Prompt(title: name, placeholder: "Message \(name), ↩ to send", icon: face) { [weak self] text in
                    defer { self?.invalidate() }
                    return MessagesProvider.send(text, toHandle: handle)
                })
                var actions = [ItemAction("Message", message), ItemAction("Open in Messages", MessagesProvider.openThread(handle))]
                if let card = MessagesProvider.contactCard(id) { actions.append(card) }
                items.append(Item(
                    id: "mes.new." + handle, title: name, subtitle: "New message · " + handle,
                    icon: face, action: message,
                    altAction: MessagesProvider.openThread(handle), actions: actions))
            }
        }
        return items
    }
}
