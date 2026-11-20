import AppKit

@MainActor
final class SetupWindowController {
    var onRequestAccessibility: (() -> Void)?
    var onOpenAccessibility: (() -> Void)?
    var onRequestInputMonitoring: (() -> Void)?
    var onCheckAgain: (() -> Void)?

    private let window: NSWindow
    private let content: SetupContentView
    private var didPositionWindow = false

    init() {
        content = SetupContentView(frame: NSRect(x: 0, y: 0, width: 560, height: 508))
        window = NSWindow(
            contentRect: content.frame,
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "ClipDeck — буферы обмена"
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.backgroundColor = NSColor(srgbRed: 0.085, green: 0.095, blue: 0.12, alpha: 1)
        window.contentView = content
        content.onRequestAccessibility = { [weak self] in self?.onRequestAccessibility?() }
        content.onOpenAccessibility = { [weak self] in self?.onOpenAccessibility?() }
        content.onRequestInputMonitoring = { [weak self] in self?.onRequestInputMonitoring?() }
        content.onCheckAgain = { [weak self] in self?.onCheckAgain?() }
        content.onClose = { [weak self] in self?.window.close() }
    }

    func show() {
        if !didPositionWindow {
            window.center()
            didPositionWindow = true
        }
        content.needsLayout = true
        content.layoutSubtreeIfNeeded()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func applyTheme(_ theme: AppearanceTheme) {
        window.appearance = theme.preferredAppearance
        window.backgroundColor = theme == .current
            ? NSColor(srgbRed: 0.085, green: 0.095, blue: 0.12, alpha: 1)
            : .windowBackgroundColor
        content.applyTheme(theme)
    }

    func update(
        accessibilityGranted: Bool,
        interceptionActive: Bool,
        enabled: Bool,
        inputMonitoringGranted: Bool
    ) {
        let showFallback = accessibilityGranted && !interceptionActive && enabled
        let desiredSize = NSSize(width: 560, height: showFallback ? 586 : 508)
        if window.contentView?.frame.size != desiredSize {
            // Keep the upper edge fixed so that controls do not jump to a new
            // part of the screen when permission status changes.
            let oldTop = window.frame.maxY
            window.setContentSize(desiredSize)
            window.setFrameOrigin(NSPoint(x: window.frame.minX, y: oldTop - window.frame.height))
        }
        content.update(
            accessibilityGranted: accessibilityGranted,
            interceptionActive: interceptionActive,
            enabled: enabled,
            inputMonitoringGranted: inputMonitoringGranted
        )
    }
}

private final class SetupContentView: NSView {
    var onRequestAccessibility: (() -> Void)?
    var onOpenAccessibility: (() -> Void)?
    var onRequestInputMonitoring: (() -> Void)?
    var onCheckAgain: (() -> Void)?
    var onClose: (() -> Void)?

    private let logo = SetupLogoView(frame: .zero)
    private let appTitle = NSTextField(labelWithString: "ClipDeck")
    private let subtitle = NSTextField(labelWithString: "Системный буфер и ваши сохранённые ячейки")
    private let slots = SetupSlotStrip(frame: .zero)
    private let copyKeys = SetupKeyBadge(text: "⌘C", accent: NSColor(srgbRed: 0.38, green: 0.91, blue: 0.69, alpha: 1))
    private let pasteKeys = SetupKeyBadge(text: "⌘V", accent: NSColor(srgbRed: 0.48, green: 0.72, blue: 1, alpha: 1))
    private let copyTitle = NSTextField(labelWithString: "Копирование в выбранную ячейку")
    private let copyDescription = NSTextField(wrappingLabelWithString: "Нажмите ⌘C, затем выберите квадрат или цифру.\nПовторное ⌘C сохраняет в буфер по умолчанию.")
    private let pasteTitle = NSTextField(labelWithString: "Вставка из выбранной ячейки")
    private let pasteDescription = NSTextField(wrappingLabelWithString: "Нажмите ⌘V и выберите, откуда вставить.\nПовторное ⌘V вставляет из буфера по умолчанию.")
    private let keyboardHint = NSTextField(wrappingLabelWithString: "1–9 / 0 — первые 10 ячеек · Esc — отмена · ⌘ — буфер macOS\nНаведение — просмотр. Число буферов и буфер по умолчанию — в меню.")
    private let permissionCard = SetupPermissionCard(frame: .zero)
    private let primaryButton = NSButton(title: "Разрешить доступ", target: nil, action: nil)
    private let settingsButton = NSButton(title: "Открыть настройки", target: nil, action: nil)
    private let checkButton = NSButton(title: "Проверить снова", target: nil, action: nil)
    private let privacyNote = NSTextField(wrappingLabelWithString: "Сохранённые ячейки живут в памяти до выхода из ClipDeck.\nУтилита не передаёт содержимое по сети.")
    private var accessibilityGranted = false
    private var interceptionActive = false
    private var enabled = true
    private var showsFallback = false

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        appTitle.font = NSFont.systemFont(ofSize: 28, weight: .semibold)
        appTitle.textColor = .white
        subtitle.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        subtitle.textColor = NSColor.white.withAlphaComponent(0.63)
        for label in [copyTitle, pasteTitle] {
            label.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
            label.textColor = .white
        }
        for label in [copyDescription, pasteDescription] {
            label.font = NSFont.systemFont(ofSize: 12, weight: .regular)
            label.textColor = NSColor.white.withAlphaComponent(0.73)
        }
        keyboardHint.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        keyboardHint.textColor = NSColor.white.withAlphaComponent(0.55)
        privacyNote.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        privacyNote.textColor = NSColor.white.withAlphaComponent(0.48)
        privacyNote.alignment = .center
        for label in [appTitle, subtitle, copyTitle, copyDescription, pasteTitle, pasteDescription, keyboardHint, privacyNote] {
            label.isSelectable = false
        }
        for view in [logo, appTitle, subtitle, slots, copyKeys, pasteKeys, copyTitle, copyDescription, pasteTitle, pasteDescription, keyboardHint, permissionCard, primaryButton, settingsButton, checkButton, privacyNote] {
            addSubview(view)
        }
        for button in [primaryButton, settingsButton, checkButton] {
            button.bezelStyle = .rounded
            button.controlSize = .regular
            button.font = NSFont.systemFont(ofSize: 12, weight: .medium)
            button.target = self
        }
        primaryButton.action = #selector(primaryAction)
        primaryButton.keyEquivalent = "\r"
        primaryButton.bezelColor = NSColor(srgbRed: 0.23, green: 0.48, blue: 0.82, alpha: 1)
        settingsButton.action = #selector(openSettings)
        checkButton.action = #selector(checkAgain)
        permissionCard.onRequestInputMonitoring = { [weak self] in self?.onRequestInputMonitoring?() }
        update(accessibilityGranted: false, interceptionActive: false, enabled: true, inputMonitoringGranted: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func applyTheme(_ theme: AppearanceTheme) {
        appearance = theme.preferredAppearance
        for label in [appTitle, copyTitle, pasteTitle] { label.textColor = theme.primaryTextColor }
        subtitle.textColor = theme == .current ? NSColor.white.withAlphaComponent(0.63) : theme.secondaryTextColor
        for label in [copyDescription, pasteDescription] {
            label.textColor = theme == .current ? NSColor.white.withAlphaComponent(0.73) : theme.secondaryTextColor
        }
        keyboardHint.textColor = theme == .current ? NSColor.white.withAlphaComponent(0.55) : theme.secondaryTextColor
        privacyNote.textColor = theme == .current ? NSColor.white.withAlphaComponent(0.48) : theme.secondaryTextColor
        primaryButton.bezelColor = theme == .current
            ? NSColor(srgbRed: 0.23, green: 0.48, blue: 0.82, alpha: 1) : .controlAccentColor
        permissionCard.applyTheme(theme)
        slots.applyTheme(theme)
        copyKeys.applyTheme(theme, isCopy: true)
        pasteKeys.applyTheme(theme, isCopy: false)
    }

    func update(accessibilityGranted: Bool, interceptionActive: Bool, enabled: Bool, inputMonitoringGranted: Bool) {
        self.accessibilityGranted = accessibilityGranted
        self.interceptionActive = interceptionActive
        self.enabled = enabled
        showsFallback = accessibilityGranted && !interceptionActive && enabled
        permissionCard.update(
            accessibilityGranted: accessibilityGranted,
            interceptionActive: interceptionActive,
            enabled: enabled,
            inputMonitoringGranted: inputMonitoringGranted
        )
        if !accessibilityGranted {
            primaryButton.title = "Разрешить доступ"
        } else if interceptionActive || !enabled {
            primaryButton.title = "Готово"
        } else {
            primaryButton.title = "Проверить снова"
        }
        checkButton.isHidden = accessibilityGranted && !interceptionActive && enabled
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let left: CGFloat = 32
        let width = bounds.width - left * 2
        logo.frame = NSRect(x: left, y: 24, width: 44, height: 44)
        appTitle.frame = NSRect(x: 90, y: 18, width: width - 58, height: 36)
        subtitle.frame = NSRect(x: 91, y: 57, width: width - 59, height: 18)
        slots.frame = NSRect(x: 44, y: 93, width: bounds.width - 88, height: 36)
        copyKeys.frame = NSRect(x: left, y: 150, width: 54, height: 48)
        copyTitle.frame = NSRect(x: 100, y: 148, width: bounds.width - 132, height: 18)
        copyDescription.frame = NSRect(x: 100, y: 172, width: bounds.width - 132, height: 34)
        pasteKeys.frame = NSRect(x: left, y: 214, width: 54, height: 48)
        pasteTitle.frame = NSRect(x: 100, y: 212, width: bounds.width - 132, height: 18)
        pasteDescription.frame = NSRect(x: 100, y: 236, width: bounds.width - 132, height: 34)
        keyboardHint.frame = NSRect(x: left, y: 281, width: width, height: 31)
        let cardHeight: CGFloat = showsFallback ? 158 : 80
        permissionCard.frame = NSRect(x: left, y: 325, width: width, height: cardHeight)
        let buttonsY: CGFloat = 420 + (showsFallback ? 78 : 0)
        primaryButton.frame = NSRect(x: left, y: buttonsY, width: 176, height: 32)
        settingsButton.frame = NSRect(x: left + 184, y: buttonsY, width: 168, height: 32)
        checkButton.frame = NSRect(x: left + 360, y: buttonsY, width: width - 360, height: 32)
        privacyNote.frame = NSRect(x: left, y: buttonsY + 46, width: width, height: 30)
    }

    @objc private func primaryAction() {
        if !accessibilityGranted { onRequestAccessibility?() }
        else if interceptionActive || !enabled { onClose?() }
        else { onCheckAgain?() }
    }

    @objc private func openSettings() { onOpenAccessibility?() }
    @objc private func checkAgain() { onCheckAgain?() }
}

private final class SetupPermissionCard: NSView {
    var onRequestInputMonitoring: (() -> Void)?
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let fallbackLabel = NSTextField(wrappingLabelWithString: "")
    private let fallbackButton = NSButton(title: "Открыть мониторинг ввода", target: nil, action: nil)
    private var indicatorColor = NSColor.systemOrange
    private var showsFallback = false
    private var appearanceTheme: AppearanceTheme = .current

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.045).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .white
        for label in [detailLabel, fallbackLabel] {
            label.font = NSFont.systemFont(ofSize: 11, weight: .regular)
            label.textColor = NSColor.white.withAlphaComponent(0.65)
            label.isSelectable = false
        }
        fallbackButton.bezelStyle = .rounded
        fallbackButton.controlSize = .small
        fallbackButton.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        fallbackButton.target = self
        fallbackButton.action = #selector(requestInputMonitoring)
        for view in [titleLabel, detailLabel, fallbackLabel, fallbackButton] { addSubview(view) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func applyTheme(_ theme: AppearanceTheme) {
        appearanceTheme = theme
        appearance = theme.preferredAppearance
        refreshColors()
    }

    private func refreshColors() {
        titleLabel.textColor = appearanceTheme.primaryTextColor
        for label in [detailLabel, fallbackLabel] {
            label.textColor = appearanceTheme == .current
                ? NSColor.white.withAlphaComponent(0.65) : appearanceTheme.secondaryTextColor
        }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            self.layer?.backgroundColor = (self.appearanceTheme == .current
                ? NSColor.white.withAlphaComponent(0.045) : NSColor.controlBackgroundColor).cgColor
            self.layer?.borderColor = (self.appearanceTheme == .current
                ? NSColor.white.withAlphaComponent(0.08) : NSColor.separatorColor).cgColor
        }
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshColors()
    }

    func update(accessibilityGranted: Bool, interceptionActive: Bool, enabled: Bool, inputMonitoringGranted: Bool) {
        showsFallback = accessibilityGranted && !interceptionActive && enabled
        if !accessibilityGranted {
            indicatorColor = .systemOrange
            titleLabel.stringValue = "Нужен доступ «Универсальный доступ»"
            detailLabel.stringValue = "Он позволяет перехватывать ⌘C и ⌘V и вставлять выбранную ячейку.\nВключите ClipDeck в настройках macOS, затем проверьте доступ."
        } else if !enabled {
            indicatorColor = .systemGray
            titleLabel.stringValue = "Перехват на паузе"
            detailLabel.stringValue = "Доступ разрешён. Возобновите работу через значок ClipDeck\nв строке меню, когда будете готовы."
        } else if interceptionActive {
            indicatorColor = appearanceTheme.accent(isCopy: true)
            titleLabel.stringValue = "Готово к работе"
            detailLabel.stringValue = "Откройте приложение, выделите текст и нажмите ⌘C.\nВыбор ячейки появится внизу экрана."
        } else {
            indicatorColor = .systemOrange
            titleLabel.stringValue = "Доступ разрешён; проверяем перехват"
            detailLabel.stringValue = "Если вы только что включили разрешение, нажмите\n«Проверить снова» или перезапустите ClipDeck."
        }
        fallbackLabel.stringValue = inputMonitoringGranted
            ? "Мониторинг ввода уже разрешён. Если перехват не включился,\nпроверьте переключатель ClipDeck в настройках и перезапустите его."
            : "Если перехват всё ещё не включается, разрешите для ClipDeck\n«Мониторинг ввода» в настройках macOS."
        fallbackButton.isHidden = !showsFallback
        fallbackLabel.isHidden = !showsFallback
        needsDisplay = true
        needsLayout = true
    }

    override func layout() {
        super.layout()
        titleLabel.frame = NSRect(x: 30, y: 13, width: bounds.width - 44, height: 17)
        detailLabel.frame = NSRect(x: 14, y: 37, width: bounds.width - 28, height: 31)
        fallbackLabel.frame = NSRect(x: 14, y: 81, width: bounds.width - 28, height: 31)
        fallbackButton.frame = NSRect(x: 12, y: 119, width: 214, height: 26)
    }

    override func draw(_ dirtyRect: NSRect) {
        indicatorColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: 15, y: 19, width: 6, height: 6)).fill()
        if showsFallback {
            (appearanceTheme == .current ? NSColor.white.withAlphaComponent(0.08) : NSColor.separatorColor).setFill()
            NSBezierPath(rect: NSRect(x: 14, y: 74, width: bounds.width - 28, height: 1)).fill()
        }
    }

    @objc private func requestInputMonitoring() { onRequestInputMonitoring?() }
}

private final class SetupLogoView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let rounded = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 12, yRadius: 12)
        NSGradient(starting: NSColor(srgbRed: 0.20, green: 0.46, blue: 0.70, alpha: 1), ending: NSColor(srgbRed: 0.16, green: 0.64, blue: 0.52, alpha: 1))?.draw(in: rounded, angle: -35)
        for x in 0..<2 {
            for y in 0..<2 {
                NSColor.white.withAlphaComponent(x == y ? 0.92 : 0.52).setFill()
                NSBezierPath(roundedRect: NSRect(x: CGFloat(11 + x * 12), y: CGFloat(11 + y * 12), width: 10, height: 10), xRadius: 2.5, yRadius: 2.5).fill()
            }
        }
    }
}

private final class SetupSlotStrip: NSView {
    private var appearanceTheme: AppearanceTheme = .current

    func applyTheme(_ theme: AppearanceTheme) {
        appearanceTheme = theme
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let gap: CGFloat = 6
        let side = min(bounds.height, (bounds.width - gap * 10) / 11)
        let totalWidth = side * 11 + gap * 10
        let startX = (bounds.width - totalWidth) / 2
        for index in 0..<11 {
            let rect = NSRect(x: startX + CGFloat(index) * (side + gap), y: 0, width: side, height: side)
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
            let base = appearanceTheme.primaryTextColor
            (index == 1 ? NSColor.systemTeal.withAlphaComponent(0.16) : base.withAlphaComponent(0.055)).setFill()
            path.fill()
            (index == 1 ? NSColor.systemTeal.withAlphaComponent(0.65) : base.withAlphaComponent(0.11)).setStroke()
            path.lineWidth = 1
            path.stroke()
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
                .foregroundColor: base.withAlphaComponent(0.85)
            ]
            let text = (index == 0 ? "⌘" : String(index)) as NSString
            let size = text.size(withAttributes: attributes)
            text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
        }
    }
}

private final class SetupKeyBadge: NSView {
    private let text: String
    private var accent: NSColor

    init(text: String, accent: NSColor) {
        self.text = text
        self.accent = accent
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func applyTheme(_ theme: AppearanceTheme, isCopy: Bool) {
        accent = theme.accent(isCopy: isCopy)
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        accent.withAlphaComponent(0.09).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 11, yRadius: 11).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 20, weight: .medium),
            .foregroundColor: accent
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attributes)
    }
}
