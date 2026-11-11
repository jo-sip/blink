import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Holds the config being edited; changes save (and apply) shortly after you stop typing.
final class SettingsModel: ObservableObject {
    @Published var config: Config
    @Published var plugins: [(name: String, keyword: String, source: String)] = []
    let save: (Config) -> Void
    let suspendHotkeys: (Bool) -> Void
    let clearClipboard: () -> Void
    let importWorkflow: (URL) -> Bool
    private var bag: AnyCancellable?
    /// Which tab opens first (the debug `--show settings:codes` uses it).
    var initialTab = "general"

    init(config: Config, plugins: [(String, String, String)], save: @escaping (Config) -> Void,
         suspendHotkeys: @escaping (Bool) -> Void, clearClipboard: @escaping () -> Void, importWorkflow: @escaping (URL) -> Bool) {
        self.config = config
        self.plugins = plugins
        self.save = save
        self.suspendHotkeys = suspendHotkeys
        self.clearClipboard = clearClipboard
        self.importWorkflow = importWorkflow
        bag = $config.dropFirst().removeDuplicates().debounce(for: .milliseconds(600), scheduler: RunLoop.main)
            .sink { [weak self] in self?.save($0) }
    }

    /// "m" → "Messages", for the extra-code pickers.
    func scopeName(_ code: String) -> String {
        if code == config.messagesKeyword { return "Messages (\(code))" }
        if code == config.clipboard.keyword { return "Clipboard (\(code))" }
        if code == config.files.keyword { return "Files (\(code))" }
        if let s = config.searches.first(where: { $0.keyword == code }) { return "\(s.name) (\(code))" }
        if let p = plugins.first(where: { $0.keyword == code }) { return "\(p.name) (\(code))" }
        return code
    }

    /// Keywords you can point a short code at.
    var keywords: [String] {
        var k = [config.messagesKeyword, config.files.keyword, config.clipboard.keyword] + config.searches.map(\.keyword)
        k += plugins.map(\.keyword)
        return Array(NSOrderedSet(array: k)) as? [String] ?? k
    }
}

/// Click, then press the new shortcut. Blink's own hotkeys pause while recording so they don't fire.
struct ShortcutRecorder: View {
    @Binding var spec: String
    let suspend: (Bool) -> Void
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button(action: toggle) {
            Text(recording ? "Press a shortcut…" : HotKey.display(spec))
                .frame(minWidth: 130)
                .foregroundColor(recording ? .accentColor : .primary)
        }
        .help("Click, then press the keys. Esc cancels.")
        .onDisappear(perform: stop)
    }

    private func toggle() { recording ? stop() : start() }

    private func start() {
        recording = true
        suspend(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 { stop(); return nil }  // esc
            let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if let s = HotKey.spec(keyCode: e.keyCode, flags: flags) {
                spec = s
                stop()
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording { suspend(false) }
        recording = false
    }
}

/// A plain bordered text box. In grouped forms a titled TextField turns its title into a label
/// and squeezes the box to nothing, so the hint goes in as placeholder text instead.
private func Field(_ hint: String, text: Binding<String>, width: CGFloat? = nil) -> some View {
    TextField("", text: text, prompt: Text(hint))
        .labelsHidden()
        .textFieldStyle(.roundedBorder)
        .frame(width: width)
}

private func listBinding(_ b: Binding<[String]>) -> Binding<String> {
    Binding(get: { b.wrappedValue.joined(separator: ", ") },
            set: { b.wrappedValue = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } })
}

private func chooseFolder() -> String? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return nil }
    return url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
}

/// A list of folders with Add/Remove.
private struct FolderList: View {
    @Binding var folders: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            List {
                ForEach(folders.indices, id: \.self) { i in
                    HStack {
                        Image(systemName: "folder")
                        Text(folders[i]).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button { folders.remove(at: i) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                    }
                }
            }
            .frame(minHeight: 140)
            Button("Add Folder…") { if let f = chooseFolder(), !folders.contains(f) { folders.append(f) } }
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @State private var newCode = ""
    @State private var newTarget = ""
    @State private var tab = ""

    var body: some View {
        TabView(selection: Binding(get: { tab.isEmpty ? model.initialTab : tab }, set: { tab = $0 })) {
            general.tabItem { Label("General", systemImage: "gearshape") }.tag("general")
            shortcuts.tabItem { Label("Codes", systemImage: "keyboard") }.tag("codes")
            searches.tabItem { Label("Searches", systemImage: "magnifyingglass") }.tag("searches")
            places.tabItem { Label("Files", systemImage: "folder") }.tag("files")
            messages.tabItem { Label("Messages", systemImage: "message") }.tag("messages")
            clipboard.tabItem { Label("Clipboard", systemImage: "doc.on.clipboard") }.tag("clipboard")
            plugins.tabItem { Label("Plugins", systemImage: "puzzlepiece.extension") }.tag("plugins")
        }
        .padding(20)
        .frame(width: 700, height: 480)
    }

    private var general: some View {
        Form {
            LabeledContent("Open Blink") { ShortcutRecorder(spec: $model.config.hotkey, suspend: model.suspendHotkeys) }
            Toggle("Launch at login", isOn: $model.config.launchAtLogin)
            Stepper("Rows shown before scrolling: \(model.config.visibleRows)", value: $model.config.visibleRows, in: 3...15)
            Stepper("Most results per search: \(model.config.maxResults)", value: $model.config.maxResults, in: 10...100, step: 10)
            Text("Changes apply as you make them.").font(.caption).foregroundColor(.secondary)
        }
        .formStyle(.grouped)
    }

    private func codeRow(_ name: String, _ code: Binding<String>, icon: String) -> some View {
        HStack {
            Image(systemName: icon).foregroundColor(.secondary).frame(width: 20)
            Text(name)
            Spacer()
            Field("code", text: code, width: 80)
        }
    }

    private var shortcuts: some View {
        Form {
            Section("Type a code, then Tab or a space, to search just that") {
                codeRow("Messages", $model.config.messagesKeyword, icon: "message")
                codeRow("Clipboard", $model.config.clipboard.keyword, icon: "doc.on.clipboard")
                codeRow("Files", $model.config.files.keyword, icon: "folder")
                ForEach(model.config.searches.indices, id: \.self) { i in
                    codeRow(model.config.searches[i].name.isEmpty ? "Search" : model.config.searches[i].name,
                            $model.config.searches[i].keyword, icon: "magnifyingglass")
                }
                ForEach(model.plugins, id: \.keyword) { p in
                    HStack {
                        Image(systemName: "puzzlepiece.extension").foregroundColor(.secondary).frame(width: 20)
                        Text(p.name)
                        Spacer()
                        Text(p.keyword).font(.system(.body, design: .monospaced)).foregroundColor(.secondary)
                            .help("A plugin's code is its file name (or the Alfred workflow's keyword).")
                    }
                }
            }
            Section("Extra codes (optional), e.g. “msg” for Messages") {
                ForEach(model.config.shortcuts.keys.sorted(), id: \.self) { code in
                    HStack {
                        Text(code).font(.system(.body, design: .monospaced)).frame(width: 60, alignment: .leading)
                        Image(systemName: "arrow.right").foregroundColor(.secondary)
                        Picker("", selection: Binding(get: { model.config.shortcuts[code] ?? "" },
                                                      set: { model.config.shortcuts[code] = $0 })) {
                            ForEach(model.keywords, id: \.self) { Text(model.scopeName($0)).tag($0) }
                        }
                        .labelsHidden()
                        Button { model.config.shortcuts[code] = nil } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                    }
                }
                HStack {
                    Field("code", text: $newCode, width: 70)
                        .onSubmit(addCode)
                    Image(systemName: "arrow.right").foregroundColor(.secondary)
                    Picker("", selection: $newTarget) {
                        Text("Choose…").tag("")
                        ForEach(model.keywords, id: \.self) { Text(model.scopeName($0)).tag($0) }
                    }
                    .labelsHidden()
                    Button("Add", action: addCode)
                        .disabled(newCode.trimmingCharacters(in: .whitespaces).isEmpty || newTarget.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func addCode() {
        let code = newCode.trimmingCharacters(in: .whitespaces).lowercased()
        guard !code.isEmpty, !newTarget.isEmpty else { return }
        model.config.shortcuts[code] = newTarget
        newCode = ""
        newTarget = ""
    }

    private var searches: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Type the keyword, a space and your search. {query} in the URL is replaced. App is optional, e.g. Google Chrome.")
                .font(.caption).foregroundColor(.secondary)
            List {
                ForEach(model.config.searches.indices, id: \.self) { i in
                    HStack {
                        Field("kw", text: $model.config.searches[i].keyword, width: 50)
                        Field("Name", text: $model.config.searches[i].name, width: 130)
                        Field("https://…{query}", text: $model.config.searches[i].url)
                        Field("App (optional)", text: Binding(get: { model.config.searches[i].app ?? "" },
                                                              set: { model.config.searches[i].app = $0.isEmpty ? nil : $0 }),
                              width: 120)
                        Button { model.config.searches.remove(at: i) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                    }
                }
            }
            Button("Add Search") { model.config.searches.append(SearchEngine(keyword: "", name: "", url: "https://")) }
        }
    }

    private var places: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading) {
                Text("Places").font(.headline)
                Text("Folders found by name in every search.").font(.caption).foregroundColor(.secondary)
                FolderList(folders: $model.config.places)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("File search").font(.headline)
                Text("“\(model.config.files.keyword)” then a space searches inside these folders.").font(.caption).foregroundColor(.secondary)
                FolderList(folders: $model.config.files.scopes)
                Field("Skip folders named (comma separated)", text: listBinding($model.config.files.excludes))
                Stepper("Most file results: \(model.config.files.maxResults)", value: $model.config.files.maxResults, in: 5...100, step: 5)
                Toggle("Also show files in every search", isOn: $model.config.files.includeInDefaultResults)
            }
        }
    }

    private var messages: some View {
        Form {
            Toggle("Include “Unknown Senders” (often spam)", isOn: $model.config.messagesIncludeUnknownSenders)
            Stepper(model.config.messagesPinMinutes == 0 ? "Don’t pin unread messages"
                        : "Pin unread messages from the last \(model.config.messagesPinMinutes) minutes",
                    value: $model.config.messagesPinMinutes, in: 0...120, step: 5)
            Text("Needs Full Disk Access (to read Messages), Contacts, and Automation → Messages (to send) in System Settings → Privacy & Security.")
                .font(.caption).foregroundColor(.secondary)
        }
        .formStyle(.grouped)
    }

    private var clipboard: some View {
        Form {
            Toggle("Keep clipboard history", isOn: $model.config.clipboard.enabled)
            LabeledContent("Open clipboard history") {
                ShortcutRecorder(spec: $model.config.clipboard.hotkey, suspend: model.suspendHotkeys)
            }
            Stepper("Remember the last \(model.config.clipboard.maxItems) copies", value: $model.config.clipboard.maxItems, in: 50...1000, step: 50)
            LabeledContent("Never record from apps") {
                Field("bundle IDs, comma separated", text: listBinding($model.config.clipboard.ignoreApps), width: 320)
            }
            Text("Passwords and codes that apps mark as private are never recorded. Pasting straight into apps needs Accessibility permission; without it, entries are copied, ready for ⌘V.")
                .font(.caption).foregroundColor(.secondary)
            Button("Clear History…") {
                let alert = NSAlert()
                alert.messageText = "Clear clipboard history?"
                alert.informativeText = "Pinned entries are kept. This can’t be undone."
                alert.addButton(withTitle: "Clear")
                alert.addButton(withTitle: "Cancel")
                if alert.runModal() == .alertFirstButtonReturn { model.clearClipboard() }
            }
        }
        .formStyle(.grouped)
    }

    private var plugins: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Scripts in the plugins folder and imported Alfred workflows. Both can print Blink’s or Alfred’s Script Filter JSON.")
                .font(.caption).foregroundColor(.secondary)
            List(model.plugins, id: \.keyword) { p in
                HStack {
                    Text(p.keyword).font(.system(.body, design: .monospaced)).frame(width: 70, alignment: .leading)
                    Text(p.name)
                    Spacer()
                    Text(p.source).font(.caption).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            HStack {
                Button("Open Plugins Folder") { NSWorkspace.shared.open(Config.pluginsDir) }
                Button("Import Alfred Workflow…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [UTType(filenameExtension: "alfredworkflow") ?? .zip]
                    panel.allowsMultipleSelection = true
                    guard panel.runModal() == .OK else { return }
                    for url in panel.urls { _ = model.importWorkflow(url) }
                }
            }
        }
    }
}

/// The Settings window (⌘, in the launcher, or the menu bar icon).
final class SettingsWindow {
    private var window: NSWindow?

    func show(model: SettingsModel) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 520),
                             styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "Blink Settings"
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        window?.contentViewController = NSHostingController(rootView: SettingsView(model: model))
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    var isVisible: Bool { window?.isVisible ?? false }
}
