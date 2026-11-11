import AppKit

private final class Panel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private final class RowView: NSTableRowView {
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }
    override func drawSelection(in dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 8, dy: 1), xRadius: 12, yRadius: 12).fill()
    }
}

/// Chat-style history shown under the bar while replying.
private final class TranscriptView: NSStackView {
    private let maxBubble: CGFloat = 430

    init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 5
        edgeInsets = NSEdgeInsets(top: 2, left: 0, bottom: 14, right: 0)
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(_ messages: [ContextMessage]) {
        arrangedSubviews.forEach { $0.removeFromSuperview() }
        for m in messages {
            let label = NSTextField(wrappingLabelWithString: "")
            let text = NSMutableAttributedString()
            let color: NSColor = m.fromMe ? .white : .labelColor
            if let sender = m.sender {
                text.append(NSAttributedString(string: sender + "  ", attributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor]))
            }
            text.append(NSAttributedString(string: m.text, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: color]))
            label.attributedStringValue = text
            label.maximumNumberOfLines = 3
            label.lineBreakMode = .byTruncatingTail
            label.preferredMaxLayoutWidth = maxBubble - 20
            label.isSelectable = false
            label.translatesAutoresizingMaskIntoConstraints = false

            let bubble = NSView()
            bubble.wantsLayer = true
            bubble.layer?.cornerRadius = 11
            bubble.layer?.backgroundColor = (m.fromMe ? NSColor.systemBlue : NSColor.labelColor.withAlphaComponent(0.12)).cgColor
            bubble.translatesAutoresizingMaskIntoConstraints = false
            bubble.addSubview(label)

            let row = NSView()
            row.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(bubble)
            addArrangedSubview(row)
            if m.fromMe {
                bubble.layer?.backgroundColor = (m.failed ? NSColor.systemRed : NSColor.systemBlue)
                    .withAlphaComponent(m.status == "Sending…" ? 0.6 : 1).cgColor
            }
            NSLayoutConstraint.activate([
                label.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 5),
                label.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -5),
                label.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 10),
                label.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -10),
                bubble.topAnchor.constraint(equalTo: row.topAnchor),
                bubble.bottomAnchor.constraint(equalTo: row.bottomAnchor),
                bubble.widthAnchor.constraint(lessThanOrEqualToConstant: maxBubble),
                m.fromMe ? bubble.trailingAnchor.constraint(equalTo: row.trailingAnchor)
                         : bubble.leadingAnchor.constraint(equalTo: row.leadingAnchor),
                row.widthAnchor.constraint(equalTo: widthAnchor),
            ])
            if let status = m.status {
                let note = NSTextField(labelWithString: status)
                note.font = .systemFont(ofSize: 11, weight: .medium)
                note.textColor = m.failed ? .systemRed : .secondaryLabelColor
                note.alignment = .right
                note.translatesAutoresizingMaskIntoConstraints = false
                addArrangedSubview(note)
                note.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
                setCustomSpacing(2, after: row)
            }
        }
    }
}

/// The picture for an icon, and whether it should be drawn as a circle (contact photos).
func resolveIcon(_ icon: Icon) -> (image: NSImage?, tint: NSColor?, round: Bool) {
    switch icon {
    case .none:
        return (nil, nil, false)
    case .file(let path):
        return (IconCache.file(path), nil, false)
    case .symbol(let name):
        return (NSImage(systemSymbolName: name, accessibilityDescription: nil), .secondaryLabelColor, false)
    case .thumbnail(let path):
        return (IconCache.thumbnail(path), nil, false)
    case .contact(let id):
        if let img = ContactPhotos.shared.image(id) { return (img, nil, true) }
        return (NSImage(systemSymbolName: "person.crop.circle.fill", accessibilityDescription: nil), .secondaryLabelColor, false)
    }
}

enum IconCache {
    private static var files: [String: NSImage] = [:]
    private static var thumbs: [String: NSImage] = [:]
    static func thumbnail(_ path: String) -> NSImage? {
        if let img = thumbs[path] { return img }
        guard let img = NSImage(contentsOfFile: path) else { return nil }
        thumbs[path] = img
        return img
    }
    static func file(_ path: String) -> NSImage {
        if let img = files[path] { return img }
        let img = NSWorkspace.shared.icon(forFile: path)
        files[path] = img
        return img
    }
}

/// An image view that can clip to a circle.
final class IconView: NSImageView {
    func show(_ icon: Icon) {
        let r = resolveIcon(icon)
        image = r.image
        contentTintColor = r.tint
        wantsLayer = true
        layer?.cornerRadius = r.round ? min(bounds.width, bounds.height) / 2 : 0
        layer?.masksToBounds = r.round
    }

    override func layout() {
        super.layout()
        if layer?.masksToBounds == true { layer?.cornerRadius = min(bounds.width, bounds.height) / 2 }
    }
}

/// One ⌘-number action on a row. Hover highlights it, a click runs it; the focused one is filled in.
private final class Chip: NSView {
    private let label = NSTextField(labelWithString: "")
    private let index: Int
    private let title: String
    var onHover: ((Int?) -> Void)?
    var onClick: ((Int) -> Void)?

    init(index: Int, title: String) {
        self.index = index
        self.title = title
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
        setFocused(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setFocused(_ focused: Bool) {
        layer?.backgroundColor = focused ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
        let text = NSMutableAttributedString(string: "⌘\(index + 1) ", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: focused ? NSColor.white.withAlphaComponent(0.75) : NSColor.tertiaryLabelColor])
        text.append(NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: focused ? .semibold : .regular),
            .foregroundColor: focused ? NSColor.white : NSColor.secondaryLabelColor]))
        label.attributedStringValue = text
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(index) }
    override func mouseExited(with event: NSEvent) { onHover?(nil) }
    override func mouseDown(with event: NSEvent) { onClick?(index) }
    // Don't let the label swallow clicks meant for the chip.
    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
}

/// Rounded label that centres its text optically (on the cap height, not the line box).
final class Pill: NSView {
    var text = "" { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    var color: NSColor = .systemBlue { didSet { needsDisplay = true } }
    var textColor: NSColor = .white { didSet { needsDisplay = true } }
    var image: NSImage? { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }
    private var imageSide: CGFloat { height - 8 }
    private let font: NSFont
    private let height: CGFloat
    private let pad: CGFloat

    init(font: NSFont, height: CGFloat, pad: CGFloat) {
        self.font = font
        self.height = height
        self.pad = pad
        super.init(frame: .zero)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var attrs: [NSAttributedString.Key: Any] { [.font: font, .foregroundColor: textColor] }

    override var intrinsicContentSize: NSSize {
        var w = ceil((text as NSString).size(withAttributes: attrs).width) + pad * 2
        if image != nil { w += imageSide + 6 }
        return NSSize(width: max(height, w), height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: min(bounds.height / 2, 8), yRadius: min(bounds.height / 2, 8)).fill()
        let size = (text as NSString).size(withAttributes: attrs)
        var textX = bounds.midX - size.width / 2
        if let image {
            let side = imageSide
            image.draw(in: NSRect(x: pad - 3, y: (bounds.height - side) / 2, width: side, height: side))
            textX = pad - 3 + side + 6
        }
        // draw(at:) places the line box's bottom-left; lift it so the cap height sits in the middle.
        let y = bounds.midY - font.capHeight / 2 + font.descender
        (text as NSString).draw(at: NSPoint(x: textX, y: y.rounded()), withAttributes: attrs)
    }
}

/// Table that highlights the row under the mouse as it moves.
private final class HoverTableView: NSTableView {
    var onHover: ((Int) -> Void)?
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    private var lastMouse: NSPoint?

    /// Forget the pointer position, so a launcher opening under a still mouse keeps the top row.
    func resetHover() { lastMouse = NSEvent.mouseLocation }

    override func mouseMoved(with event: NSEvent) {
        let now = NSEvent.mouseLocation
        defer { lastMouse = now }
        // macOS can send a "move" when the window appears or rows shift; only follow real pointer motion.
        guard let last = lastMouse, hypot(now.x - last.x, now.y - last.y) > 2 else { return }
        let r = row(at: convert(event.locationInWindow, from: nil))
        if r >= 0 { onHover?(r) }
    }
}

private final class ItemCell: NSTableCellView {
    private let iconView = IconView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let badge = Pill(font: .systemFont(ofSize: 11, weight: .bold), height: 18, pad: 6)
    private let pinMark = NSImageView(image: NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pinned") ?? NSImage())
    private let chips = NSStackView()
    private var actionTitles: [String] = []
    private var shownState: (on: Bool, focus: Int?)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = .systemFont(ofSize: 15, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        chips.orientation = .horizontal
        chips.spacing = 4
        chips.isHidden = true
        chips.setHuggingPriority(.required, for: .horizontal)
        iconView.imageScaling = .scaleProportionallyUpOrDown

        let text = NSStackView(views: [title, subtitle])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        pinMark.contentTintColor = .tertiaryLabelColor
        pinMark.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        let right = NSStackView(views: [chips, pinMark, badge])
        right.orientation = .horizontal
        right.spacing = 10
        right.alignment = .centerY
        right.setHuggingPriority(.required, for: .horizontal)
        for v in [iconView, text, right] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 28),
            iconView.heightAnchor.constraint(equalToConstant: 28),
            text.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.trailingAnchor.constraint(lessThanOrEqualTo: right.leadingAnchor, constant: -12),
            right.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            right.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The ⌘-number actions only show on the highlighted row.
    var onChipHover: ((Int?) -> Void)?
    var onChipClick: ((Int) -> Void)?

    func setHighlighted(_ on: Bool, focus: Int? = nil) {
        if let shown = shownState, shown.on == on, shown.focus == focus { return }
        let rebuild = shownState == nil || chips.arrangedSubviews.count != actionTitles.count
        shownState = (on, focus)
        chips.isHidden = !on || actionTitles.isEmpty
        if rebuild {
            // Built once per row; focus changes only restyle, so hovering doesn't recreate what's under the mouse.
            chips.arrangedSubviews.forEach { $0.removeFromSuperview() }
            for (i, t) in actionTitles.enumerated() {
                let chip = Chip(index: i, title: t)
                chip.onHover = { [weak self] i in self?.onChipHover?(i) }
                chip.onClick = { [weak self] i in self?.onChipClick?(i) }
                chips.addArrangedSubview(chip)
            }
        }
        for case let (i, chip as Chip) in chips.arrangedSubviews.enumerated() { chip.setFocused(on && i == focus) }
    }

    func configure(_ item: Item) {
        title.stringValue = item.title
        subtitle.stringValue = item.subtitle
        subtitle.isHidden = item.subtitle.isEmpty
        pinMark.isHidden = !(Pins.key(for: item.id).map(Pins.shared.contains) ?? false)
        badge.text = item.badge ?? ""
        badge.isHidden = item.badge == nil
        actionTitles = item.actions.count >= 2 ? item.actions.prefix(9).map(\.title) : []
        shownState = nil
        iconView.show(item.icon)
    }
}

final class Launcher: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSWindowDelegate {
    private let engine: Engine
    private let panel: Panel
    private let field = NSTextField()
    private let scopeIcon = IconView()
    private let modeLabel = Pill(font: .systemFont(ofSize: 15, weight: .semibold), height: 28, pad: 11)
    private let table = HoverTableView()
    private let scroll = NSScrollView()
    private var items: [Item] = []
    private let transcript = TranscriptView()
    private var prompt: Prompt?
    private var promptToken = 0
    /// The user arrowed to a row for this query, so refinements keep their selection.
    private var userMoved = false
    /// What is on screen, to skip redraws when a refinement changes nothing.
    private var signature = ""

    // Desktop (Space) switching: an open launcher follows you instead of closing.
    private var wantsOpen = false
    private var pendingHide: DispatchWorkItem?
    private var lastSpaceChange = Date.distantPast
    private var autoHiddenAt = Date.distantPast
    private var savedQuery = ""
    /// Scoped search, e.g. Messages after "m" + Tab. Holds the provider keyword.
    private var mode: String?
    private var savedMode: String?
    /// Which ⌘-number action of the highlighted row Tab has moved onto (nil: the row itself).
    private var actionFocus: Int?
    var onOpenSettings: (() -> Void)?
    private var keyMonitor: Any?
    private var spaceObserver: NSObjectProtocol?
    /// Row to keep highlighted across the redraw after pinning or unpinning it.
    private var reselectID: String?

    // Live reply view: messages you just sent, shown until the Messages database has them.
    private var echoes: [PendingSend] = []
    private var history: [ContextMessage] = []
    private var shownTranscript: [ContextMessage] = []
    private var liveTimer: Timer?

    private let width: CGFloat = 720
    private let barHeight: CGFloat = 60
    private let rowHeight: CGFloat = 46
    /// Space between the floating search bar and the results.
    private let gap: CGFloat = 8
    /// Clear space around the glass inside the window, so the glass's own shadow isn't cut off in a straight line.
    private let margin: CGFloat = 28
    private var listPanel: NSView!
    private let maxRows: Int

    init(engine: Engine, maxRows: Int = 8) {
        self.engine = engine
        self.maxRows = min(max(maxRows, 1), 15)
        panel = Panel(contentRect: NSRect(x: 0, y: 0, width: width + 56, height: barHeight + 56),
                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()

        panel.isFloatingPanel = true
        panel.level = .modalPanel
        panel.backgroundColor = .clear
        panel.isOpaque = false
        // Liquid Glass draws its own shadow; the window's rectangular one shows as a box around the corners.
        panel.hasShadow = true
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) { panel.hasShadow = false }
        #endif
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self

        // Two floating pieces: the search bar, and the results below it with a gap between.
        let root = NSView()
        panel.contentView = root
        /// Apple's Liquid Glass on macOS 26+, the older frosted blur before that.
        /// Returns the piece to position (outer) and the view its contents go in (inner).
        func glass(radius: CGFloat) -> (outer: NSView, inner: NSView) {
            #if compiler(>=6.2)  // Liquid Glass needs the macOS 26 SDK (Xcode 26)
            if #available(macOS 26.0, *) {
                let g = NSGlassEffectView()
                g.style = .regular
                g.cornerRadius = radius
                let inner = NSView()
                g.contentView = inner
                g.translatesAutoresizingMaskIntoConstraints = false
                root.addSubview(g)
                return (g, inner)
            }
            #endif
            let v = NSVisualEffectView()
            v.material = .hudWindow
            v.state = .active
            v.blendingMode = .behindWindow
            v.wantsLayer = true
            v.layer?.cornerRadius = radius
            v.layer?.masksToBounds = true
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
            return (v, v)
        }
        let (barGlass, bg) = glass(radius: 22)
        let (listGlass, list) = glass(radius: 18)
        listPanel = listGlass
        listGlass.isHidden = true

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 24, weight: .light)
        field.placeholderString = "Search…"
        field.delegate = self
        field.cell?.isScrollable = true
        field.cell?.wraps = false

        modeLabel.isHidden = true

        scopeIcon.imageScaling = .scaleProportionallyUpOrDown
        scopeIcon.isHidden = true
        scopeIcon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scopeIcon.widthAnchor.constraint(equalToConstant: 34),
            scopeIcon.heightAnchor.constraint(equalToConstant: 34),
        ])
        let bar = NSStackView(views: [scopeIcon, modeLabel, field])
        bar.orientation = .horizontal
        bar.spacing = 12
        bar.alignment = .centerY
        bar.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(bar)

        let column = NSTableColumn(identifier: .init("main"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.backgroundColor = .clear
        table.rowHeight = rowHeight
        table.intercellSpacing = .zero
        table.style = .plain
        table.selectionHighlightStyle = .regular
        table.refusesFirstResponder = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.onHover = { [weak self] row in
            guard let self, row != self.table.selectedRow, row < self.items.count else { return }
            self.userMoved = true
            self.actionFocus = nil
            self.table.selectRowIndexes([row], byExtendingSelection: false)
        }

        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.translatesAutoresizingMaskIntoConstraints = false
        list.addSubview(scroll)

        transcript.translatesAutoresizingMaskIntoConstraints = false
        transcript.isHidden = true
        list.addSubview(transcript)

        NSLayoutConstraint.activate([
            barGlass.topAnchor.constraint(equalTo: root.topAnchor, constant: margin),
            barGlass.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: margin),
            barGlass.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -margin),
            barGlass.heightAnchor.constraint(equalToConstant: barHeight),
            listGlass.topAnchor.constraint(equalTo: barGlass.bottomAnchor, constant: gap),
            listGlass.leadingAnchor.constraint(equalTo: barGlass.leadingAnchor),
            listGlass.trailingAnchor.constraint(equalTo: barGlass.trailingAnchor),
            listGlass.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -margin),
            bar.topAnchor.constraint(equalTo: bg.topAnchor),
            bar.bottomAnchor.constraint(equalTo: bg.bottomAnchor),
            bar.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 22),
            bar.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -22),
            transcript.topAnchor.constraint(equalTo: list.topAnchor, constant: 14),
            transcript.leadingAnchor.constraint(equalTo: list.leadingAnchor, constant: 22),
            transcript.trailingAnchor.constraint(equalTo: list.trailingAnchor, constant: -22),
            scroll.topAnchor.constraint(equalTo: list.topAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: list.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: list.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: list.bottomAnchor, constant: -6),
        ])

        engine.onUpdate = { [weak self] found, refinement in
            guard let self, self.prompt == nil else { return }
            self.setItems(found, refinement: refinement)
        }

        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.spaceChanged() }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, self.panel.isKeyWindow else { return e }
            return self.handleKey(e) ? nil : e
        }
    }

    /// A reload replaces the launcher; the old one stops listening.
    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        panel.orderOut(nil)
    }

    // MARK: Show / hide

    var isVisible: Bool { panel.isVisible }

    /// Provider data changed underneath an open launcher.
    func dataChanged() {
        if isVisible, prompt == nil { engine.requery() }
    }

    func toggle() { isVisible ? hide() : show() }

    /// For screenshots: a colourful wallpaper window just behind the launcher (BLINK_BACKDROP=1).
    private var backdrop: NSWindow?
    private func placeBackdrop() {
        guard ProcessInfo.processInfo.environment["BLINK_BACKDROP"] != nil else { return }
        let f = panel.frame
        let rect = NSRect(x: f.minX - 42, y: f.maxY - 640, width: f.width + 84, height: 680)
        if backdrop == nil {
            let w = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
            w.level = .floating
            w.isOpaque = true
            w.ignoresMouseEvents = true
            w.contentView = NSImageView(image: NSImage(size: rect.size, flipped: false) { r in
                NSGradient(colors: [NSColor(srgbRed: 0.98, green: 0.55, blue: 0.45, alpha: 1),
                                    NSColor(srgbRed: 0.62, green: 0.38, blue: 0.95, alpha: 1),
                                    NSColor(srgbRed: 0.20, green: 0.55, blue: 0.98, alpha: 1)],
                           atLocations: [0, 0.5, 1], colorSpace: .sRGB)!.draw(in: r, angle: -30)
                for (x, y, d, c) in [(0.15, 0.75, 0.55, NSColor.systemYellow), (0.85, 0.25, 0.6, NSColor.systemTeal),
                                     (0.6, 0.85, 0.4, NSColor.systemPink)] as [(CGFloat, CGFloat, CGFloat, NSColor)] {
                    let s = r.width * d
                    NSGradient(colors: [c.withAlphaComponent(0.55), c.withAlphaComponent(0)])!
                        .draw(in: NSBezierPath(ovalIn: NSRect(x: r.width * x - s / 2, y: r.height * y - s / 2, width: s, height: s)),
                              relativeCenterPosition: .zero)
                }
                return true
            })
            backdrop = w
        }
        backdrop?.setFrame(rect, display: true)
        backdrop?.orderFront(nil)
    }

    func show() {
        wantsOpen = true
        pendingHide?.cancel()
        userMoved = false
        actionFocus = nil
        table.resetHover()
        signature = ""
        prompt = nil
        mode = nil
        promptToken += 1
        transcript.isHidden = true
        updatePill()
        field.stringValue = ""
        engine.refresh()
        runQuery()
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let vf = screen?.visibleFrame {
            let top = vf.maxY - vf.height * 0.22
            panel.setFrameOrigin(NSPoint(x: vf.midX - panel.frame.width / 2, y: top + margin - panel.frame.height))
        }
        placeBackdrop()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    func show(query: String) {
        show()
        if !query.isEmpty { setQuery(query) }
    }

    private let debug = ProcessInfo.processInfo.environment["BLINK_DEBUG"] != nil
    private func debugLog(_ s: String) {
        if debug { FileHandle.standardError.write("[\(field.stringValue)] \(s)\n".data(using: .utf8)!) }
    }

    /// Debug aid: opens straight into a scope, as if its short code and Tab were typed.
    func showMode(_ spec: String) {
        show()
        let parts = spec.split(separator: ":", maxSplits: 1).map(String.init)
        enterMode(parts[0])
        guard parts.count > 1 else { return }
        for (i, q) in parts[1].split(separator: ",").enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6 + 0.15 * Double(i)) { self.setQuery(String(q)) }
        }
    }

    /// Debug aid: types each query in turn, like keystrokes.
    func typeSequence(_ queries: [String], gap: Double = 0.08) {
        show()
        for (i, q) in queries.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6 + gap * Double(i)) { self.setQuery(q) }
        }
    }

    /// Debug aid: a pinned reply row above the usual results, for checking layout.
    func demoPinned() {
        show()
        var pin = Item(id: "demo.pin", title: "Reply to Sarah Chen", subtitle: "2m · Are we still on for Saturday?",
                       icon: .symbol("person.crop.circle.fill"), badge: "2", score: 20_000, pinned: true)
        pin.action = .prompt(Prompt(title: "Sarah Chen", placeholder: "Type a message, ↩ to send") { _ in nil })
        pin.actions = [ItemAction("Reply", pin.action), ItemAction("Open in Messages", .none), ItemAction("Contact Card", .none)]
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            self.setItems([pin] + self.items.filter { !$0.pinned })
            self.userMoved = true
            self.table.selectRowIndexes([0], byExtendingSelection: false)
            self.tab(backward: false)
            self.tab(backward: false)
        }
    }

    /// Debug aid: a live reply with made-up messages; sends "On it 🧊 see you soon" and fakes delivery.
    func demoLive() {
        show()
        let lock = NSLock()
        var log = [ContextMessage(text: "Are you still coming tonight? 🎉", fromMe: false),
                   ContextMessage(text: "Yes! Leaving work at 6", fromMe: true),
                   ContextMessage(text: "Perfect. Grab some ice on the way?", fromMe: false)]
        let prompt = Prompt(title: "Sarah Chen", placeholder: "Message Sarah Chen, ↩ to send",
                            context: { lock.lock(); defer { lock.unlock() }; return log }, live: true) { text in
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.2) {
                lock.lock()
                log.append(ContextMessage(text: text, fromMe: true, status: "Delivered", date: Date()))
                lock.unlock()
            }
            return nil
        }
        enter(prompt)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            self.field.stringValue = "On it 🧊 see you soon"
            self.sendLive("On it 🧊 see you soon", with: prompt)
        }
    }

    /// Debug aid: the reply view with made-up messages, for checking layout.
    func demoPrompt() {
        show()
        enter(Prompt(title: "Sarah Chen", placeholder: "Type a message, ↩ to send", context: {
            [ContextMessage(text: "Are you still coming tonight? 🎉", fromMe: false),
             ContextMessage(text: "Yes! I'll bring the long extension lead and the spare monitor, and I can pick up food on the way if you tell me what everyone wants.", fromMe: true),
             ContextMessage(text: "Perfect", fromMe: false, sender: "Sam"),
             ContextMessage(text: "See you at 2", fromMe: false)]
        }) { _ in nil })
    }

    func hide() {
        stopLive()
        wantsOpen = false
        pendingHide?.cancel()
        pendingHide = nil
        panel.orderOut(nil)
    }

    /// Take keyboard focus back without disturbing what has been typed.
    private func refocus() {
        wantsOpen = true
        panel.orderFrontRegardless()
        panel.makeKey()
        if field.currentEditor() == nil {
            panel.makeFirstResponder(field)
            let end = (field.stringValue as NSString).length
            field.currentEditor()?.selectedRange = NSRange(location: end, length: 0)
        }
    }

    private func spaceChanged() {
        lastSpaceChange = Date()
        // Reopen if focus loss from the swipe already closed it a moment ago.
        guard wantsOpen || Date().timeIntervalSince(autoHiddenAt) < 1.5 else { return }
        pendingHide?.cancel()
        pendingHide = nil
        refocus()
        // The new desktop's app can grab focus as the swipe settles; take it back once more.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.wantsOpen, !self.panel.isKeyWindow else { return }
            self.refocus()
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        pendingHide?.cancel()
        pendingHide = nil
    }

    /// Clicking elsewhere closes the launcher, but a desktop swipe shouldn't, so wait briefly to tell them apart.
    func windowDidResignKey(_ notification: Notification) {
        guard wantsOpen else { return }
        pendingHide?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.wantsOpen, !self.panel.isKeyWindow else { return }
            if Date().timeIntervalSince(self.lastSpaceChange) < 1 {
                self.refocus()
            } else {
                self.hide()
                self.autoHiddenAt = Date()
            }
        }
        pendingHide = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    // MARK: Results

    private func setItems(_ new: [Item], refinement: Bool = false) {
        let sig = new.map { "\($0.id)\u{1}\($0.title)\u{1}\($0.subtitle)\u{1}\($0.badge ?? "")" }.joined(separator: "\u{2}")
        if refinement, sig == signature { debugLog("skip (unchanged) \(new.count)"); return }  // nothing changed: don't touch the screen
        signature = sig
        debugLog("draw \(new.count) rows\(refinement ? " (refinement)" : ""), top matches text: \(new.first.map { $0.title.lowercased().contains(field.stringValue.lowercased()) } ?? false)")

        let previous = table.selectedRow >= 0 && table.selectedRow < items.count ? items[table.selectedRow].id : nil
        let keptFocus = actionFocus
        actionFocus = nil
        items = new
        table.reloadData()
        if items.isEmpty {
        } else if prompt == nil, field.stringValue.isEmpty, items[0].pinned, !userMoved {
            // Pinned replies wait for ↓ (or ↩), so typing still searches.
            table.deselectAll(nil)
            // Reused row views can keep their old highlight after a reload; clear it explicitly.
            table.enumerateAvailableRowViews { rowView, _ in rowView.isSelected = false }
            table.scrollRowToVisible(0)
        } else if let id = reselectID, let row = items.firstIndex(where: { Pins.key(for: $0.id) == id || $0.id == id }) {
            reselectID = nil
            userMoved = true
            table.selectRowIndexes([row], byExtendingSelection: false)
            table.scrollRowToVisible(row)
        } else if refinement, userMoved, let id = previous, let row = items.firstIndex(where: { $0.id == id }) {
            actionFocus = keptFocus
            table.selectRowIndexes([row], byExtendingSelection: false)
            refreshHighlights()
        } else {
            userMoved = false
            table.selectRowIndexes([0], byExtendingSelection: false)
            table.scrollRowToVisible(0)
        }
        debugLog("selected row \(table.selectedRow), field empty \(field.stringValue.isEmpty), first pinned \(items.first?.pinned ?? false), moved \(userMoved)")
        resize()
    }

    /// Fits the panel to its content, keeping the top edge where it is.
    private func resize() {
        let rows = min(items.count, maxRows)
        var listHeight: CGFloat = rows > 0 ? CGFloat(rows) * rowHeight + 12 : 0
        if !transcript.isHidden, rows == 0 {
            panel.contentView?.layoutSubtreeIfNeeded()
            listHeight = transcript.fittingSize.height + 14
        }
        listPanel.isHidden = listHeight == 0
        let height = barHeight + (listHeight > 0 ? gap + listHeight : 0) + margin * 2
        var f = panel.frame
        f.origin.y += f.height - height
        f.size.height = height
        panel.setFrame(f, display: true)
        panel.invalidateShadow()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? ItemCell ?? {
            let c = ItemCell(frame: .zero)
            c.identifier = id
            return c
        }()
        cell.configure(items[row])
        cell.onChipHover = { [weak self] index in
            guard let self, row == self.table.selectedRow, index != self.actionFocus else { return }
            self.actionFocus = index
            self.refreshHighlights()
        }
        cell.onChipClick = { [weak self] index in
            guard let self, row < self.items.count, index < self.items[row].actions.count else { return }
            self.perform(self.items[row].actions[index].action, for: self.items[row])
        }
        cell.setHighlighted(row == tableView.selectedRow, focus: row == tableView.selectedRow ? actionFocus : nil)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        refreshHighlights()
    }

    private func refreshHighlights() {
        let selected = table.selectedRow
        table.enumerateAvailableRowViews { _, row in
            (self.table.view(atColumn: 0, row: row, makeIfNecessary: false) as? ItemCell)?
                .setHighlighted(row == selected, focus: row == selected ? self.actionFocus : nil)
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { RowView() }

    func controlTextDidChange(_ obj: Notification) {
        if prompt == nil {
            userMoved = false
            actionFocus = nil
            runQuery()
        }
    }

    // MARK: Keys

    private func handleKey(_ e: NSEvent) -> Bool {
        if let editor = field.currentEditor() as? NSTextView, editor.hasMarkedText() { return false }
        let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch Int(e.keyCode) {
        case 124 where stepAction(1): return true                 // → onto the next action
        case 123 where stepAction(-1): return true                // ← back
        case 125: move(1); return true                           // down
        case 126: move(-1); return true                          // up
        case 45 where mods == .control: move(1); return true     // ctrl+n
        case 35 where mods == .control: move(-1); return true    // ctrl+p
        case 36, 76: activate(alt: mods.contains(.command)); return true
        case 48: tab(backward: mods.contains(.shift)); return true  // tab / shift-tab
        case 53: escape(); return true
        case 51 where prompt == nil && mode != nil && field.stringValue.isEmpty && mods.isDisjoint(with: [.command, .option]):
            exitMode(); return true                              // backspace on empty leaves the scope
        case 43 where mods == .command:                          // ⌘, settings
            onOpenSettings?()
            return true
        case 35 where mods == .command:                          // ⌘P pins or unpins the row
            if prompt == nil, let row = actionRow, let key = Pins.key(for: items[row].id) {
                perform(.togglePin(key), for: items[row])
            }
            return true
        case 18...29 where mods == .command:                     // ⌘1…⌘9
            if let d = e.charactersIgnoringModifiers.flatMap(Int.init), (1...9).contains(d) {
                runQuickAction(d - 1)
                return true
            }
            return false
        default:
            // On a highlighted pinned reply, typing starts the reply rather than a search.
            if prompt == nil, field.stringValue.isEmpty, mods.isDisjoint(with: [.command, .control]),
               table.selectedRow >= 0, table.selectedRow < items.count, items[table.selectedRow].pinned,
               case .prompt(let p) = items[table.selectedRow].action,
               let chars = e.characters, !chars.isEmpty,
               chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value) }) {
                enter(p)
            }
            return false  // the keystroke still lands in the field
        }
    }

    private func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        userMoved = true
        actionFocus = nil
        let current = table.selectedRow
        let row = current < 0 ? (delta > 0 ? 0 : items.count - 1) : (current + delta + items.count) % items.count
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    private func setQuery(_ text: String) {
        userMoved = false
        field.stringValue = text
        field.currentEditor()?.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        runQuery()
    }

    /// In a scope the field holds only the search text; the engine sees "<keyword> <text>".
    private func runQuery() {
        engine.query(mode.map { $0 + " " + field.stringValue } ?? field.stringValue)
    }

    /// Left of the field: a picture for the scope or person when there is one, otherwise a name pill.
    private func updatePill() {
        scopeIcon.isHidden = true
        modeLabel.isHidden = true
        modeLabel.image = nil
        if let p = prompt {
            field.placeholderString = p.placeholder
            if case .contact(let id) = p.icon, ContactPhotos.shared.has(id) {
                scopeIcon.show(p.icon)
                scopeIcon.isHidden = false
            } else {
                modeLabel.text = p.title
                modeLabel.color = .systemBlue
                modeLabel.isHidden = false
            }
        } else if let kw = mode, let provider = engine.provider(keyword: kw) {
            field.placeholderString = "Search \(provider.name)…"
            scopeIcon.show(provider.icon)
            scopeIcon.isHidden = false
        } else {
            field.placeholderString = "Search…"
        }
    }

    private func enterMode(_ keyword: String) {
        guard engine.provider(keyword: keyword) != nil else { return }
        mode = keyword
        updatePill()
        setQuery("")
    }

    private func exitMode() {
        mode = nil
        updatePill()
        setQuery("")
    }

    /// → and ← walk the highlighted row's actions, but only when the caret is at the end of the text
    /// (so mid-word arrows still move the caret). Returns false to let the key through.
    private func stepAction(_ delta: Int) -> Bool {
        guard prompt == nil, table.selectedRow >= 0, table.selectedRow < items.count else { return false }
        let count = items[table.selectedRow].actions.count >= 2 ? min(items[table.selectedRow].actions.count, 9) : 0
        guard count > 0 else { return false }
        if delta > 0 {
            let length = (field.stringValue as NSString).length
            guard let r = field.currentEditor()?.selectedRange, r.length == 0, r.location == length else { return false }
            actionFocus = min((actionFocus ?? -1) + 1, count - 1)
        } else {
            guard let f = actionFocus else { return false }
            actionFocus = f > 0 ? f - 1 : nil
        }
        userMoved = true
        refreshHighlights()
        return true
    }

    /// Tab walks the highlighted row's actions (⌘1, ⌘2, …) and then moves to the next row; ↩ runs whatever
    /// is focused. Rows that lead somewhere (a scope like "Messages") are entered instead.
    private func tab(backward: Bool) {
        guard prompt == nil, !items.isEmpty else { return }
        if !backward, mode == nil, !userMoved, actionFocus == nil,
           let p = engine.modeProvider(for: field.stringValue), let kw = p.keyword {
            enterMode(kw)  // a typed short code: "m" → Messages
            return
        }
        guard table.selectedRow >= 0, table.selectedRow < items.count else {
            move(backward ? -1 : 1)  // nothing highlighted yet (pinned replies): pick a row first
            return
        }
        let item = items[table.selectedRow]
        if !backward, actionFocus == nil {
            switch item.action {
            case .mode(let kw): enterMode(kw); return
            case .complete(let text): setQuery(text); return
            default: break
            }
        }
        let count = item.actions.count >= 2 ? min(item.actions.count, 9) : 0
        if !backward {
            if let f = actionFocus, f + 1 < count {
                actionFocus = f + 1
            } else if actionFocus == nil, count > 0 {
                actionFocus = 0
            } else {
                move(1)
                return
            }
        } else {
            if let f = actionFocus {
                actionFocus = f > 0 ? f - 1 : nil
            } else {
                move(-1)
                let prev = table.selectedRow >= 0 ? items[table.selectedRow] : nil
                let n = (prev?.actions.count ?? 0) >= 2 ? min(prev!.actions.count, 9) : 0
                actionFocus = n > 0 ? n - 1 : nil
            }
        }
        userMoved = true
        refreshHighlights()
    }

    private func escape() {
        if prompt != nil {
            prompt = nil
            stopLive()
            promptToken += 1
            transcript.isHidden = true
            mode = savedMode
            updatePill()
            setQuery(savedQuery)
        } else if mode != nil {
            exitMode()
        } else {
            hide()
        }
    }

    @objc private func clicked() {
        if table.clickedRow >= 0 {
            table.selectRowIndexes([table.clickedRow], byExtendingSelection: false)
            activate(alt: false)
        }
    }

    private func activate(alt: Bool) {
        if let p = prompt {
            let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            if p.live {
                sendLive(text, with: p)
                return
            }
            hide()
            DispatchQueue.main.async {
                self.engine.invalidate()
                if let error = p.submit(text) { self.showError(error, draft: text, prompt: p) }
            }
            return
        }
        guard let row = actionRow else { return }
        let item = items[row]
        if !alt, let f = actionFocus, f < item.actions.count {
            perform(item.actions[f].action, for: item)
            return
        }
        perform(alt ? (item.altAction ?? item.action) : item.action, for: item)
    }

    /// The row ↩ and ⌘-numbers act on. With nothing highlighted, that's the top pinned reply.
    private var actionRow: Int? {
        let row = table.selectedRow < 0 && items.first?.pinned == true ? 0 : table.selectedRow
        return row >= 0 && row < items.count ? row : nil
    }

    private func runQuickAction(_ index: Int) {
        guard prompt == nil, let row = actionRow else { return }
        let item = items[row]
        if index < item.actions.count {
            perform(item.actions[index].action, for: item)
        } else if index == 0 {
            perform(item.action, for: item)
        }
    }

    private func perform(_ action: Action, for item: Item) {
        switch action {
        case .none:
            break
        case .open(let url):
            Usage.shared.record(item.id)
            hide()
            NSWorkspace.shared.open(url)
        case .copy(let text):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            hide()
        case .run(let body):
            Usage.shared.record(item.id)
            hide()
            body()
        case .complete(let text):
            setQuery(text)
        case .prompt(let p):
            enter(p)
        case .mode(let kw):
            enterMode(kw)
        case .update(let body):
            body()
            reselectID = nil
            signature = ""
            runQuery()
        case .togglePin(let key):
            Pins.shared.toggle(key)
            reselectID = key
            signature = ""
            runQuery()
        }
    }

    private func enter(_ p: Prompt) {
        savedQuery = field.stringValue
        savedMode = mode
        prompt = p
        updatePill()
        field.stringValue = ""
        transcript.set([])
        transcript.isHidden = true
        setItems([])

        promptToken += 1
        echoes = []
        history = []
        shownTranscript = []
        stopLive()
        loadHistory()
        if p.live {
            let token = promptToken
            liveTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                guard let self, token == self.promptToken, self.prompt != nil, self.isVisible else { return }
                self.loadHistory()
            }
        }
    }

    private func stopLive() {
        liveTimer?.invalidate()
        liveTimer = nil
    }

    /// Fetches the conversation off the main thread and redraws it if anything changed.
    private func loadHistory() {
        guard let context = prompt?.context else { return }
        let token = promptToken
        DispatchQueue.global(qos: .userInitiated).async {
            let messages = context()
            DispatchQueue.main.async {
                guard token == self.promptToken, self.prompt != nil else { return }
                self.history = messages
                self.renderTranscript()
            }
        }
    }

    /// History plus anything just sent that the database hasn't caught up with yet.
    private func renderTranscript() {
        let (shown, remaining) = mergePendingSends(history: history, pending: echoes)
        echoes = remaining
        guard shown != shownTranscript, items.isEmpty else { return }
        shownTranscript = shown
        transcript.set(shown)
        transcript.isHidden = shown.isEmpty
        resize()
    }

    /// Sends without closing: the message shows straight away as "Sending…", then its real status.
    private func sendLive(_ text: String, with p: Prompt) {
        field.stringValue = ""
        echoes.append(PendingSend(text: text, sentAt: Date()))
        renderTranscript()
        let token = promptToken
        // Let the bubble draw before Messages is asked to send (that call can take a moment).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            self.engine.invalidate()
            let error = p.submit(text)
            if let error { Log.write("send failed: \(error)") }
            guard token == self.promptToken else { return }
            if let error, let i = self.echoes.lastIndex(where: { $0.text == text && $0.error == nil }) {
                self.echoes[i].error = error
            }
            self.renderTranscript()
            self.loadHistory()
        }
    }

    /// A failed send reopens the launcher with the draft intact.
    private func showError(_ message: String, draft: String, prompt p: Prompt) {
        show()
        enter(p)
        promptToken += 1  // keep the error visible instead of the history
        field.stringValue = draft
        setItems([Item(id: "error", title: "Couldn’t send", subtitle: message, icon: .symbol("exclamationmark.triangle.fill"))])
    }
}
