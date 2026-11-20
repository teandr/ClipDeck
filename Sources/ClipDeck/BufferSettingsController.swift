import AppKit

/// A regular, nonmodal settings window. Only an explicit menu action opens it;
/// the clipboard picker itself remains a nonactivating panel.
@MainActor
final class BufferSettingsController {
    var onApply: ((Int, AppearanceTheme) -> Void)?

    private let window: NSWindow
    private let content: BufferSettingsContentView
    private var didPositionWindow = false

    init() {
        let compatibilityHeight: CGFloat = AppearanceTheme.liquidGlass.isAvailable ? 0 : 36
        content = BufferSettingsContentView(frame: NSRect(x: 0, y: 0, width: 520,
                                                         height: 476 + compatibilityHeight))
        window = NSWindow(contentRect: content.frame,
                          styleMask: [.titled, .closable],
                          backing: .buffered, defer: false)
        window.title = "Настройки — ClipDeck"
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        // Inherit the application's applied appearance. Editing the draft
        // theme below never changes the window or application appearance.
        window.contentView = content
        content.onApply = { [weak self] count, theme in
            guard let self else { return }
            self.window.close()
            self.onApply?(count, theme)
        }
        content.onCancel = { [weak self] in self?.window.close() }
    }

    func show(count: Int, theme: AppearanceTheme) {
        content.configure(count: count, theme: theme)
        if !didPositionWindow {
            window.center()
            didPositionWindow = true
        }
        content.needsLayout = true
        content.layoutSubtreeIfNeeded()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        content.focusCountField()
    }
}

private final class BufferSettingsContentView: NSView, NSTextFieldDelegate {
    var onApply: ((Int, AppearanceTheme) -> Void)?
    var onCancel: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "Настройки ClipDeck")
    private let subtitleLabel = NSTextField(labelWithString: "Количество ячеек и оформление приложения.")
    private let countLabel = NSTextField(labelWithString: "Количество:")
    private let countField = NSTextField(string: "10")
    private let stepper = NSStepper(frame: .zero)
    private let rangeLabel = NSTextField(labelWithString: "от 1 до 30")
    private let errorLabel = NSTextField(labelWithString: "Введите целое число от 1 до 30.")
    private let themeLabel = NSTextField(labelWithString: "Тема:")
    private let themePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let themeDescription = NSTextField(wrappingLabelWithString: "")
    private let glassRequirement = NSTextField(wrappingLabelWithString:
        "Liquid Glass требует macOS 26 и сборку SDK 26.")
    private let themes: [AppearanceTheme] = [.current, .liquidGlass, .system, .light, .dark]
    private var draftTheme: AppearanceTheme = .current
    private let systemNote = NSTextField(wrappingLabelWithString:
        "Системная ячейка ⌘ отображается отдельно\nи не входит в выбранное количество.")
    private let hiddenNote = NSTextField(wrappingLabelWithString:
        "Если уменьшить число ячеек, содержимое скрытых буферов останется в памяти до выхода из ClipDeck. Увеличьте число снова, чтобы вернуть эти буферы.")
    private let keyboardNote = NSTextField(wrappingLabelWithString:
        "Клавиши 1–9 и 0 выбирают первые 10 буферов.\nОстальные ячейки выбираются мышью.")
    private let separator = NSBox(frame: .zero)
    private let cancelButton = NSButton(title: "Отмена", target: nil, action: nil)
    private let applyButton = NSButton(title: "Применить", target: nil, action: nil)

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        titleLabel.font = NSFont.systemFont(ofSize: 17, weight: .semibold)
        subtitleLabel.font = NSFont.systemFont(ofSize: 12)
        subtitleLabel.textColor = .secondaryLabelColor
        countLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        themeLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        rangeLabel.font = NSFont.systemFont(ofSize: 11)
        rangeLabel.textColor = .secondaryLabelColor
        errorLabel.font = NSFont.systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed
        errorLabel.isHidden = true
        for label in [themeDescription, systemNote, hiddenNote, keyboardNote] {
            label.font = NSFont.systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
        }
        glassRequirement.font = NSFont.systemFont(ofSize: 11)
        glassRequirement.textColor = .secondaryLabelColor
        glassRequirement.isHidden = AppearanceTheme.liquidGlass.isAvailable
        for label in [titleLabel, subtitleLabel, countLabel, rangeLabel, errorLabel,
                      themeLabel, themeDescription, glassRequirement,
                      systemNote, hiddenNote, keyboardNote] {
            label.isSelectable = false
            addSubview(label)
        }

        countField.font = NSFont.monospacedDigitSystemFont(ofSize: 14, weight: .medium)
        countField.alignment = .center
        countField.placeholderString = "1–30"
        countField.delegate = self
        // Ending field editing must never apply settings or close the window.
        // Return is handled by the Apply button's key equivalent; Tab, clicking
        // another control and activation changes only finish field editing.
        countField.cell?.sendsActionOnEndEditing = false
        countField.setAccessibilityLabel("Количество пользовательских буферов")
        countField.setAccessibilityHelp("Целое число от 1 до 30. Системная ячейка не считается.")
        addSubview(countField)

        stepper.minValue = 1
        stepper.maxValue = 30
        stepper.increment = 1
        stepper.valueWraps = false
        stepper.autorepeat = true
        stepper.integerValue = 10
        stepper.target = self
        stepper.action = #selector(stepCount)
        stepper.setAccessibilityLabel("Изменить количество пользовательских буферов")
        addSubview(stepper)

        themePopup.addItems(withTitles: themes.map { $0.title })
        themePopup.menu?.autoenablesItems = false
        for (index, theme) in themes.enumerated() {
            themePopup.item(at: index)?.isEnabled = theme.isAvailable
        }
        themePopup.target = self
        themePopup.action = #selector(changeDraftTheme)
        themePopup.setAccessibilityLabel("Тема оформления")
        addSubview(themePopup)

        separator.boxType = .separator
        addSubview(separator)
        for button in [cancelButton, applyButton] {
            button.bezelStyle = .rounded
            button.target = self
            addSubview(button)
        }
        cancelButton.action = #selector(cancelSettings)
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.keyEquivalentModifierMask = []
        applyButton.action = #selector(applySettings)
        applyButton.keyEquivalent = "\r"
        applyButton.keyEquivalentModifierMask = []
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(count: Int, theme: AppearanceTheme) {
        setCount(min(30, max(1, count)))
        // A preference restored on an unsupported OS/SDK follows the same
        // fallback as the application, while the unavailable option stays visible.
        draftTheme = theme.effectiveTheme
        themePopup.selectItem(at: themes.firstIndex(of: draftTheme) ?? 0)
        updateThemeDescription()
    }

    func focusCountField() {
        // selectText also makes the field the first responder. A separate
        // makeFirstResponder call can end and restart the same editing session.
        countField.selectText(nil)
    }

    func controlTextDidChange(_ notification: Notification) {
        _ = validateCount()
    }

    private func validateCount() -> Int? {
        let raw = (countField.currentEditor()?.string ?? countField.stringValue)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let count = Int(raw), (1...30).contains(count) else {
            errorLabel.isHidden = false
            applyButton.isEnabled = false
            return nil
        }
        errorLabel.isHidden = true
        applyButton.isEnabled = true
        stepper.integerValue = count
        return count
    }

    private func setCount(_ count: Int) {
        let text = String(count)
        countField.stringValue = text
        countField.currentEditor()?.string = text
        stepper.integerValue = count
        errorLabel.isHidden = true
        applyButton.isEnabled = true
    }

    @objc private func stepCount() {
        // While the field is invalid, the stepper retains the last valid value.
        setCount(stepper.integerValue)
    }

    @objc private func changeDraftTheme() {
        let selectedIndex = themePopup.indexOfSelectedItem
        guard themes.indices.contains(selectedIndex), themes[selectedIndex].isAvailable else {
            themePopup.selectItem(at: themes.firstIndex(of: draftTheme) ?? 0)
            return
        }
        draftTheme = themes[selectedIndex]
        updateThemeDescription()
    }

    private func updateThemeDescription() {
        let description: String
        switch draftTheme {
        case .current:
            description = "Знакомое оформление ClipDeck с полупрозрачной тёмной панелью."
        case .liquidGlass:
            description = "Нативный материал Liquid Glass; его вид зависит от оформления macOS."
        case .system:
            description = "Панель и окна следуют светлому или тёмному оформлению macOS."
        case .light:
            description = "Светлое оформление панели, предпросмотра и окон ClipDeck."
        case .dark:
            description = "Тёмное оформление панели, предпросмотра и окон ClipDeck."
        }
        themeDescription.stringValue = description
        themePopup.setAccessibilityHelp(description + " Изменение применяется кнопкой «Применить».")
    }

    @objc private func applySettings() {
        guard let count = validateCount() else {
            focusCountField()
            return
        }
        setCount(count)
        onApply?(count, draftTheme)
    }

    @objc private func cancelSettings() { onCancel?() }

    override func layout() {
        super.layout()
        let inset: CGFloat = 24
        let width = bounds.width - inset * 2
        titleLabel.frame = NSRect(x: inset, y: 22, width: width, height: 25)
        subtitleLabel.frame = NSRect(x: inset, y: 53, width: width, height: 20)
        countLabel.frame = NSRect(x: inset, y: 97, width: 112, height: 20)
        countField.frame = NSRect(x: 145, y: 91, width: 76, height: 28)
        stepper.frame = NSRect(x: 230, y: 91, width: 19, height: 28)
        rangeLabel.frame = NSRect(x: 260, y: 98, width: 120, height: 18)
        errorLabel.frame = NSRect(x: 145, y: 126, width: bounds.width - 145 - inset, height: 18)
        themeLabel.frame = NSRect(x: inset, y: 166, width: 112, height: 20)
        themePopup.frame = NSRect(x: 145, y: 159, width: bounds.width - 145 - inset, height: 28)
        themeDescription.frame = NSRect(x: 145, y: 194, width: bounds.width - 145 - inset, height: 40)
        glassRequirement.frame = NSRect(x: 145, y: 240, width: bounds.width - 145 - inset, height: 30)
        let compatibilityHeight: CGFloat = glassRequirement.isHidden ? 0 : 36
        systemNote.frame = NSRect(x: inset, y: 248 + compatibilityHeight, width: width, height: 36)
        hiddenNote.frame = NSRect(x: inset, y: 296 + compatibilityHeight, width: width, height: 50)
        keyboardNote.frame = NSRect(x: inset, y: 358 + compatibilityHeight, width: width, height: 34)
        separator.frame = NSRect(x: inset, y: 408 + compatibilityHeight, width: width, height: 1)
        applyButton.frame = NSRect(x: bounds.width - inset - 110, y: 424 + compatibilityHeight,
                                  width: 110, height: 32)
        cancelButton.frame = NSRect(x: applyButton.frame.minX - 106, y: 424 + compatibilityHeight,
                                   width: 98, height: 32)
    }
}
