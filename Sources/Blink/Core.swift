import AppKit

/// Where a row's icon comes from.
enum Icon {
    case none
    case file(String)    // icon of the file/app at this path
    case symbol(String)  // SF Symbol name
    case thumbnail(String) // an image file, shown as itself
    case contact(String) // a contact's photo, by contact identifier (falls back to a person symbol)
}

/// Contact thumbnails, filled when Contacts loads. Images are made once and shared.
final class ContactPhotos {
    static let shared = ContactPhotos()
    private let lock = NSLock()
    private var data: [String: Data] = [:]
    private var images: [String: NSImage] = [:]

    func set(_ photos: [String: Data]) {
        lock.lock()
        data = photos
        images = [:]
        lock.unlock()
    }

    func has(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return data[id] != nil
    }

    func image(_ id: String) -> NSImage? {
        lock.lock()
        defer { lock.unlock() }
        if let img = images[id] { return img }
        guard let d = data[id], let img = NSImage(data: d) else { return nil }
        images[id] = img
        return img
    }
}

/// A second input step, e.g. "type the reply to send to Kate".
/// One line of conversation history shown above a reply.
struct ContextMessage: Equatable {
    let text: String
    let fromMe: Bool
    var sender: String? = nil
    /// Under your latest message: "Sending…", "Delivered", "Read 9:41 pm", "Not delivered".
    var status: String? = nil
    var failed = false
    var date: Date? = nil
}

struct Prompt {
    let title: String
    let placeholder: String
    /// Shown instead of the title when it is a picture (a contact photo).
    var icon: Icon = .none
    /// Optional history to show while typing. Runs off the main thread.
    var context: (() -> [ContextMessage])? = nil
    /// Stay open after sending: show the sent message, its delivery status and new replies as they arrive.
    var live = false
    /// Runs on the main thread. Returns an error message, or nil on success.
    let submit: (String) -> String?
}

enum Action {
    case none
    case open(URL)
    case copy(String)
    case run(() -> Void)
    case complete(String)  // replace the query text
    case prompt(Prompt)
    case mode(String)      // scope the launcher to the provider with this keyword
    case togglePin(String) // pin or unpin the item with this id
    case update(() -> Void) // change something and stay open (e.g. delete a clipboard entry)
}

/// A numbered extra action on a row, triggered with ⌘1…⌘9 while the row is highlighted.
struct ItemAction {
    let title: String
    let action: Action
    init(_ title: String, _ action: Action) {
        self.title = title
        self.action = action
    }
}

/// Opens a path in the Finder with the item selected.
func revealAction(_ path: String) -> Action {
    .run { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
}

struct Item {
    var id: String
    var title: String
    var subtitle: String = ""
    var icon: Icon = .none
    var badge: String? = nil
    var score: Int = 0
    var action: Action = .none
    var altAction: Action? = nil  // cmd+return
    /// Shown above everything when nothing is typed; arrow onto it and just start typing to reply.
    var pinned = false
    /// ⌘1…⌘9 actions, shown on the highlighted row. The first is normally the same as ↩.
    var actions: [ItemAction] = []
}

/// Everything the launcher can search is a Provider.
/// - keyword == nil: takes part in every query, must be fast (runs on the main thread).
/// - keyword != nil: only runs for "<keyword> <query>".
protocol Provider: AnyObject {
    var name: String { get }
    var keyword: String? { get }
    var icon: Icon { get }
    /// Slow providers (disk, database, subprocess) run off the main thread.
    var isAsync: Bool { get }
    /// Show this provider's items straight away when the query is a prefix of its name/keyword.
    var expandsOnPrefix: Bool { get }
    /// A keyword provider that also adds its results (below apps) to ordinary queries.
    var includeInGlobal: Bool { get }
    /// How many of its results join ordinary queries (nil: the files setting).
    var globalLimit: Int? { get }
    func search(_ query: String) -> [Item]
    /// Offers pinned items (shown when the query is empty). Runs off the main thread.
    var providesPinned: Bool { get }
    func pinned() -> [Item]
    /// Rebuilds items you pinned (ids as `Pins` stores them), for the empty launcher.
    func favorites(_ ids: [String]) -> [Item]
    /// Called each time the launcher opens.
    func refresh()
}

extension Provider {
    var keyword: String? { nil }
    var icon: Icon { .symbol("puzzlepiece.extension") }
    var isAsync: Bool { false }
    var expandsOnPrefix: Bool { false }
    var includeInGlobal: Bool { false }
    var globalLimit: Int? { nil }
    var providesPinned: Bool { false }
    func pinned() -> [Item] { [] }
    func favorites(_ ids: [String]) -> [Item] { [] }
    func refresh() {}
}

/// A message you just sent that the Messages database may not show yet.
struct PendingSend: Equatable {
    let text: String
    let sentAt: Date
    var error: String? = nil
}

/// What the reply view shows: the conversation plus any sends the database hasn't caught up with.
/// Returns the transcript and the sends still pending.
func mergePendingSends(history: [ContextMessage], pending: [PendingSend], limit: Int = 8) -> ([ContextMessage], [PendingSend]) {
    // A send is done once the database has a message from you with the same text from about then.
    let remaining = pending.filter { send in
        send.error != nil || !history.contains { m in
            m.fromMe && m.text == send.text && (m.date.map { $0 >= send.sentAt.addingTimeInterval(-10) } ?? false)
        }
    }
    var shown = history
    if !remaining.isEmpty {
        // The newest status belongs to the newest send.
        for i in shown.indices where shown[i].fromMe && !shown[i].failed { shown[i].status = nil }
    }
    for (i, send) in remaining.enumerated() {
        let isLast = i == remaining.count - 1
        shown.append(ContextMessage(text: send.text, fromMe: true,
                                    status: send.error.map { "Not sent: " + $0 } ?? (isLast ? "Sending…" : nil),
                                    failed: send.error != nil))
    }
    return (Array(shown.suffix(limit)), remaining)
}
