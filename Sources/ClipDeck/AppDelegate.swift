import AppKit
import ApplicationServices
import CoreGraphics
import ClipDeckCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let keyboard = KeyboardInterceptor()
    private let clipboard = ClipboardService()
    private let clipboardPreview = ClipboardPreviewProvider()
    private lazy var systemClipboard = SystemClipboardController(clipboard: clipboard, previews: clipboardPreview)
    private let overlay = OverlayController()
    private let notice = NoticeController()
    private let setup = SetupWindowController()
    private let bufferSettings = BufferSettingsController()
    private var machine = InteractionState()
    // Keep hidden slots until exit. Changing the visible count never destroys
    // a saved fragment; increasing the count reveals those slots again.
    private var store = ClipboardStore(slotCount: InteractionState.maximumSlotCount)
    private var captured: [UUID: ClipboardPayload] = [:]
    private var captureTimeouts: [UUID: DispatchWorkItem] = [:]
    private var interactionTarget: NSRunningApplication?
    private var pendingPasteID: UUID?
    private var renderScheduled = false
    private var overlayMessage: String?
    private var lastMessage = "Готово к копированию"
    private var statusItem: NSStatusItem!
    private var permissionTimer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var enabled = true
    private var bufferCount = InteractionState.slotCount
    private var defaultSlot = 0
    private var appearanceTheme: AppearanceTheme = .current

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A second instance must never install a second active event tap.
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            NSApp.terminate(nil)
            return
        }
        UserDefaults.standard.register(defaults: ["defaultSlot": 0, "enabled": true,
                                                 "bufferCount": InteractionState.slotCount,
                                                 "appearanceTheme": AppearanceTheme.current.rawValue])
        bufferCount = min(max(UserDefaults.standard.integer(forKey: "bufferCount"), 1),
                          InteractionState.maximumSlotCount)
        machine = InteractionState(slotCount: bufferCount)
        let savedDefault = UserDefaults.standard.integer(forKey: "defaultSlot")
        defaultSlot = (0..<bufferCount).contains(savedDefault) ? savedDefault : 0
        enabled = UserDefaults.standard.bool(forKey: "enabled")
        let savedTheme = AppearanceTheme(rawValue: UserDefaults.standard.string(forKey: "appearanceTheme") ?? "") ?? .current
        applyAppearanceTheme(savedTheme.effectiveTheme)
        configureCallbacks()
        createStatusItem()
        observeContextChanges()
        refreshPermissionState()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            // Timer is installed on the main run loop. Explicit dispatch keeps
            // the actor boundary clear under newer Swift/AppKit SDKs too.
            DispatchQueue.main.async { self?.refreshPermissionState() }
        }
        if enabled && !keyboard.isRunning { showSetup() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        keyboard.stop()
        permissionTimer?.invalidate()
        cancelInteraction()
        systemClipboard.stop()
        for (center, token) in observers { center.removeObserver(token) }
        observers.removeAll()
        store.clearAll()
        captured.removeAll()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func configureCallbacks() {
        // KeyboardInterceptor registers its C callback on CFRunLoopGetMain().
        // These non-Sendable closures are created on the main actor, avoiding a
        // dependency on macOS 14's MainActor.assumeIsolated runtime entry point.
        keyboard.onShortcut = { [weak self] shortcut, isRepeat in
            self?.handleShortcut(shortcut, isRepeat: isRepeat) ?? false
        }
        keyboard.onSelectSlot = { [weak self] index in self?.selectSlot(index) }
        keyboard.onCancel = { [weak self] in self?.cancelInteraction() }
        keyboard.isChoosingSlot = { [weak self] in self?.machine.isOverlayVisible ?? false }
        keyboard.onUserKeyDown = { [weak self] in self?.pendingPasteID = nil }
        keyboard.onMouseDown = { [weak self] point in
            guard let self else { return }
            // A click after choosing a slot invalidates any queued insertion.
            self.pendingPasteID = nil
            if self.machine.isOverlayVisible,
               !self.overlay.contains(screenPoint: ScreenLocator.appKitPoint(fromQuartz: point)) {
                self.cancelInteraction()
            }
        }
        keyboard.onTapDisabled = { [weak self] in
            self?.cancelInteraction()
            DispatchQueue.main.async { self?.updateStatusAppearance() }
        }
        overlay.onSelect = { [weak self] cell in
            switch cell {
            case .system: self?.selectSystemClipboard()
            case .saved(let index): self?.selectSlot(index)
            }
        }
        overlay.onCancel = { [weak self] in self?.cancelInteraction() }
        overlay.previewProvider = { [weak self] cell, completion in
            guard let self, self.machine.isOverlayVisible else {
                completion(.empty)
                return
            }
            switch cell {
            case .system:
                self.systemClipboard.preview(completion: completion)
            case .saved(let index):
                self.clipboardPreview.preview(self.store[index], completion: completion)
            }
        }
        systemClipboard.onChange = { [weak self] in
            guard let self, self.machine.isOverlayVisible else { return }
            self.scheduleRender()
        }
        setup.onRequestAccessibility = { [weak self] in self?.requestAccessibility() }
        setup.onOpenAccessibility = { [weak self] in self?.openAccessibilitySettings() }
        setup.onRequestInputMonitoring = { [weak self] in self?.requestInputMonitoring() }
        setup.onCheckAgain = { [weak self] in self?.refreshPermissionState() }
        bufferSettings.onApply = { [weak self] count, theme in
            self?.applySettings(bufferCount: count, theme: theme)
        }
    }

    /// Only the reducer, metadata reads and value-type stores run synchronously
    /// inside an event tap. UI rendering and pasteboard bytes are deferred.
    private func handleShortcut(_ shortcut: InteractionState.Shortcut, isRepeat: Bool) -> Bool {
        precondition(Thread.isMainThread)
        guard enabled, keyboard.isRunning else { return false }
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
              frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return false }
        if isRepeat { return true }

        if let target = interactionTarget, target.processIdentifier != frontmost.processIdentifier {
            cancelInteraction()
        }
        let beginsCopy = shortcut == .copy && machine.currentCopyID == nil
        let beginsPaste: Bool
        if case .pasting = machine.phase { beginsPaste = false }
        else { beginsPaste = shortcut == .paste }
        if beginsCopy || beginsPaste {
            interactionTarget = frontmost
            overlayMessage = nil
        }
        // The revision must be captured BEFORE forwarding the original Cmd-C.
        // No contents are requested here; the source app still performs Copy.
        let baseline = beginsCopy ? NSPasteboard.general.changeCount : nil
        let effects = machine.handle(
            .shortcut(shortcut, isRepeat: false),
            defaultSlot: defaultSlot,
            occupiedSlots: store.occupiedSlots
        )
        let forwardsNativeCopy = effects.contains { effect in
            if case .captureCopy = effect { return true }
            return false
        }
        apply(effects, baseline: baseline)
        return !forwardsNativeCopy
    }

    private func selectSlot(_ index: Int) {
        guard interactionStillTargetsFrontmostApp() else {
            cancelInteraction()
            return
        }
        overlayMessage = nil
        apply(machine.handle(.selectSlot(index), defaultSlot: defaultSlot, occupiedSlots: store.occupiedSlots))
    }

    private func selectSystemClipboard() {
        guard interactionStillTargetsFrontmostApp() else {
            cancelInteraction()
            return
        }
        overlayMessage = nil
        if case .copying = machine.phase {
            // Native Copy was already forwarded. Selecting System just ends
            // the picker; it does not duplicate data into a numbered slot.
            lastMessage = "Выбран системный буфер"
            scheduleStatusUpdate()
        }
        apply(machine.handle(.selectSystemClipboard, defaultSlot: defaultSlot,
                             occupiedSlots: store.occupiedSlots))
    }

    private func apply(_ effects: [InteractionState.Effect], baseline: Int? = nil) {
        // Save the target before a hide effect ends this selection. Paste
        // retains its own target until the asynchronous write completes.
        let target = interactionTarget
        for effect in effects {
            switch effect {
            case .showOverlay:
                overlayMessage = nil
                scheduleRender()
            case .hideOverlay:
                scheduleRender()
            case .captureCopy(let id):
                guard let baseline else { continue }
                beginCapture(id: id, baseline: baseline)
            case .discardCopy(let id):
                clipboard.cancel(id: id)
                captureTimeouts.removeValue(forKey: id)?.cancel()
                captured.removeValue(forKey: id)
            case .storeCopy(let id, let slot):
                guard let payload = captured[id] else {
                    apply(machine.handle(
                        .copyStoreFailed(id, message: "Копирование не завершилось. Нажмите Escape и попробуйте ещё раз."),
                        defaultSlot: defaultSlot, occupiedSlots: store.occupiedSlots
                    ))
                    continue
                }
                do {
                    try store.save(payload, at: slot)
                    lastMessage = "Сохранено в ячейку \(slot + 1)"
                    scheduleStatusUpdate()
                    apply(machine.handle(.copyStored(id), defaultSlot: defaultSlot,
                                         occupiedSlots: store.occupiedSlots))
                } catch {
                    apply(machine.handle(.copyStoreFailed(id, message: error.localizedDescription),
                                         defaultSlot: defaultSlot, occupiedSlots: store.occupiedSlots))
                }
            case .pasteSlot(let slot):
                if let target { paste(slot: slot, into: target) }
            case .pasteSystemClipboard:
                if let target { pasteSystemClipboard(into: target) }
            case .showError(let message):
                if machine.isOverlayVisible {
                    overlayMessage = message
                    scheduleRender()
                } else {
                    report(message)
                }
            }
        }
        if !machine.isOverlayVisible { interactionTarget = nil }
    }

    private func beginCapture(id: UUID, baseline: Int) {
        // A separate UI deadline also covers a slow lazy pasteboard provider;
        // cancellation never makes the event tap wait for that provider.
        let deadline = DispatchWorkItem { [weak self] in
            guard let self, self.machine.currentCopyID == id else { return }
            self.apply(self.machine.handle(
                .copyFailed(id, message: "Приложение не завершило копирование. Выделите фрагмент и попробуйте ещё раз."),
                defaultSlot: self.defaultSlot, occupiedSlots: self.store.occupiedSlots
            ))
        }
        captureTimeouts[id] = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: deadline)
        clipboard.capture(id: id, baseline: baseline,
                          sourceBundleID: interactionTarget?.bundleIdentifier) { [weak self] result in
            guard let self, self.machine.currentCopyID == id else { return }
            guard self.interactionStillTargetsFrontmostApp() else {
                self.cancelInteraction()
                return
            }
            self.captureTimeouts.removeValue(forKey: id)?.cancel()
            switch result {
            case .success(let payload):
                self.captured[id] = payload
                self.apply(self.machine.handle(.copyCaptured(id), defaultSlot: self.defaultSlot,
                                               occupiedSlots: self.store.occupiedSlots))
            case .failure(let error):
                self.apply(self.machine.handle(.copyFailed(id, message: error.localizedDescription),
                                               defaultSlot: self.defaultSlot, occupiedSlots: self.store.occupiedSlots))
            }
        }
    }

    private func paste(slot: Int, into target: NSRunningApplication) {
        guard let payload = store[slot], isFrontmost(target), keyboard.isRunning else {
            report("Вставка отменена: активное приложение изменилось.")
            return
        }
        let request = UUID()
        pendingPasteID = request
        let revision = NSPasteboard.general.changeCount
        clipboard.write(payload, expectedChangeCount: revision, shouldWrite: { [weak self] in
            guard let self else { return false }
            return self.pendingPasteID == request && self.enabled && self.keyboard.isRunning && self.isFrontmost(target)
        }) { [weak self] result in
            guard let self, self.pendingPasteID == request else { return }
            self.pendingPasteID = nil
            if case .failure(let error) = result {
                self.report(error.localizedDescription)
                return
            }
            guard self.enabled, self.keyboard.isRunning, self.isFrontmost(target) else {
                self.report("Вставка отменена: активное приложение изменилось.")
                return
            }
            guard self.sendPasteCommand(into: target) else {
                self.report("Не удалось отправить команду вставки.")
                return
            }
            // Keep the selected payload in the system clipboard. Restoring an
            // older one after a fixed delay races applications' lazy reads.
            self.lastMessage = "Команда вставки из ячейки \(slot + 1) отправлена"
            self.updateStatusAppearance()
        }
    }

    /// A system-cell paste uses the live macOS clipboard. It never rebuilds
    /// the pasteboard from the bounded snapshot used only for its preview.
    private func pasteSystemClipboard(into target: NSRunningApplication) {
        let request = UUID()
        pendingPasteID = request
        DispatchQueue.main.async { [weak self] in
            guard let self, self.pendingPasteID == request else { return }
            self.pendingPasteID = nil
            guard self.enabled, self.keyboard.isRunning, self.isFrontmost(target) else {
                self.report("Вставка отменена: активное приложение изменилось.")
                return
            }
            guard self.sendPasteCommand(into: target) else {
                self.report("Не удалось отправить команду вставки.")
                return
            }
            self.lastMessage = "Команда вставки из системного буфера отправлена"
            self.updateStatusAppearance()
        }
    }

    private func sendPasteCommand(into target: NSRunningApplication) -> Bool {
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return false }
        for event in [down, up] {
            event.flags = .maskCommand
            event.setIntegerValueField(.eventSourceUserData, value: KeyboardInterceptor.syntheticEventMarker)
            event.postToPid(target.processIdentifier)
        }
        return true
    }

    private func interactionStillTargetsFrontmostApp() -> Bool {
        guard let interactionTarget else { return false }
        return isFrontmost(interactionTarget)
    }

    private func isFrontmost(_ application: NSRunningApplication) -> Bool {
        !application.isTerminated &&
            NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier
    }

    private func cancelInteraction() {
        pendingPasteID = nil
        overlayMessage = nil
        apply(machine.handle(.cancel, defaultSlot: defaultSlot, occupiedSlots: store.occupiedSlots))
        interactionTarget = nil
    }

    private func scheduleRender() {
        guard !renderScheduled else { return }
        renderScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.renderScheduled = false
            guard self.machine.isOverlayVisible,
                  let screen = ScreenLocator.screen(for: self.interactionTarget) else {
                self.systemClipboard.stop()
                self.overlay.hide()
                return
            }
            let mode: OverlayMode
            let isLoading: Bool
            switch self.machine.phase {
            case .idle:
                self.systemClipboard.stop()
                self.overlay.hide()
                return
            case .copying(let session):
                mode = .copy
                isLoading = !session.isReady
            case .pasting:
                mode = .paste
                isLoading = false
            }
            self.systemClipboard.start()
            self.overlay.show(mode: mode, slots: self.presentations(), defaultSlot: self.defaultSlot,
                              isLoading: isLoading, screen: screen)
            if let message = self.overlayMessage { self.overlay.showMessage(message) }
        }
    }

    private func presentations() -> [SlotPresentation] {
        let system = systemClipboard.presentation
        let systemCell = SlotPresentation(cell: .system, preview: system.preview, isEmpty: system.isEmpty,
                                          kind: system.kind, revision: system.revision)
        return [systemCell] + (0..<bufferCount).map { index in
            guard let payload = store[index] else {
                return SlotPresentation(cell: .saved(index), preview: "", isEmpty: true, kind: "")
            }
            let summary = ClipboardService.describe(payload)
            return SlotPresentation(cell: .saved(index), preview: summary.preview, isEmpty: false, kind: summary.kind)
        }
    }

    private func report(_ message: String) {
        lastMessage = message
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateStatusAppearance()
            if let screen = ScreenLocator.screen(for: NSWorkspace.shared.frontmostApplication) {
                self.notice.show(message, on: screen)
            }
        }
    }

    private func observeContextChanges() {
        let workspace = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification,
            NSWorkspace.willSleepNotification,
            NSWorkspace.screensDidSleepNotification,
            NSWorkspace.sessionDidResignActiveNotification
        ]
        for name in names {
            let token = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                DispatchQueue.main.async { self?.cancelInteraction() }
            }
            observers.append((workspace, token))
        }
        let center = NotificationCenter.default
        let token = center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                       object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { self?.cancelInteraction() }
        }
        observers.append((center, token))
    }

    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        rebuildMenu()
        updateStatusAppearance()
    }

    private var visibleOccupiedCount: Int {
        store.occupiedSlots.filter { $0 < bufferCount }.count
    }

    func menuWillOpen(_ menu: NSMenu) {
        cancelInteraction()
        rebuildMenu()
    }

    private func rebuildMenu() {
        guard let menu = statusItem?.menu else { return }
        menu.removeAllItems()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let header = NSMenuItem(title: "ClipDeck \(version) · занято \(visibleOccupiedCount) из \(bufferCount)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let summary = NSMenuItem(title: lastMessage, action: nil, keyEquivalent: "")
        summary.isEnabled = false
        menu.addItem(summary)
        menu.addItem(.separator())
        addMenuItem(enabled ? "Приостановить" : "Включить", action: #selector(toggleEnabled), to: menu)
        addMenuItem("Выбрать ячейку для вставки…", action: #selector(openPastePicker), to: menu)
            .isEnabled = enabled && keyboard.isRunning
        addMenuItem("Настройки…", action: #selector(showBufferSettings), to: menu)
        let defaults = NSMenuItem(title: "Буфер по умолчанию: \(defaultSlot + 1)", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for index in 0..<bufferCount {
            let item = addMenuItem("Ячейка \(index + 1)", action: #selector(changeDefault(_:)), to: submenu)
            item.tag = index
            item.state = index == defaultSlot ? .on : .off
        }
        defaults.submenu = submenu
        menu.addItem(defaults)
        addMenuItem("Очистить сохранённые буферы", action: #selector(clearSlots), to: menu)
            .isEnabled = !store.occupiedSlots.isEmpty
        menu.addItem(.separator())
        addMenuItem("Настройка доступа и справка…", action: #selector(showSetup), to: menu)
        addMenuItem("Завершить ClipDeck", action: #selector(quit), to: menu, key: "q")
    }

    @discardableResult
    private func addMenuItem(_ title: String, action: Selector, to menu: NSMenu, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }

    private func scheduleStatusUpdate() {
        DispatchQueue.main.async { [weak self] in self?.updateStatusAppearance() }
    }

    private func updateStatusAppearance() {
        guard let button = statusItem?.button else { return }
        button.image = NSImage(systemSymbolName: "square.grid.3x3.fill", accessibilityDescription: "ClipDeck")
        button.image?.isTemplate = true
        button.imagePosition = .imageLeft
        button.title = !enabled ? " Ⅱ" : (keyboard.isRunning ? "" : " !")
        button.toolTip = "ClipDeck · \(visibleOccupiedCount)/\(bufferCount) · \(lastMessage)"
    }

    @objc private func toggleEnabled() {
        enabled.toggle()
        UserDefaults.standard.set(enabled, forKey: "enabled")
        cancelInteraction()
        if !enabled { keyboard.stop(); lastMessage = "Приостановлено — обычные ⌘C и ⌘V" }
        refreshPermissionState()
        rebuildMenu()
    }

    @objc private func changeDefault(_ sender: NSMenuItem) {
        guard (0..<bufferCount).contains(sender.tag) else { return }
        defaultSlot = sender.tag
        UserDefaults.standard.set(defaultSlot, forKey: "defaultSlot")
        lastMessage = "Буфер по умолчанию — \(defaultSlot + 1)"
        updateStatusAppearance()
    }

    private func changeBufferCount(_ count: Int) {
        let adjusted = min(max(count, 1), InteractionState.maximumSlotCount)
        guard adjusted != bufferCount else { return }
        cancelInteraction()
        bufferCount = adjusted
        machine = InteractionState(slotCount: adjusted)
        if defaultSlot >= adjusted { defaultSlot = 0 }
        UserDefaults.standard.set(adjusted, forKey: "bufferCount")
        UserDefaults.standard.set(defaultSlot, forKey: "defaultSlot")
        lastMessage = "Количество сохранённых буферов — \(adjusted)"
        updateStatusAppearance()
        rebuildMenu()
    }

    private func applySettings(bufferCount count: Int, theme: AppearanceTheme) {
        cancelInteraction()
        changeBufferCount(count)
        let resolvedTheme = theme.effectiveTheme
        applyAppearanceTheme(resolvedTheme)
        UserDefaults.standard.set(resolvedTheme.rawValue, forKey: "appearanceTheme")
        lastMessage = "Настройки сохранены · \(resolvedTheme.title)"
        updateStatusAppearance()
        rebuildMenu()
    }

    private func applyAppearanceTheme(_ theme: AppearanceTheme) {
        appearanceTheme = theme
        NSApp.appearance = theme.preferredAppearance
        overlay.applyTheme(theme)
        notice.applyTheme(theme)
        setup.applyTheme(theme)
    }

    @objc private func clearSlots() {
        cancelInteraction()
        store.clearAll()
        lastMessage = "Все ячейки очищены"
        updateStatusAppearance()
    }

    @objc private func openPastePicker() {
        // Let menu tracking finish before reading the target application.
        DispatchQueue.main.async { [weak self] in _ = self?.handleShortcut(.paste, isRepeat: false) }
    }

    @objc private func showSetup() {
        cancelInteraction()
        // NSMenu tracks in a separate run-loop mode. Wait until normal event
        // handling resumes, so dismissing the menu cannot undo window ordering.
        perform(#selector(presentSetupWindow), with: nil, afterDelay: 0, inModes: [.default])
    }

    @objc private func presentSetupWindow() {
        refreshPermissionState()
        setup.show()
    }

    @objc private func showBufferSettings() {
        cancelInteraction()
        perform(#selector(presentBufferSettingsWindow), with: nil, afterDelay: 0, inModes: [.default])
    }

    @objc private func presentBufferSettingsWindow() {
        bufferSettings.show(count: bufferCount, theme: appearanceTheme)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func refreshPermissionState() {
        let trusted = AXIsProcessTrusted()
        if enabled && trusted {
            if !keyboard.isRunning {
                if keyboard.start() { lastMessage = "Готово · ⌘C сохранить · ⌘V вставить" }
                else { lastMessage = "Нужно разрешить перехват клавиш" }
            }
        } else if keyboard.isRunning {
            keyboard.stop()
            cancelInteraction()
        }
        if enabled && !trusted { lastMessage = "Нужен доступ «Универсальный доступ»" }
        setup.update(accessibilityGranted: trusted, interceptionActive: keyboard.isRunning,
                     enabled: enabled, inputMonitoringGranted: CGPreflightListenEventAccess())
        updateStatusAppearance()
    }

    private func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openAccessibilitySettings()
    }

    private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func requestInputMonitoring() {
        // This fallback is offered only when accessibility is granted but the
        // active event tap still cannot be installed. No Screen Recording.
        guard AXIsProcessTrusted(), !keyboard.isRunning else { return }
        _ = CGRequestListenEventAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }
}
