import Foundation

/// Pure interaction logic. Pasteboard contents and macOS events stay in the app target.
///
/// An intercepted Command-C may reach the frontmost app only when `captureCopy` is
/// returned. All other intercepted copy/paste presses, including key autorepeat,
/// are consumed by the app. In particular, the first Command-V never pastes.
public struct InteractionState {
    /// Default number of saved buffers; the system clipboard is separate.
    public static let slotCount = 10
    public static let maximumSlotCount = 30

    public enum Shortcut: Equatable {
        case copy
        case paste
    }

    public enum Mode: Equatable {
        case copy
        case paste
    }

    public struct CopySession: Equatable {
        public let id: UUID
        public let isReady: Bool
        /// Most recent choice while the native application is still copying.
        public let queuedSlot: Int?
        /// The application has been asked to save, and must acknowledge it.
        public var isStoring: Bool { isReady && queuedSlot != nil }
    }

    public enum Phase: Equatable {
        case idle
        case copying(CopySession)
        case pasting
    }

    public enum Input: Equatable {
        case shortcut(Shortcut, isRepeat: Bool)
        case selectSlot(Int)
        /// Choose the live system clipboard independently of the saved slots.
        case selectSystemClipboard
        /// The app has obtained a complete, validated snapshot for this session.
        case copyCaptured(UUID)
        case copyFailed(UUID, message: String)
        case copyStored(UUID)
        case copyStoreFailed(UUID, message: String)
        case cancel
    }

    public enum Effect: Equatable {
        case showOverlay(Mode, isLoading: Bool)
        case hideOverlay
        /// Start observing the result of the original native copy operation.
        case captureCopy(UUID)
        /// Cancel capture and release any temporary data owned by this session.
        case discardCopy(UUID)
        /// Store the captured snapshot, then acknowledge success or failure.
        case storeCopy(UUID, slot: Int)
        /// The app restores this slot and posts its own marked paste keystroke.
        case pasteSlot(Int)
        /// Post a marked native paste without replacing the system clipboard.
        case pasteSystemClipboard
        case showError(String)
    }

    public private(set) var phase: Phase = .idle
    public let configuredSlotCount: Int

    public init(slotCount: Int = InteractionState.slotCount) {
        configuredSlotCount = min(max(slotCount, 1), Self.maximumSlotCount)
    }

    public var isOverlayVisible: Bool {
        if case .idle = phase { return false }
        return true
    }

    public var currentCopyID: UUID? {
        if case .copying(let session) = phase { return session.id }
        return nil
    }

    /// Apply an input. Slot indexes are zero-based within configuredSlotCount.
    ///
    /// `occupiedSlots` is supplied by the actual store for every event, so clearing
    /// a slot while the panel is open cannot paste a stale, nonexistent entry.
    /// An invalid default setting safely falls back to the first slot.
    @discardableResult
    public mutating func handle(
        _ input: Input,
        defaultSlot: Int,
        occupiedSlots: Set<Int>
    ) -> [Effect] {
        let fallbackSlot = isValidSlot(defaultSlot) ? defaultSlot : 0

        switch input {
        case .shortcut(let shortcut, let isRepeat):
            // A held key must not be mistaken for the user's second press.
            guard !isRepeat else { return [] }
            switch shortcut {
            case .copy:
                if case .copying = phase {
                    return chooseSlot(fallbackSlot, occupiedSlots: occupiedSlots)
                }

                let session = CopySession(id: UUID(), isReady: false, queuedSlot: nil)
                phase = .copying(session)
                return [.showOverlay(.copy, isLoading: true), .captureCopy(session.id)]

            case .paste:
                if case .pasting = phase {
                    return chooseSlot(fallbackSlot, occupiedSlots: occupiedSlots)
                }

                var effects: [Effect] = []
                if case .copying(let session) = phase {
                    effects.append(.discardCopy(session.id))
                }
                phase = .pasting
                effects.append(.showOverlay(.paste, isLoading: false))
                return effects
            }

        case .selectSlot(let slot):
            guard isOverlayVisible else { return [] }
            guard isValidSlot(slot) else {
                return [.showError("Выберите ячейку от 1 до \(configuredSlotCount).")]
            }
            return chooseSlot(slot, occupiedSlots: occupiedSlots)

        case .selectSystemClipboard:
            switch phase {
            case .idle:
                return []
            case .copying(let session):
                // The original native copy is already underway. Only stop
                // our capture; never save its result to a numbered slot.
                phase = .idle
                return [.discardCopy(session.id), .hideOverlay]
            case .pasting:
                phase = .idle
                return [.hideOverlay, .pasteSystemClipboard]
            }

        case .copyCaptured(let id):
            guard case .copying(let session) = phase,
                  session.id == id,
                  !session.isReady else { return [] }

            if let slot = session.queuedSlot {
                return finishCopy(id: id, slot: slot)
            }

            phase = .copying(CopySession(id: id, isReady: true, queuedSlot: nil))
            return [.showOverlay(.copy, isLoading: false)]

        case .copyFailed(let id, let message):
            guard case .copying(let session) = phase,
                  session.id == id,
                  !session.isReady else { return [] }

            phase = .idle
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            let error = trimmed.isEmpty ? "Не удалось скопировать выделение." : trimmed
            return [.discardCopy(id), .hideOverlay, .showError(error)]

        case .copyStored(let id):
            guard case .copying(let session) = phase,
                  session.id == id, session.isStoring else { return [] }
            phase = .idle
            return [.discardCopy(id), .hideOverlay]

        case .copyStoreFailed(let id, let message):
            guard case .copying(let session) = phase,
                  session.id == id, session.isStoring else { return [] }
            // Keep the captured bytes available so the user can choose a
            // different replacement slot after a total-memory-budget failure.
            phase = .copying(CopySession(id: id, isReady: true, queuedSlot: nil))
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            let error = trimmed.isEmpty ? "Не удалось сохранить фрагмент в ячейку." : trimmed
            return [.showOverlay(.copy, isLoading: false), .showError(error)]

        case .cancel:
            switch phase {
            case .idle:
                return []
            case .copying(let session):
                phase = .idle
                return [.discardCopy(session.id), .hideOverlay]
            case .pasting:
                phase = .idle
                return [.hideOverlay]
            }
        }
    }

    private func isValidSlot(_ slot: Int) -> Bool {
        (0..<configuredSlotCount).contains(slot)
    }

    private mutating func chooseSlot(_ slot: Int, occupiedSlots: Set<Int>) -> [Effect] {
        switch phase {
        case .idle:
            return []

        case .copying(let session):
            guard !session.isStoring else { return [] }
            if session.isReady {
                return finishCopy(id: session.id, slot: slot)
            }
            // The final explicit choice wins if the source app copies slowly.
            phase = .copying(CopySession(id: session.id, isReady: false, queuedSlot: slot))
            return [.showOverlay(.copy, isLoading: true)]

        case .pasting:
            guard occupiedSlots.contains(slot) else {
                return [.showError("Ячейка \(slot + 1) пуста. Сначала сохраните в неё фрагмент.")]
            }
            phase = .idle
            return [.hideOverlay, .pasteSlot(slot)]
        }
    }

    private mutating func finishCopy(id: UUID, slot: Int) -> [Effect] {
        phase = .copying(CopySession(id: id, isReady: true, queuedSlot: slot))
        return [.storeCopy(id, slot: slot)]
    }
}
