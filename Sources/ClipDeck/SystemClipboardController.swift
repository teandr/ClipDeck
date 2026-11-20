import AppKit
import ClipDeckCore
import Foundation

struct SystemClipboardPresentation: Equatable {
    let preview: String
    let kind: String
    let isEmpty: Bool
    let revision: Int?
}

/// A temporary view of the live clipboard, independent of the saved slots.
/// Only changeCount is inspected on main; providers and bytes are read by the
/// service. Monitoring and the materialized snapshot exist only while visible.
@MainActor
final class SystemClipboardController {
    var onChange: (() -> Void)?
    private(set) var presentation = SystemClipboardPresentation(
        preview: "Системный буфер", kind: "Система", isEmpty: false, revision: nil
    )

    private enum PreviewState {
        case loading
        case empty
        case payload(ClipboardPayload)
        case unavailable(String)
    }

    private let clipboard: ClipboardService
    private let previews: ClipboardPreviewProvider
    private var timer: Timer?
    private var isActive = false
    private var session = UUID()
    private var revisionToken = UUID()
    private var pendingReadID: UUID?
    private var readDeadline: DispatchWorkItem?
    private var state: PreviewState = .loading

    init(clipboard: ClipboardService, previews: ClipboardPreviewProvider) {
        self.clipboard = clipboard
        self.previews = previews
    }

    /// The coordinator also calls start during ordinary overlay renders. An
    /// already observed generation produces neither another read nor a render.
    func start() {
        if isActive {
            refresh()
            return
        }
        isActive = true
        session = UUID()
        let pollingTimer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
        timer = pollingTimer
        RunLoop.main.add(pollingTimer, forMode: .common)
        refresh()
    }

    func stop() {
        guard isActive else { return }
        isActive = false
        session = UUID()
        timer?.invalidate()
        timer = nil
        cancelRead()
        // Drop cached clipboard bytes as soon as the overlay disappears.
        // No saved slot receives this content.
        state = .loading
        presentation = SystemClipboardPresentation(
            preview: "Системный буфер", kind: "Система", isEmpty: false, revision: nil
        )
    }

    func preview(completion: @escaping (ClipboardPreviewContent) -> Void) {
        guard isActive else { return }
        refresh()
        switch state {
        case .loading:
            completion(.loading)
        case .empty:
            completion(.empty)
        case .unavailable(let explanation):
            completion(.unsupported(explanation))
        case .payload(let payload):
            let requestedSession = session
            let requestedToken = revisionToken
            guard let requestedRevision = presentation.revision else { return }
            previews.preview(payload) { [weak self] content in
                // Explicitly enter main actor even if a future preview provider
                // changes its callback queue.
                DispatchQueue.main.async {
                    guard let self, self.isActive, self.session == requestedSession,
                          self.revisionToken == requestedToken,
                          self.presentation.revision == requestedRevision else { return }
                    guard NSPasteboard.general.changeCount == requestedRevision else {
                        self.refresh()
                        return
                    }
                    completion(content)
                }
            }
        }
    }

    private func refresh(force: Bool = false) {
        guard isActive else { return }
        let revision = NSPasteboard.general.changeCount
        guard force || presentation.revision != revision else { return }
        cancelRead()
        revisionToken = UUID()
        state = .loading
        let requestID = UUID()
        let requestedSession = session
        pendingReadID = requestID
        setPresentation(preview: "Чтение…", kind: "Система", isEmpty: false,
                        revision: revision)
        guard isActive, session == requestedSession, pendingReadID == requestID else { return }
        // A provider call may block its worker beyond the service's own 2 s
        // deadline. This UI deadline does not wait for that worker to return.
        let deadline = DispatchWorkItem { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.isActive, self.session == requestedSession,
                      self.pendingReadID == requestID,
                      self.presentation.revision == revision else { return }
                guard NSPasteboard.general.changeCount == revision else {
                    self.refresh()
                    return
                }
                self.cancelRead()
                self.showUnavailable(.captureTimedOut, revision: revision)
            }
        }
        readDeadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: deadline)
        clipboard.readCurrent(id: requestID, expectedGeneration: revision) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.isActive, self.session == requestedSession,
                      self.pendingReadID == requestID,
                      self.presentation.revision == revision else { return }
                guard NSPasteboard.general.changeCount == revision else {
                    self.refresh()
                    return
                }
                self.pendingReadID = nil
                self.readDeadline?.cancel()
                self.readDeadline = nil
                switch result {
                case .snapshot(let payload, let preview, let kind):
                    self.state = .payload(payload)
                    self.setPresentation(preview: preview, kind: kind, isEmpty: false,
                                         revision: revision)
                case .empty:
                    self.state = .empty
                    self.setPresentation(preview: "Пусто", kind: "Система", isEmpty: true,
                                         revision: revision)
                case .unavailable(let error):
                    self.showUnavailable(error, revision: revision)
                case .changed:
                    self.refresh(force: true)
                }
            }
        }
    }

    private func cancelRead() {
        if let requestID = pendingReadID { clipboard.cancelCurrent(id: requestID) }
        pendingReadID = nil
        readDeadline?.cancel()
        readDeadline = nil
    }

    private func showUnavailable(_ error: ClipboardError, revision: Int) {
        let title: String
        let explanation: String
        switch error {
        case .sensitiveContent:
            title = "Защищено"
            explanation = "Источник пометил содержимое как защищённое. Предпросмотр скрыт."
        case .payloadTooLarge:
            title = "Большой объём"
            explanation = "Содержимое превышает лимит предпросмотра."
        case .unsupportedContent:
            title = "Без предпросмотра"
            explanation = "Источник предоставляет файлы по запросу. Их содержимое не загружается для предпросмотра."
        case .captureTimedOut:
            title = "Недоступно"
            explanation = "Источник не предоставил содержимое для предпросмотра вовремя."
        default:
            title = "Без предпросмотра"
            explanation = "Не удалось прочитать содержимое для предпросмотра."
        }
        state = .unavailable(explanation + " Обычная вставка из системного буфера остаётся доступной.")
        setPresentation(preview: title, kind: "Система", isEmpty: false, revision: revision)
    }

    private func setPresentation(preview: String, kind: String, isEmpty: Bool, revision: Int) {
        let updated = SystemClipboardPresentation(preview: preview, kind: kind,
                                                  isEmpty: isEmpty, revision: revision)
        guard updated != presentation else { return }
        presentation = updated
        onChange?()
    }
}
