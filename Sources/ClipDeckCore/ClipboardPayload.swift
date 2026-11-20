import Foundation

/// A fully materialized value snapshot. No pasteboard providers or file handles
/// are retained. Multiple items and multiple representations stay in order.
public struct ClipboardPayload: Equatable {
    public struct Representation: Equatable {
        public let type: String
        public let data: Data

        public init(type: String, data: Data) {
            self.type = type
            self.data = data
        }
    }

    public struct Item: Equatable {
        public let representations: [Representation]

        public init(representations: [Representation]) {
            self.representations = representations
        }
    }

    public let items: [Item]

    public init(items: [Item]) {
        self.items = items
    }

    /// Counts all stored representations, including alternative image formats.
    /// Saturation keeps malformed input from overflowing accounting arithmetic.
    public var byteCount: Int {
        var total = 0
        for item in items {
            for representation in item.representations {
                let (sum, overflow) = total.addingReportingOverflow(representation.data.count)
                if overflow { return Int.max }
                total = sum
            }
        }
        return total
    }

    public func validate(maxBytes: Int) throws {
        guard !items.isEmpty else { throw ClipboardError.emptyPayload }
        // Bound metadata too; tiny empty representations must not bypass the
        // byte budget with an unbounded number of entries or type-name strings.
        guard items.count <= 4_096 else { throw ClipboardError.malformedPayload }
        var total = 0
        for item in items {
            guard !item.representations.isEmpty,
                  item.representations.count <= 256 else {
                throw ClipboardError.malformedPayload
            }
            var types = Set<String>()
            var containsData = false
            for representation in item.representations {
                guard !representation.type.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      representation.type.utf8.count <= 1_024,
                      types.insert(representation.type).inserted else {
                    throw ClipboardError.malformedPayload
                }
                containsData = containsData || !representation.data.isEmpty
                let (sum, overflow) = total.addingReportingOverflow(representation.data.count)
                guard !overflow, sum <= max(0, maxBytes) else {
                    throw ClipboardError.payloadTooLarge(maxBytes: max(0, maxBytes))
                }
                total = sum
            }
            guard containsData else { throw ClipboardError.emptyPayload }
        }
    }
}

public enum ClipboardError: Error, LocalizedError, Equatable {
    case invalidSlot
    case emptyPayload
    case malformedPayload
    case payloadTooLarge(maxBytes: Int)
    case storeFull(maxBytes: Int)
    case captureTimedOut
    case sensitiveContent
    case unsupportedContent
    case writeFailed

    public var errorDescription: String? {
        switch self {
        case .invalidSlot:
            return "Эта ячейка недоступна."
        case .emptyPayload:
            return "В буфере нет данных для сохранения."
        case .malformedPayload:
            return "Формат содержимого буфера не поддерживается."
        case .payloadTooLarge(let maxBytes):
            return "Этот фрагмент превышает лимит одной ячейки — \(Self.formatted(maxBytes))."
        case .storeFull(let maxBytes):
            return "Ячейки заняли лимит памяти — \(Self.formatted(maxBytes)). Очистите ненужные ячейки."
        case .captureTimedOut:
            return "Приложение не передало новые данные. Выделите фрагмент и повторите копирование."
        case .sensitiveContent:
            return "Приложение пометило содержимое как конфиденциальное или временное. Оно не сохранено."
        case .unsupportedContent:
            return "Приложение передало только обещание файла или недоступный формат. Скопируйте готовый файл или текст."
        case .writeFailed:
            return "Не удалось восстановить выбранный фрагмент в системном буфере."
        }
    }

    private static func formatted(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(max(0, bytes)), countStyle: .memory)
    }
}

/// In-memory storage only. The application owns this object on its main thread.
/// A failed save never changes the existing slot or its accounting.
public final class ClipboardStore {
    public static let defaultMaxPayloadBytes = 64 * 1_024 * 1_024
    public static let defaultMaxTotalBytes = 256 * 1_024 * 1_024

    public let slotCount: Int
    public let maxPayloadBytes: Int
    public let maxTotalBytes: Int
    public private(set) var totalBytes = 0
    private var slots: [ClipboardPayload?]

    public init(
        slotCount: Int = InteractionState.slotCount,
        maxPayloadBytes: Int = ClipboardStore.defaultMaxPayloadBytes,
        maxTotalBytes: Int = ClipboardStore.defaultMaxTotalBytes
    ) {
        let count = min(max(slotCount, 1), InteractionState.maximumSlotCount)
        self.slotCount = count
        self.slots = Array(repeating: nil, count: count)
        self.maxPayloadBytes = max(0, maxPayloadBytes)
        self.maxTotalBytes = max(0, maxTotalBytes)
    }

    public subscript(index: Int) -> ClipboardPayload? {
        guard slots.indices.contains(index) else { return nil }
        return slots[index]
    }

    public var occupiedSlots: Set<Int> {
        Set(slots.indices.filter { slots[$0] != nil })
    }

    public func save(_ payload: ClipboardPayload, at index: Int) throws {
        guard slots.indices.contains(index) else { throw ClipboardError.invalidSlot }
        try payload.validate(maxBytes: maxPayloadBytes)
        let bytes = payload.byteCount
        let previousBytes = slots[index]?.byteCount ?? 0
        let retainedBytes = totalBytes - previousBytes
        guard bytes <= maxTotalBytes,
              retainedBytes <= maxTotalBytes - bytes else {
            throw ClipboardError.storeFull(maxBytes: maxTotalBytes)
        }
        // All checks precede mutation, including replacement accounting.
        slots[index] = payload
        totalBytes = retainedBytes + bytes
    }

    public func clear(at index: Int) {
        guard slots.indices.contains(index), let previous = slots[index] else { return }
        totalBytes -= previous.byteCount
        slots[index] = nil
    }

    public func clearAll() {
        slots = Array(repeating: nil, count: slotCount)
        totalBytes = 0
    }
}
