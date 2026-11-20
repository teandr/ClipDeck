import AppKit

/// The live system pasteboard is distinct from ClipDeck's saved buffers.
enum ClipboardCell: Equatable {
    case system
    case saved(Int)
}

/// Presentation-only values. Clipboard bytes stay in the clipboard store.
struct SlotPresentation: Equatable {
    let cell: ClipboardCell
    let preview: String
    let isEmpty: Bool
    let kind: String
    /// The system pasteboard may change while keeping the same short snippet.
    let revision: Int?

    init(cell: ClipboardCell, preview: String, isEmpty: Bool, kind: String, revision: Int? = nil) {
        self.cell = cell
        self.preview = preview
        self.isEmpty = isEmpty
        self.kind = kind
        self.revision = revision
    }
}

enum OverlayMode: Equatable {
    case copy
    case paste

    fileprivate var title: String {
        switch self {
        case .copy: return "Сохранить в буфер"
        case .paste: return "Вставить из буфера"
        }
    }

    fileprivate var command: String {
        switch self {
        case .copy: return "⌘C"
        case .paste: return "⌘V"
        }
    }
}

/// The panel intentionally cannot become key or main. Clicking a slot must not
/// move the insertion point or transfer focus from the application being edited.
private final class ClipboardOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class OverlayController {
    var onSelect: ((ClipboardCell) -> Void)?
    var onClearSlot: ((Int) -> Void)?
    var onCancel: (() -> Void)?
    /// Supplies bounded preview contents on demand; the callback returns on main.
    var previewProvider: ((ClipboardCell, @escaping (ClipboardPreviewContent) -> Void) -> Void)?

    private let panel: ClipboardOverlayPanel
    private let content: OverlayContentView
    private let surface: ThemedSurfaceView
    private let hoverPreview = HoverPreviewController()
    private var targetScreen: NSScreen?
    private var currentMode: OverlayMode?
    private var displayedSlots: [SlotPresentation] = []
    private var hoveredCell: ClipboardCell?
    private var previewCell: ClipboardCell?
    private var previewPointerInside = false
    private var previewGeneration: UInt64 = 0
    private var hoverGeneration: UInt64 = 0
    private var previewWork: DispatchWorkItem?
    private var dismissWork: DispatchWorkItem?

    var isVisible: Bool { panel.isVisible }

    /// Uses AppKit screen coordinates (bottom-left origin), like panel.frame.
    func contains(screenPoint: NSPoint) -> Bool {
        panel.isVisible && (panel.frame.contains(screenPoint) || hoverPreview.contains(screenPoint: screenPoint))
    }

    init() {
        content = OverlayContentView(frame: .zero)
        surface = ThemedSurfaceView(hostedView: content, cornerRadius: 17)
        panel = ClipboardOverlayPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "ClipDeck"
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovable = false
        panel.acceptsMouseMovedEvents = true
        panel.animationBehavior = .utilityWindow
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = surface
        content.onSelect = { [weak self] cell in
            self?.clearPreview()
            self?.content.resetHoverTracking()
            self?.onSelect?(cell)
        }
        content.onCancel = { [weak self] in
            self?.clearPreview()
            self?.content.resetHoverTracking()
            self?.onCancel?()
        }
        content.onHoverChanged = { [weak self] cell, anchor in
            self?.hoverChanged(cell: cell, anchor: anchor)
        }
        hoverPreview.onClearSlot = { [weak self] index in
            guard let self, self.panel.isVisible, self.hoverPreview.isVisible,
                  self.previewCell == .saved(index) else { return }
            self.clearPreview()
            self.content.resetHoverTracking()
            self.onClearSlot?(index)
        }
        hoverPreview.onHoverChanged = { [weak self] inside in
            guard let self else { return }
            self.previewPointerInside = inside
            if inside {
                // A pointer may cross other rows on the way to the card.
                // Reaching it cancels any pending replacement preview.
                self.cancelPendingPreview()
                self.hoveredCell = nil
                self.dismissWork?.cancel()
                self.dismissWork = nil
            } else if self.hoveredCell == nil, self.previewCell != nil {
                self.schedulePreviewDismissal()
            }
        }
        applyTheme(.current)
    }

    func applyTheme(_ theme: AppearanceTheme) {
        panel.appearance = theme.preferredAppearance
        surface.applyTheme(theme)
        content.applyTheme(theme)
        hoverPreview.applyTheme(theme)
        surface.needsLayout = true
        surface.layoutSubtreeIfNeeded()
        if panel.isVisible { content.synchronizeHover(at: NSEvent.mouseLocation) }
    }

    func show(
        mode: OverlayMode,
        slots: [SlotPresentation],
        defaultSlot: Int,
        isLoading: Bool,
        screen: NSScreen
    ) {
        precondition(Thread.isMainThread)
        if !panel.isVisible || currentMode != mode || targetScreen !== screen || previewChanged(in: slots) {
            clearPreview()
            content.resetHoverTracking()
        }
        currentMode = mode
        displayedSlots = slots
        targetScreen = screen
        content.configure(mode: mode, slots: slots, defaultSlot: defaultSlot, isLoading: isLoading)
        position(on: screen)
        // orderFrontRegardless displays the panel without activating ClipDeck.
        panel.orderFrontRegardless()
        // Opening beneath an already stationary pointer must also start the
        // delay; it does not always generate a new AppKit mouse-entered event.
        content.synchronizeHover(at: NSEvent.mouseLocation)
    }

    func update(slots: [SlotPresentation], defaultSlot: Int, isLoading: Bool) {
        precondition(Thread.isMainThread)
        if previewChanged(in: slots) {
            clearPreview()
            content.resetHoverTracking()
        }
        displayedSlots = slots
        content.update(slots: slots, defaultSlot: defaultSlot, isLoading: isLoading)
        if let screen = targetScreen { position(on: screen) }
        if panel.isVisible { content.synchronizeHover(at: NSEvent.mouseLocation) }
    }

    private func previewChanged(in slots: [SlotPresentation]) -> Bool {
        [previewCell, hoveredCell].compactMap { $0 }.contains { cell in
            displayedSlots.first(where: { $0.cell == cell }) != slots.first(where: { $0.cell == cell })
        }
    }

    func showMessage(_ message: String) {
        precondition(Thread.isMainThread)
        content.showMessage(message)
    }

    func hide() {
        precondition(Thread.isMainThread)
        clearPreview()
        content.resetHoverTracking()
        content.stopLoading()
        panel.orderOut(nil)
        currentMode = nil
        displayedSlots = []
        targetScreen = nil
    }

    private func hoverChanged(cell: ClipboardCell?, anchor: NSRect?) {
        guard panel.isVisible else { return }
        guard let cell, anchor != nil else {
            cancelPendingPreview()
            hoveredCell = nil
            if hoverPreview.isVisible {
                // The card stays live briefly while crossing the header and
                // the gap above it. Entering the card cancels this dismissal.
                if !previewPointerInside { schedulePreviewDismissal() }
            } else {
                clearPreview()
            }
            return
        }

        dismissWork?.cancel()
        dismissWork = nil
        if hoveredCell == cell {
            return
        }
        if previewCell == cell, hoverPreview.isVisible {
            // Returning from the preview to its own tile needs no new delay.
            cancelPendingPreview()
            hoveredCell = cell
            return
        }

        // Keep the current card while crossing other rows to reach it. Only
        // dwelling on another tile replaces it, so lower rows stay scrollable.
        cancelPendingPreview()
        hoveredCell = cell
        let request = hoverGeneration
        let session = previewGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.panel.isVisible,
                  self.hoverGeneration == request,
                  self.previewGeneration == session,
                  self.hoveredCell == cell,
                  let target = self.content.hoverTarget(at: NSEvent.mouseLocation),
                  target.cell == cell,
                  let screen = self.targetScreen,
                  let provider = self.previewProvider else { return }
            self.previewWork = nil
            self.previewGeneration &+= 1
            let generation = self.previewGeneration
            self.previewCell = cell
            let previewAnchor = self.previewAnchor(for: target.anchor)
            self.hoverPreview.show(.loading, cell: cell, anchor: previewAnchor, screen: screen)
            provider(cell) { [weak self] preview in
                // Providers may finish after a tile change or after Escape.
                // Validate the session again on main before touching any UI.
                DispatchQueue.main.async {
                    guard let self, self.panel.isVisible,
                          self.previewGeneration == generation,
                          self.previewCell == cell,
                          self.hoverPreview.isVisible else { return }
                    self.hoverPreview.show(preview, cell: cell, anchor: previewAnchor, screen: screen)
                }
            }
        }
        previewWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func previewAnchor(for tile: NSRect) -> NSRect {
        // Preserve the tile's horizontal anchor, while placing the popup above
        // the whole overlay rather than over its compact header.
        NSRect(x: tile.minX, y: tile.minY, width: tile.width,
               height: max(tile.height, panel.frame.maxY - tile.minY))
    }

    private func schedulePreviewDismissal() {
        dismissWork?.cancel()
        let generation = previewGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.previewGeneration == generation,
                  self.hoveredCell == nil, !self.previewPointerInside else { return }
            self.clearPreview()
        }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28, execute: work)
    }

    private func clearPreview() {
        cancelPendingPreview()
        dismissWork?.cancel()
        dismissWork = nil
        previewGeneration &+= 1
        hoveredCell = nil
        previewCell = nil
        previewPointerInside = false
        hoverPreview.hide()
    }

    private func cancelPendingPreview() {
        previewWork?.cancel()
        previewWork = nil
        hoverGeneration &+= 1
    }

    private func position(on screen: NSScreen) {
        let visible = screen.visibleFrame
        let size = content.preferredSize(availableWidth: max(240, visible.width - 32))
        let bottomInset: CGFloat = min(22, max(8, visible.height * 0.025))
        let frame = NSRect(
            x: visible.midX - size.width / 2,
            y: visible.minY + bottomInset,
            width: size.width,
            height: size.height
        )
        panel.setFrame(frame, display: true)
        surface.needsLayout = true
        surface.layoutSubtreeIfNeeded()
        content.needsLayout = true
        content.layoutSubtreeIfNeeded()
    }
}

private final class OverlayContentView: NSView {
    var onSelect: ((ClipboardCell) -> Void)?
    var onCancel: (() -> Void)?
    var onHoverChanged: ((ClipboardCell?, NSRect?) -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")
    private let closeButton = OverlayCloseButton(frame: .zero)
    private let spinner = NSProgressIndicator(frame: .zero)
    private var slotButtons: [ClipboardSlotButton] = []
    private var mode: OverlayMode = .copy
    private var theme: AppearanceTheme = .current
    private var defaultSlot = 0
    private var isLoading = false
    private var message: String?
    private var cells: [ClipboardCell] = []
    private var columnCount = 1
    private var hoveredButton: ClipboardCell?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        subtitleLabel.alignment = .right
        subtitleLabel.lineBreakMode = .byTruncatingTail
        hintLabel.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        hintLabel.alignment = .center
        hintLabel.lineBreakMode = .byTruncatingTail
        for label in [titleLabel, subtitleLabel, hintLabel] {
            label.isSelectable = false
            label.setAccessibilityElement(false)
            addSubview(label)
        }

        closeButton.target = self
        closeButton.action = #selector(cancel)
        closeButton.toolTip = "Отменить · Esc"
        closeButton.setAccessibilityLabel("Отменить выбор буфера")
        addSubview(closeButton)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        addSubview(spinner)
        applyTheme(.current)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func applyTheme(_ theme: AppearanceTheme) {
        self.theme = theme
        closeButton.applyTheme(theme)
        for button in slotButtons { button.applyTheme(theme) }
        updateLabels()
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLabels()
        needsDisplay = true
    }

    private func rebuildButtons(for slots: [SlotPresentation]) {
        // Keep the live cell first and saved cells in numeric order. Duplicate
        // presentations do not create duplicate buttons.
        let savedCells = (0..<30).filter { index in
            slots.contains { $0.cell == .saved(index) }
        }.map { ClipboardCell.saved($0) }
        let newCells: [ClipboardCell] = [.system] + savedCells
        guard newCells != cells else { return }
        resetHoverTracking()
        for button in slotButtons { button.removeFromSuperview() }
        slotButtons.removeAll()
        cells = newCells
        for cell in cells {
            let button = ClipboardSlotButton(clipboardCell: cell)
            button.applyTheme(theme)
            button.target = self
            button.action = #selector(selectSlot(_:))
            button.onHoverChanged = { [weak self, weak button] inside in
                guard let self, let button else { return }
                if inside {
                    self.notifyHover(cell: cell, anchor: button.screenFrame)
                } else if self.hoveredButton == cell {
                    self.notifyHover(cell: nil, anchor: nil)
                }
            }
            slotButtons.append(button)
            addSubview(button)
        }
        needsLayout = true
    }

    func preferredSize(availableWidth: CGFloat) -> NSSize {
        let columns = min(max(1, cells.count), availableWidth >= 506 ? 11 : 6)
        columnCount = columns
        let gap: CGFloat = 6
        let inset: CGFloat = 14
        let tileSize = min(48, (availableWidth - inset * 2 - CGFloat(columns - 1) * gap) / CGFloat(columns)).rounded(.down)
        let rows = max(1, (cells.count + columns - 1) / columns)
        let gridWidth = inset * 2 + tileSize * CGFloat(columns) + gap * CGFloat(columns - 1)
        return NSSize(
            width: max(min(260, availableWidth), gridWidth),
            height: 34 + tileSize * CGFloat(rows) + gap * CGFloat(rows - 1) + 28
        )
    }

    func configure(mode: OverlayMode, slots: [SlotPresentation], defaultSlot: Int, isLoading: Bool) {
        self.mode = mode
        update(slots: slots, defaultSlot: defaultSlot, isLoading: isLoading)
    }

    func update(slots: [SlotPresentation], defaultSlot: Int, isLoading: Bool) {
        rebuildButtons(for: slots)
        self.defaultSlot = min(max(defaultSlot, 0), max(0, cells.count - 2))
        self.isLoading = isLoading
        message = nil

        // Missing presentations are rendered as empty; duplicates are ignored.
        // Do not retain more than the small preview string in this UI layer.
        for button in slotButtons {
            let presentation = slots.first(where: { $0.cell == button.clipboardCell })
                ?? SlotPresentation(cell: button.clipboardCell, preview: "", isEmpty: true, kind: "")
            button.configure(
                presentation: presentation,
                mode: mode,
                isDefault: button.clipboardCell == .saved(self.defaultSlot),
                isLoading: isLoading
            )
        }
        if isLoading { spinner.startAnimation(nil) }
        else { spinner.stopAnimation(nil) }
        updateLabels()
    }

    func showMessage(_ message: String) {
        self.message = message
        updateLabels()
    }

    func stopLoading() {
        spinner.stopAnimation(nil)
    }

    func hoverTarget(at screenPoint: NSPoint) -> (cell: ClipboardCell, anchor: NSRect)? {
        for button in slotButtons {
            if let frame = button.screenFrame, frame.contains(screenPoint) {
                return (button.clipboardCell, frame)
            }
        }
        return nil
    }

    func synchronizeHover(at screenPoint: NSPoint) {
        let target = hoverTarget(at: screenPoint)
        for button in slotButtons { button.setPointerHovered(button.clipboardCell == target?.cell) }
        notifyHover(cell: target?.cell, anchor: target?.anchor)
    }

    func resetHoverTracking() {
        hoveredButton = nil
        for button in slotButtons { button.setPointerHovered(false) }
    }

    private func notifyHover(cell: ClipboardCell?, anchor: NSRect?) {
        guard cell != hoveredButton else { return }
        hoveredButton = cell
        onHoverChanged?(cell, anchor)
    }

    override func layout() {
        super.layout()
        let inset: CGFloat = 14
        let columns = columnCount
        let gap: CGFloat = 6
        let tileSize = min(48, (bounds.width - inset * 2 - CGFloat(columns - 1) * gap) / CGFloat(columns)).rounded(.down)
        let closeWidth: CGFloat = 22
        titleLabel.frame = NSRect(x: inset, y: 9, width: max(100, bounds.width * 0.47 - inset), height: 17)
        closeButton.frame = NSRect(x: bounds.width - inset - closeWidth, y: 4, width: closeWidth, height: closeWidth)
        let subtitleX = bounds.width * 0.51
        subtitleLabel.frame = NSRect(x: subtitleX, y: 10, width: max(0, bounds.width - inset - closeWidth - 8 - subtitleX), height: 14)
        spinner.frame = NSRect(x: titleLabel.frame.maxX + 1, y: 8, width: 14, height: 14)

        for (index, button) in slotButtons.enumerated() {
            let row = index / columns
            let column = index % columns
            let cellsInRow = min(columns, slotButtons.count - row * columns)
            let rowWidth = CGFloat(cellsInRow) * tileSize + CGFloat(max(0, cellsInRow - 1)) * gap
            button.frame = NSRect(
                x: (bounds.width - rowWidth) / 2 + CGFloat(column) * (tileSize + gap),
                y: 34 + CGFloat(row) * (tileSize + gap),
                width: tileSize,
                height: tileSize
            )
        }
        hintLabel.frame = NSRect(x: inset, y: bounds.height - 21, width: bounds.width - inset * 2, height: 14)
        updateLabels()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func updateLabels() {
        let compact = bounds.width < 400
        titleLabel.stringValue = compact ? (mode == .copy ? "Сохранить" : "Вставить") : mode.title
        titleLabel.textColor = theme.accent(isCopy: mode == .copy)
        subtitleLabel.textColor = theme == .current
            ? NSColor.white.withAlphaComponent(0.6) : theme.secondaryTextColor
        subtitleLabel.stringValue = isLoading ? "Копирование…"
            : (compact ? "По умолч.: \(defaultSlot + 1)" : "По умолчанию: \(defaultSlot + 1)")
        if let message {
            hintLabel.stringValue = message
            hintLabel.textColor = theme == .current
                ? NSColor(srgbRed: 1, green: 0.76, blue: 0.47, alpha: 1) : theme.primaryTextColor
        } else {
            let savedCount = max(0, cells.count - 1)
            let keys = savedCount >= 10 ? "1–9 / 0" : (savedCount > 1 ? "1–\(savedCount)" : "1")
            let mouseOnly = savedCount > 10
                ? (savedCount == 11 ? " · 11 — мышью" : " · 11–\(savedCount) — мышью") : ""
            hintLabel.stringValue = bounds.width >= 500
                ? "\(keys)\(mouseOnly) · \(mode.command) → \(defaultSlot + 1) · Наведение — просмотр · Esc"
                : "\(keys)\(savedCount > 10 ? " · 11+ мышью" : "") · \(mode.command) → \(defaultSlot + 1) · Esc"
            hintLabel.textColor = theme == .current
                ? NSColor.white.withAlphaComponent(0.64) : theme.secondaryTextColor
        }
    }

    @objc private func selectSlot(_ sender: ClipboardSlotButton) {
        guard sender.isEnabled else { return }
        onSelect?(sender.clipboardCell)
    }

    @objc private func cancel() { onCancel?() }
}

/// NSButton supplies the accessibility press action. Its standard bezel is
/// replaced with a translucent square, and first clicks work in a non-key panel.
private final class ClipboardSlotButton: NSButton {
    let clipboardCell: ClipboardCell
    var onHoverChanged: ((Bool) -> Void)?
    private var mode: OverlayMode = .copy
    private var theme: AppearanceTheme = .current
    private var presentation: SlotPresentation
    private var isDefault = false
    private var isHovered = false
    private var hoverTrackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    var screenFrame: NSRect? {
        guard let window else { return nil }
        return window.convertToScreen(convert(bounds, to: nil))
    }

    init(clipboardCell: ClipboardCell) {
        self.clipboardCell = clipboardCell
        presentation = SlotPresentation(cell: clipboardCell, preview: "", isEmpty: true, kind: "")
        super.init(frame: .zero)
        setButtonType(.momentaryPushIn)
        isBordered = false
        focusRingType = .none
        title = ""
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func applyTheme(_ theme: AppearanceTheme) {
        self.theme = theme
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // Semantic colors resolve again when macOS changes light/dark mode.
        needsDisplay = true
    }

    func configure(presentation: SlotPresentation, mode: OverlayMode, isDefault: Bool, isLoading: Bool) {
        self.presentation = SlotPresentation(
            cell: presentation.cell,
            preview: String(presentation.preview.prefix(60)),
            isEmpty: presentation.isEmpty,
            kind: String(presentation.kind.prefix(24)),
            revision: presentation.revision
        )
        self.mode = mode
        self.isDefault = isDefault && clipboardCell != .system
        // A copy selection may be queued while the host application is still
        // writing the pasteboard. The system cell always permits native paste,
        // even when its contents cannot be represented in a ClipDeck preview.
        isEnabled = clipboardCell == .system || mode == .copy || !presentation.isEmpty
        let state = presentation.isEmpty ? "Пусто" : (presentation.kind.isEmpty ? "Есть содержимое" : presentation.kind)
        // A native tooltip would compete with the delayed, scrollable card.
        toolTip = nil
        let detail = self.presentation.preview.isEmpty ? "" : " " + self.presentation.preview
        switch clipboardCell {
        case .system:
            let action = mode == .copy ? "Оставить в системном буфере" : "Вставить из системного буфера"
            setAccessibilityLabel("Системный буфер, \(state)")
            setAccessibilityHelp("\(action).\(detail)")
        case .saved(let index):
            let number = index + 1
            let shortcut = index == 9 ? "0" : String(number)
            let action = mode == .copy ? "Сохранить" : "Вставить"
            let selectionHelp = index < 10 ? "Клавиша \(shortcut)." : "Выберите мышью."
            setAccessibilityLabel("Буфер \(number)\(self.isDefault ? ", по умолчанию" : ""), \(state)")
            setAccessibilityHelp("\(action). \(selectionHelp)\(detail)")
        }
        needsDisplay = true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        guard !isHovered else { return }
        setPointerHovered(true)
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        guard isHovered else { return }
        setPointerHovered(false)
        onHoverChanged?(false)
    }

    func setPointerHovered(_ inside: Bool) {
        guard isHovered != inside else { return }
        isHovered = inside
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let area = bounds.insetBy(dx: 1, dy: 1)
        let cornerRadius = min(13, area.width * 0.19)
        let path = NSBezierPath(roundedRect: area, xRadius: cornerRadius, yRadius: cornerRadius)
        let emphasized = isHovered || (isEnabled && isHighlighted)
        let accent = theme.accent(isCopy: mode == .copy)
        let isCurrent = theme == .current
        let background: NSColor
        if emphasized {
            background = accent.withAlphaComponent(isHighlighted ? (isCurrent ? 0.33 : 0.24) : (isCurrent ? 0.22 : 0.14))
        }
        else if isDefault { background = accent.withAlphaComponent(isEnabled ? 0.10 : 0.05) }
        else if isCurrent { background = NSColor.white.withAlphaComponent(isEnabled ? 0.075 : 0.025) }
        else { background = NSColor.controlBackgroundColor.withAlphaComponent(isEnabled ? 0.68 : 0.38) }
        background.setFill()
        path.fill()
        let border: NSColor
        if isDefault { border = accent.withAlphaComponent(isEnabled ? 0.72 : 0.30) }
        else if isCurrent { border = NSColor.white.withAlphaComponent(emphasized ? 0.28 : 0.12) }
        else { border = emphasized ? accent.withAlphaComponent(0.52) : NSColor.separatorColor }
        border.setStroke()
        path.lineWidth = isDefault ? 1.5 : 1
        path.stroke()

        let opacity: CGFloat = isEnabled ? 1 : (isCurrent ? 0.38 : 0.55)
        let compactSystem = clipboardCell == .system && bounds.height >= 36 && bounds.height < 48
        let numberSize: CGFloat = compactSystem ? 14 : max(17, min(22, bounds.width * 0.37))
        let numberFont = NSFont.monospacedDigitSystemFont(ofSize: numberSize, weight: .medium)
        let showsDetail = bounds.height >= 48 || compactSystem
        let numberY: CGFloat = compactSystem ? 2 : (showsDetail ? 5 : (bounds.height - numberFont.pointSize - 6) / 2)
        let symbol: String
        switch clipboardCell {
        case .system: symbol = "⌘"
        case .saved(let index): symbol = String(index + 1)
        }
        drawCentered(
            symbol,
            in: NSRect(x: 4, y: numberY, width: bounds.width - 8, height: numberFont.pointSize + 6),
            font: numberFont,
            color: (isDefault ? accent : theme.primaryTextColor).withAlphaComponent(opacity)
        )

        if showsDetail {
            let line = clipboardCell == .system ? "Система"
                : (presentation.isEmpty ? "Пусто" : (presentation.preview.isEmpty ? presentation.kind : presentation.preview))
            let textInset: CGFloat = clipboardCell == .system ? 3 : 5
            drawCentered(
                line.isEmpty ? "Содержимое" : line.replacingOccurrences(of: "\n", with: " "),
                in: NSRect(x: textInset, y: bounds.height - (compactSystem ? 13 : 18),
                           width: bounds.width - textInset * 2, height: compactSystem ? 10 : 12),
                font: NSFont.systemFont(ofSize: compactSystem ? 7.5 : 9, weight: .medium),
                color: isCurrent ? NSColor.white.withAlphaComponent(opacity * 0.58) : theme.secondaryTextColor
            )
        }

        if isDefault {
            accent.withAlphaComponent(opacity * 0.9).setFill()
            NSBezierPath(ovalIn: NSRect(x: bounds.width - 12, y: 8, width: 4, height: 4)).fill()
        }
        if clipboardCell == .saved(9) && bounds.width >= 48 {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .medium),
                .foregroundColor: isCurrent ? NSColor.white.withAlphaComponent(opacity * 0.35) : theme.secondaryTextColor
            ]
            ("0" as NSString).draw(at: NSPoint(x: 8, y: 7), withAttributes: attributes)
        }
    }

    private func drawCentered(_ text: String, in rect: NSRect, font: NSFont, color: NSColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(in: rect, withAttributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
    }
}

private final class OverlayCloseButton: NSButton {
    override var acceptsFirstResponder: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        focusRingType = .none
        title = ""
        image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Отменить")
        imagePosition = .imageOnly
        applyTheme(.current)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func applyTheme(_ theme: AppearanceTheme) {
        contentTintColor = theme == .current
            ? NSColor.white.withAlphaComponent(0.6) : theme.secondaryTextColor
        needsDisplay = true
    }
}
