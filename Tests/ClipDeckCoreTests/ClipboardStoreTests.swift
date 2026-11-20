import Foundation
import XCTest
@testable import ClipDeckCore

final class ClipboardStoreTests: XCTestCase {
    private func payload(_ text: String) -> ClipboardPayload {
        ClipboardPayload(items: [
            .init(representations: [.init(type: "public.utf8-plain-text", data: Data(text.utf8))])
        ])
    }

    func testNewStoreHasTenEmptySlotsAndNoBytes() {
        let store = ClipboardStore()
        XCTAssertEqual(store.slotCount, 10)
        XCTAssertEqual(store.occupiedSlots, [])
        XCTAssertEqual(store.totalBytes, 0)
        for index in 0..<InteractionState.slotCount { XCTAssertNil(store[index]) }
    }

    func testThirtySlotStoreRetainsCapacityAfterClearingAll() throws {
        let store = ClipboardStore(slotCount: 30)
        try store.save(payload("first"), at: 0)
        try store.save(payload("last"), at: 29)
        XCTAssertEqual(store.slotCount, 30)
        XCTAssertEqual(store[29], payload("last"))
        XCTAssertEqual(store.occupiedSlots, [0, 29])

        store.clearAll()
        XCTAssertEqual(store.slotCount, 30)
        XCTAssertEqual(store.totalBytes, 0)
        XCTAssertEqual(store.occupiedSlots, [])
        XCTAssertNil(store[29])
        try store.save(payload("again"), at: 29)
        XCTAssertEqual(store[29], payload("again"))
        XCTAssertEqual(store.totalBytes, 5)
        XCTAssertThrowsError(try store.save(payload("outside"), at: 30)) { error in
            XCTAssertEqual(error as? ClipboardError, .invalidSlot)
        }
    }

    func testStoreSlotCountClampsAndLimitsPhysicalStorage() throws {
        for (requested, expected) in [(Int.min, 1), (0, 1), (3, 3), (Int.max, 30)] {
            let store = ClipboardStore(slotCount: requested)
            XCTAssertEqual(store.slotCount, expected)
            try store.save(payload("last"), at: expected - 1)
            XCTAssertEqual(store.occupiedSlots, [expected - 1])
            XCTAssertThrowsError(try store.save(payload("outside"), at: expected)) { error in
                XCTAssertEqual(error as? ClipboardError, .invalidSlot)
            }
        }
    }

    func testSlotsRemainIndependentWhenOneIsReplaced() throws {
        let store = ClipboardStore()
        let first = payload("first")
        let second = payload("second")
        try store.save(first, at: 0)
        try store.save(second, at: 9)
        try store.save(payload("changed"), at: 0)
        XCTAssertEqual(store[0], payload("changed"))
        XCTAssertEqual(store[9], second)
        XCTAssertEqual(store.occupiedSlots, [0, 9])
        XCTAssertEqual(store.totalBytes, 7 + 6)
    }

    func testMultipleItemsAndRepresentationsPreserveOrderAndBytes() throws {
        let snapshot = ClipboardPayload(items: [
            .init(representations: [
                .init(type: "public.utf8-plain-text", data: Data("hello".utf8)),
                .init(type: "public.rtf", data: Data([1, 2, 3]))
            ]),
            .init(representations: [
                .init(type: "public.png", data: Data([4, 5, 6, 7]))
            ])
        ])
        let store = ClipboardStore()
        try store.save(snapshot, at: 4)
        XCTAssertEqual(snapshot.byteCount, 12)
        XCTAssertEqual(store[4], snapshot)
        XCTAssertEqual(store.totalBytes, 12)
    }

    func testReplacementSubtractsOldBytesBeforeApplyingTotalLimit() throws {
        let store = ClipboardStore(maxPayloadBytes: 10, maxTotalBytes: 10)
        try store.save(payload("123456"), at: 0)
        try store.save(payload("abcd"), at: 1)
        // A naive old-total-plus-new calculation would incorrectly reject this.
        try store.save(payload("abcdef"), at: 0)
        XCTAssertEqual(store.totalBytes, 10)
        XCTAssertEqual(store[0], payload("abcdef"))
        try store.save(payload("x"), at: 0)
        XCTAssertEqual(store.totalBytes, 5)
    }

    func testOversizePayloadDoesNotDamageExistingSlot() throws {
        let store = ClipboardStore(maxPayloadBytes: 4, maxTotalBytes: 20)
        let previous = payload("old")
        try store.save(previous, at: 2)
        XCTAssertThrowsError(try store.save(payload("large"), at: 2)) { error in
            XCTAssertEqual(error as? ClipboardError, .payloadTooLarge(maxBytes: 4))
        }
        XCTAssertEqual(store[2], previous)
        XCTAssertEqual(store.totalBytes, 3)
        XCTAssertEqual(store.occupiedSlots, [2])
    }

    func testAllRepresentationsCountTowardSinglePayloadLimit() {
        let store = ClipboardStore(maxPayloadBytes: 5, maxTotalBytes: 20)
        let snapshot = ClipboardPayload(items: [.init(representations: [
            .init(type: "public.utf8-plain-text", data: Data([1, 2, 3])),
            .init(type: "public.rtf", data: Data([4, 5, 6]))
        ])])
        XCTAssertThrowsError(try store.save(snapshot, at: 0)) { error in
            XCTAssertEqual(error as? ClipboardError, .payloadTooLarge(maxBytes: 5))
        }
        XCTAssertEqual(store.totalBytes, 0)
    }

    func testTotalBudgetFailureIsAtomicForReplacementAndNewSlot() throws {
        let store = ClipboardStore(maxPayloadBytes: 10, maxTotalBytes: 8)
        try store.save(payload("abc"), at: 0)
        try store.save(payload("12345"), at: 1)
        XCTAssertThrowsError(try store.save(payload("abcd"), at: 0)) { error in
            XCTAssertEqual(error as? ClipboardError, .storeFull(maxBytes: 8))
        }
        XCTAssertThrowsError(try store.save(payload("x"), at: 2))
        XCTAssertEqual(store[0], payload("abc"))
        XCTAssertEqual(store[1], payload("12345"))
        XCTAssertNil(store[2])
        XCTAssertEqual(store.totalBytes, 8)
    }

    func testExactLimitsAreAllowed() throws {
        let store = ClipboardStore(maxPayloadBytes: 4, maxTotalBytes: 8)
        try store.save(payload("1234"), at: 0)
        try store.save(payload("5678"), at: 1)
        XCTAssertEqual(store.totalBytes, 8)
    }

    func testClearIsIdempotentAndFreesCapacity() throws {
        let store = ClipboardStore(maxPayloadBytes: 4, maxTotalBytes: 4)
        try store.save(payload("1234"), at: 0)
        store.clear(at: 0)
        store.clear(at: 0)
        store.clear(at: -1)
        store.clear(at: 10)
        XCTAssertEqual(store.totalBytes, 0)
        XCTAssertEqual(store.occupiedSlots, [])
        try store.save(payload("abcd"), at: 9)
        XCTAssertEqual(store.totalBytes, 4)
        XCTAssertEqual(store.occupiedSlots, [9])
    }

    func testClearAllReleasesAllSlotsAndResetsAccounting() throws {
        let store = ClipboardStore()
        for index in 0..<10 { try store.save(payload("x"), at: index) }
        store.clearAll()
        XCTAssertEqual(store.totalBytes, 0)
        XCTAssertEqual(store.occupiedSlots, [])
        for index in 0..<10 { XCTAssertNil(store[index]) }
        store.clearAll()
        XCTAssertEqual(store.totalBytes, 0)
    }

    func testInvalidIndexesNeverMutateStorage() throws {
        let store = ClipboardStore()
        try store.save(payload("safe"), at: 0)
        for index in [-1, 10, Int.min, Int.max] {
            XCTAssertThrowsError(try store.save(payload("bad"), at: index)) { error in
                XCTAssertEqual(error as? ClipboardError, .invalidSlot)
            }
            XCTAssertNil(store[index])
        }
        XCTAssertEqual(store[0], payload("safe"))
        XCTAssertEqual(store.totalBytes, 4)
    }

    func testEmptyAndMalformedPayloadsAreRejectedWithoutReplacement() throws {
        let store = ClipboardStore()
        let original = payload("safe")
        try store.save(original, at: 0)
        let invalid: [ClipboardPayload] = [
            .init(items: []),
            .init(items: [.init(representations: [])]),
            .init(items: [.init(representations: [.init(type: "public.text", data: Data())])]),
            .init(items: [.init(representations: [.init(type: "", data: Data([1]))])]),
            .init(items: [.init(representations: [.init(type: " \n ", data: Data([1]))])]),
            .init(items: [.init(representations: [
                .init(type: "public.text", data: Data([1])),
                .init(type: "public.text", data: Data([2]))
            ])]),
            .init(items: [.init(representations: [
                .init(type: String(repeating: "a", count: 1_025), data: Data([1]))
            ])])
        ]
        for snapshot in invalid {
            XCTAssertThrowsError(try store.save(snapshot, at: 0))
            XCTAssertEqual(store[0], original)
            XCTAssertEqual(store.totalBytes, 4)
        }
    }

    func testEmptyRepresentationIsAllowedAlongsideUsefulBytes() throws {
        let store = ClipboardStore()
        let snapshot = ClipboardPayload(items: [.init(representations: [
            .init(type: "public.text", data: Data("text".utf8)),
            .init(type: "app.vendor.empty-marker", data: Data())
        ])])
        try store.save(snapshot, at: 0)
        XCTAssertEqual(store[0], snapshot)
        XCTAssertEqual(store.totalBytes, 4)
    }

    func testZeroBudgetRejectsEvenSmallNonemptyPayload() {
        let store = ClipboardStore(maxPayloadBytes: 0, maxTotalBytes: 0)
        XCTAssertThrowsError(try store.save(payload("x"), at: 0))
        XCTAssertEqual(store.totalBytes, 0)
        XCTAssertNil(store[0])
    }

    func testMalformedEmptyItemDoesNotSilentlyDropPartOfMultiItemCopy() {
        let store = ClipboardStore()
        let snapshot = ClipboardPayload(items: [
            .init(representations: [.init(type: "public.text", data: Data("one".utf8))]),
            .init(representations: [])
        ])
        XCTAssertThrowsError(try store.save(snapshot, at: 0))
        XCTAssertNil(store[0])
        XCTAssertEqual(store.totalBytes, 0)
    }
}
