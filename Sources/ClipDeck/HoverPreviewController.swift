import AppKit

private final class HoverPreviewPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class PreviewScrollView: NSScrollView {
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class PreviewTextView: NSTextView {
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    // A content preview must never move focus or start text editing.
    override func mouseDown(with event: NSEvent) {}
}

private final class PreviewClearButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Shows a snapshot supplied by the coordinator without activating ClipDeck.
@MainActor
final class HoverPreviewController {
    var onHoverChanged: ((Bool) -> Void)?
    var onClearSlot: ((Int) -> Void)?

    private let panel: HoverPreviewPanel
    private let contentView: HoverPreviewContentView
    private let surface: ThemedSurfaceView

    var isVisible: Bool { panel.isVisible }

    init() {
        contentView = HoverPreviewContentView(frame: .zero)
        surface = ThemedSurfaceView(hostedView: contentView, cornerRadius: 16)
        panel = HoverPreviewPanel(contentRect: .zero,
                                  styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: false)
        panel.title = "Предпросмотр буфера — ClipDeck"
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = surface
        contentView.onHoverChanged = { [weak self] isInside in
            self?.onHoverChanged?(isInside)
        }
        contentView.onClearSlot = { [weak self] index in
            guard let self, self.isVisible else { return }
            self.onClearSlot?(index)
        }
        applyTheme(.current)
    }

    func applyTheme(_ theme: AppearanceTheme) {
        panel.appearance = theme.preferredAppearance
        surface.applyTheme(theme)
        contentView.applyTheme(theme)
        surface.needsLayout = true
        surface.layoutSubtreeIfNeeded()
        if panel.isVisible { onHoverChanged?(panel.frame.contains(NSEvent.mouseLocation)) }
    }

    /// Anchor's x/width identify the cell. Its upper edge is the main panel's
    /// upper edge, so the preview clears the panel header as well as the cell.
    func show(_ content: ClipboardPreviewContent, cell: ClipboardCell, anchor: NSRect, screen: NSScreen) {
        let visible = screen.visibleFrame
        let width = min(400, max(180, visible.width - 24))
        let maxHeight = min(340, max(100, visible.height - 32))
        contentView.configure(content, cell: cell)
        let size = contentView.preferredSize(width: width, maximumHeight: maxHeight)
        let minimumX = visible.minX + 12
        let maximumX = max(minimumX, visible.maxX - size.width - 12)
        let x = min(maximumX, max(minimumX, anchor.midX - size.width / 2))
        let y = min(visible.maxY - size.height - 12,
                    max(visible.minY + 12, anchor.maxY + 8))
        panel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true)
        surface.needsLayout = true
        surface.layoutSubtreeIfNeeded()
        contentView.needsLayout = true
        contentView.layoutSubtreeIfNeeded()
        panel.orderFrontRegardless()
        // Loading and content can have different heights. Re-evaluate the
        // stationary pointer after resizing rather than waiting for mouseMoved.
        onHoverChanged?(panel.frame.contains(NSEvent.mouseLocation))
    }

    func contains(screenPoint: NSPoint) -> Bool {
        panel.isVisible && panel.frame.contains(screenPoint)
    }

    func hide() {
        panel.orderOut(nil)
        contentView.clear()
    }
}

private final class HoverPreviewContentView: NSView {
    var onHoverChanged: ((Bool) -> Void)?
    var onClearSlot: ((Int) -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let kindLabel = NSTextField(labelWithString: "")
    private let footerLabel = NSTextField(labelWithString: "")
    private let clearButton = PreviewClearButton(frame: .zero)
    private let scrollView = PreviewScrollView(frame: .zero)
    private let textView = PreviewTextView(frame: .zero)
    private let imageView = NSImageView(frame: .zero)
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private var hoverArea: NSTrackingArea?
    private var displayedText = ""
    private var imageAspectRatio: CGFloat?
    private var showingText = false
    private var showingImage = false
    private var theme: AppearanceTheme = .current
    private var chromeHeight: CGFloat { clearButton.isHidden ? 64 : 76 }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        kindLabel.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        kindLabel.alignment = .right
        footerLabel.font = NSFont.systemFont(ofSize: 10, weight: .regular)
        footerLabel.lineBreakMode = .byTruncatingTail
        messageLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        messageLabel.alignment = .center
        for label in [titleLabel, kindLabel, footerLabel, messageLabel] {
            label.isSelectable = false
            addSubview(label)
        }
        clearButton.title = "Очистить"
        clearButton.bezelStyle = .rounded
        clearButton.controlSize = .small
        clearButton.target = self
        clearButton.action = #selector(clearSlot)
        clearButton.isHidden = true
        addSubview(clearButton)

        textView.isEditable = false
        textView.isSelectable = false
        textView.isRichText = false
        textView.drawsBackground = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 0, height: 3)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = [.width]
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        addSubview(scrollView)

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.imageFrameStyle = .none
        imageView.animates = false
        addSubview(imageView)
        applyTheme(.current)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func applyTheme(_ theme: AppearanceTheme) {
        self.theme = theme
        updateColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        titleLabel.textColor = theme.primaryTextColor
        kindLabel.textColor = theme == .current
            ? NSColor.white.withAlphaComponent(0.5) : theme.secondaryTextColor
        footerLabel.textColor = theme == .current
            ? NSColor.white.withAlphaComponent(0.5) : theme.secondaryTextColor
        messageLabel.textColor = theme == .current
            ? NSColor.white.withAlphaComponent(0.72) : theme.primaryTextColor
        textView.textColor = theme == .current
            ? NSColor.white.withAlphaComponent(0.91) : theme.primaryTextColor
        textView.needsDisplay = true
        needsDisplay = true
    }

    func configure(_ content: ClipboardPreviewContent, cell: ClipboardCell) {
        switch cell {
        case .system: titleLabel.stringValue = "Системный буфер"
        case .saved(let index): titleLabel.stringValue = "Буфер \(index + 1)"
        }
        imageView.image = nil
        imageAspectRatio = nil
        displayedText = ""
        showingText = false
        showingImage = false
        footerLabel.stringValue = ""
        messageLabel.stringValue = ""
        var canClear = true
        switch content {
        case .loading:
            canClear = false
            kindLabel.stringValue = "Предпросмотр"
            messageLabel.stringValue = "Подготавливаю содержимое…"
        case .empty:
            canClear = false
            kindLabel.stringValue = "Пусто"
            messageLabel.stringValue = "В этой ячейке пока ничего нет."
        case .text(let text, let truncated):
            kindLabel.stringValue = "Текст"
            displayedText = text
            showingText = true
            footerLabel.stringValue = truncated
                ? "Показана часть текста · содержимое буфера сохранено целиком"
                : "Прокрутите, чтобы прочитать весь текст"
        case .files(let paths, let truncated):
            kindLabel.stringValue = "Файлы"
            displayedText = paths.joined(separator: "\n\n")
            showingText = true
            footerLabel.stringValue = truncated ? "Показана часть списка файлов" : "Сохранённые пути к файлам"
        case .image(let image, let detail):
            kindLabel.stringValue = "Изображение"
            imageAspectRatio = CGFloat(image.width) / CGFloat(max(1, image.height))
            imageView.image = NSImage(cgImage: image,
                                      size: NSSize(width: CGFloat(image.width), height: CGFloat(image.height)))
            imageView.setAccessibilityLabel("Изображение · \(titleLabel.stringValue)")
            showingImage = true
            footerLabel.stringValue = detail
        case .unsupported(let explanation):
            kindLabel.stringValue = "Данные"
            displayedText = explanation
            showingText = true
            footerLabel.stringValue = "Форматы сохранённого фрагмента"
        }
        clearButton.isHidden = true
        if canClear, case .saved(let index) = cell {
            clearButton.tag = index
            clearButton.setAccessibilityLabel("Очистить буфер \(index + 1)")
            clearButton.isHidden = false
        }
        scrollView.isHidden = !showingText
        imageView.isHidden = !showingImage
        messageLabel.isHidden = showingText || showingImage
        textView.string = displayedText
        textView.scroll(NSPoint.zero)
        needsLayout = true
    }

    func preferredSize(width: CGFloat, maximumHeight: CGFloat) -> NSSize {
        let innerWidth = max(100, width - 32)
        let availableBodyHeight = maximumHeight - chromeHeight
        let bodyHeight: CGFloat
        if showingText {
            let font = textView.font ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            let measured = (displayedText as NSString).boundingRect(
                with: NSSize(width: innerWidth - 14, height: 50_000),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font]
            ).height
            bodyHeight = min(availableBodyHeight, max(62, ceil(measured) + 10))
        } else if let ratio = imageAspectRatio {
            bodyHeight = min(availableBodyHeight, max(100, innerWidth / max(0.05, ratio)))
        } else {
            bodyHeight = 62
        }
        return NSSize(width: width, height: min(maximumHeight, bodyHeight + chromeHeight))
    }

    override func layout() {
        super.layout()
        let inset: CGFloat = 16
        let innerWidth = max(0, bounds.width - 2 * inset)
        titleLabel.frame = NSRect(x: inset, y: 12, width: innerWidth * 0.55, height: 17)
        kindLabel.frame = NSRect(x: inset + innerWidth * 0.55, y: 14, width: innerWidth * 0.45, height: 14)
        let body = NSRect(x: inset, y: 37, width: innerWidth, height: max(20, bounds.height - chromeHeight))
        scrollView.frame = body
        imageView.frame = body
        messageLabel.frame = NSRect(x: body.minX, y: body.midY - 20, width: body.width, height: 46)
        if clearButton.isHidden {
            footerLabel.frame = NSRect(x: inset, y: bounds.height - 19, width: innerWidth, height: 13)
        } else {
            let buttonWidth = min(innerWidth, max(80, clearButton.fittingSize.width))
            clearButton.frame = NSRect(x: bounds.width - inset - buttonWidth, y: bounds.height - 32,
                                       width: buttonWidth, height: 24)
            footerLabel.frame = NSRect(x: inset, y: clearButton.frame.midY - 6.5,
                                       width: max(0, innerWidth - buttonWidth - 8), height: 13)
        }

        if showingText {
            let width = max(60, scrollView.contentSize.width)
            textView.setFrameSize(NSSize(width: width, height: max(body.height, textView.frame.height)))
            textView.textContainer?.containerSize = NSSize(width: width,
                                                          height: CGFloat.greatestFiniteMagnitude)
            if let layoutManager = textView.layoutManager, let container = textView.textContainer {
                layoutManager.ensureLayout(for: container)
                let used = layoutManager.usedRect(for: container)
                textView.setFrameSize(NSSize(width: width, height: max(body.height, ceil(used.height) + 8)))
            }
        }
    }

    func clear() {
        clearButton.isHidden = true
        imageView.image = nil
        textView.string = ""
        displayedText = ""
        imageAspectRatio = nil
    }

    @objc private func clearSlot() {
        guard !clearButton.isHidden else { return }
        onClearSlot?(clearButton.tag)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { onHoverChanged?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChanged?(false) }
}
