import Foundation
import XCTest
@testable import ClipDeckCore

final class InteractionStateTests: XCTestCase {
    typealias Machine = InteractionState
    typealias Effect = Machine.Effect

    private func send(
        _ input: Machine.Input,
        to machine: inout Machine,
        defaultSlot: Int = 0,
        occupied: Set<Int> = []
    ) -> [Effect] {
        machine.handle(input, defaultSlot: defaultSlot, occupiedSlots: occupied)
    }

    @discardableResult
    private func startCopy(_ machine: inout Machine) throws -> UUID {
        let effects = send(.shortcut(.copy, isRepeat: false), to: &machine)
        let id = try XCTUnwrap(machine.currentCopyID)
        XCTAssertEqual(effects, [.showOverlay(.copy, isLoading: true), .captureCopy(id)])
        return id
    }

    func testInitialStateHasNoOverlayOrCapture() {
        let machine = Machine()
        XCTAssertEqual(Machine.slotCount, 10)
        XCTAssertEqual(machine.configuredSlotCount, 10)
        XCTAssertEqual(machine.phase, .idle)
        XCTAssertFalse(machine.isOverlayVisible)
        XCTAssertNil(machine.currentCopyID)
    }

    func testThirtySlotConfigurationCanCopyAndPasteItsLastSlot() throws {
        var machine = Machine(slotCount: 30)
        let id = try startCopy(&machine)
        _ = send(.copyCaptured(id), to: &machine)
        XCTAssertEqual(send(.selectSlot(29), to: &machine), [.storeCopy(id, slot: 29)])
        _ = send(.copyStored(id), to: &machine)

        _ = send(.shortcut(.paste, isRepeat: false), to: &machine)
        XCTAssertEqual(send(.selectSlot(29), to: &machine, occupied: [29]), [.hideOverlay, .pasteSlot(29)])
        XCTAssertEqual(machine.phase, .idle)
    }

    func testReducedConfigurationRejectsHiddenSlotsEvenWhenOccupied() throws {
        var machine = Machine(slotCount: 3)
        let id = try startCopy(&machine)
        _ = send(.copyCaptured(id), to: &machine)
        let error: [Effect] = [.showError("Выберите ячейку от 1 до 3.")]

        XCTAssertEqual(send(.selectSlot(3), to: &machine, occupied: [3]), error)
        XCTAssertEqual(machine.currentCopyID, id)
        _ = send(.cancel, to: &machine)
        _ = send(.shortcut(.paste, isRepeat: false), to: &machine)
        XCTAssertEqual(send(.selectSlot(3), to: &machine, occupied: [3]), error)
        XCTAssertEqual(machine.phase, .pasting)
    }

    func testDefaultOutsideConfiguredSlotsFallsBackToFirstSlot() throws {
        var machine = Machine(slotCount: 3)
        let id = try startCopy(&machine)
        _ = send(.copyCaptured(id), to: &machine)
        XCTAssertEqual(
            send(.shortcut(.copy, isRepeat: false), to: &machine, defaultSlot: 3),
            [.storeCopy(id, slot: 0)]
        )
        _ = send(.copyStored(id), to: &machine)
        _ = send(.shortcut(.paste, isRepeat: false), to: &machine)
        XCTAssertEqual(
            send(.shortcut(.paste, isRepeat: false), to: &machine, defaultSlot: 3, occupied: [0, 3]),
            [.hideOverlay, .pasteSlot(0)]
        )
    }

    func testConfiguredSlotCountClampsToSupportedRange() {
        XCTAssertEqual(Machine.maximumSlotCount, 30)
        for requested in [Int.min, -1, 0, 1] {
            XCTAssertEqual(Machine(slotCount: requested).configuredSlotCount, 1)
        }
        XCTAssertEqual(Machine(slotCount: 17).configuredSlotCount, 17)
        for requested in [30, 31, Int.max] {
            XCTAssertEqual(Machine(slotCount: requested).configuredSlotCount, 30)
        }
    }

    func testSystemClipboardSelectionWhileIdleDoesNothing() {
        var machine = Machine()
        XCTAssertEqual(send(.selectSystemClipboard, to: &machine), [])
        XCTAssertEqual(machine.phase, .idle)
        XCTAssertFalse(machine.isOverlayVisible)
    }

    func testSystemClipboardSelectionDuringPendingCopyDiscardsCaptureWithoutSaving() throws {
        var machine = Machine()
        let id = try startCopy(&machine)

        XCTAssertEqual(send(.selectSystemClipboard, to: &machine), [.discardCopy(id), .hideOverlay])
        XCTAssertEqual(machine.phase, .idle)
        XCTAssertNil(machine.currentCopyID)
    }

    func testSystemClipboardSelectionReplacesQueuedNumberedCopyChoice() throws {
        var machine = Machine()
        let id = try startCopy(&machine)
        _ = send(.selectSlot(7), to: &machine)

        XCTAssertEqual(send(.selectSystemClipboard, to: &machine), [.discardCopy(id), .hideOverlay])
        XCTAssertEqual(send(.copyCaptured(id), to: &machine), [])
        XCTAssertEqual(machine.phase, .idle)
    }

    func testSystemClipboardSelectionDiscardsReadySnapshotWithoutSaving() throws {
        var machine = Machine()
        let id = try startCopy(&machine)
        _ = send(.copyCaptured(id), to: &machine)

        XCTAssertEqual(send(.selectSystemClipboard, to: &machine), [.discardCopy(id), .hideOverlay])
        XCTAssertEqual(machine.phase, .idle)
        XCTAssertFalse(machine.isOverlayVisible)
    }

    func testSystemClipboardSelectionPastesWithoutRequiringOccupiedNumberedSlots() {
        var machine = Machine()
        _ = send(.shortcut(.paste, isRepeat: false), to: &machine)

        XCTAssertEqual(
            send(.selectSystemClipboard, to: &machine, defaultSlot: 9, occupied: []),
            [.hideOverlay, .pasteSystemClipboard]
        )
        XCTAssertEqual(machine.phase, .idle)
        XCTAssertEqual(send(.selectSystemClipboard, to: &machine), [])
    }

    func testLateCopyCallbacksAfterSystemClipboardSelectionCannotAffectNextSession() throws {
        var machine = Machine()
        let discardedID = try startCopy(&machine)
        _ = send(.selectSystemClipboard, to: &machine)

        XCTAssertEqual(send(.copyCaptured(discardedID), to: &machine), [])
        XCTAssertEqual(send(.copyFailed(discardedID, message: "late"), to: &machine), [])
        let newID = try startCopy(&machine)
        let newPhase = machine.phase
        XCTAssertEqual(send(.copyCaptured(discardedID), to: &machine), [])
        XCTAssertEqual(send(.copyFailed(discardedID, message: "late"), to: &machine), [])
        XCTAssertEqual(machine.currentCopyID, newID)
        XCTAssertEqual(machine.phase, newPhase)
    }

    func testFirstCopyCapturesWithoutSavingToAnySlot() throws {
        var machine = Machine()
        let id = try startCopy(&machine)
        guard case .copying(let session) = machine.phase else {
            return XCTFail("A first copy must start a copy session.")
        }
        XCTAssertEqual(session.id, id)
        XCTAssertFalse(session.isReady)
        XCTAssertNil(session.queuedSlot)
        XCTAssertTrue(machine.isOverlayVisible)
    }

    func testRepeatedCopyWhilePendingWaitsForSnapshotThenSavesDefault() throws {
        var machine = Machine()
        let id = try startCopy(&machine)

        let pending = send(.shortcut(.copy, isRepeat: false), to: &machine, defaultSlot: 3)
        XCTAssertEqual(pending, [.showOverlay(.copy, isLoading: true)])
        guard case .copying(let session) = machine.phase else {
            return XCTFail("A pending capture cannot be committed prematurely.")
        }
        XCTAssertEqual(session.queuedSlot, 3)

        let completed = send(.copyCaptured(id), to: &machine)
        XCTAssertEqual(completed, [.storeCopy(id, slot: 3)])
        XCTAssertTrue(machine.isOverlayVisible)
        XCTAssertEqual(send(.copyStored(id), to: &machine), [.discardCopy(id), .hideOverlay])
        XCTAssertEqual(machine.phase, .idle)
        XCTAssertNil(machine.currentCopyID)
    }

    func testRepeatedCopyAfterCaptureSavesDefaultAndCloses() throws {
        var machine = Machine()
        let id = try startCopy(&machine)
        XCTAssertEqual(send(.copyCaptured(id), to: &machine), [.showOverlay(.copy, isLoading: false)])

        let effects = send(.shortcut(.copy, isRepeat: false), to: &machine, defaultSlot: 9)
        XCTAssertEqual(effects, [.storeCopy(id, slot: 9)])
        XCTAssertTrue(machine.isOverlayVisible)
        XCTAssertEqual(send(.copyStored(id), to: &machine), [.discardCopy(id), .hideOverlay])
        XCTAssertFalse(machine.isOverlayVisible)
    }

    func testSelectedCopySlotCommitsImmediatelyOnceReady() throws {
        var machine = Machine()
        let id = try startCopy(&machine)
        _ = send(.copyCaptured(id), to: &machine)
        XCTAssertEqual(
            send(.selectSlot(7), to: &machine),
            [.storeCopy(id, slot: 7)]
        )
    }

    func testMostRecentSelectionWinsWhileCopyIsStillPending() throws {
        var machine = Machine()
        let id = try startCopy(&machine)
        _ = send(.selectSlot(2), to: &machine)
        _ = send(.selectSlot(5), to: &machine)

        XCTAssertEqual(
            send(.copyCaptured(id), to: &machine),
            [.storeCopy(id, slot: 5)]
        )
    }

    func testSecondCopyCanReplaceAnEarlierQueuedSelectionWithDefault() throws {
        var machine = Machine()
        let id = try startCopy(&machine)
        _ = send(.selectSlot(8), to: &machine)
        _ = send(.shortcut(.copy, isRepeat: false), to: &machine, defaultSlot: 1)
        XCTAssertEqual(
            send(.copyCaptured(id), to: &machine),
            [.storeCopy(id, slot: 1)]
        )
    }

    func testFailedCopyNeverSavesQueuedSelection() throws {
        var machine = Machine()
        let id = try startCopy(&machine)
        _ = send(.selectSlot(4), to: &machine)

        XCTAssertEqual(
            send(.copyFailed(id, message: "Нет выделения."), to: &machine),
            [.discardCopy(id), .hideOverlay, .showError("Нет выделения.")]
        )
        XCTAssertEqual(machine.phase, .idle)
        XCTAssertEqual(send(.copyCaptured(id), to: &machine), [])
    }

    func testEmptyCaptureFailureMessageGetsUsefulFallback() throws {
        var machine = Machine()
        let id = try startCopy(&machine)
        XCTAssertEqual(
            send(.copyFailed(id, message: " \n "), to: &machine),
            [.discardCopy(id), .hideOverlay, .showError("Не удалось скопировать выделение.")]
        )
    }

    func testEscapeDuringCopyDiscardsDataAndMakesLateCallbacksHarmless() throws {
        var machine = Machine()
        let id = try startCopy(&machine)
        XCTAssertEqual(send(.cancel, to: &machine), [.discardCopy(id), .hideOverlay])
        XCTAssertEqual(send(.copyCaptured(id), to: &machine), [])
        XCTAssertEqual(send(.copyFailed(id, message: "late"), to: &machine), [])
        XCTAssertEqual(machine.phase, .idle)
    }

    func testStaleCopyCallbackCannotAffectNewCopySession() throws {
        var machine = Machine()
        let oldID = try startCopy(&machine)
        _ = send(.cancel, to: &machine)
        let newID = try startCopy(&machine)
        XCTAssertNotEqual(oldID, newID)
        XCTAssertEqual(send(.copyCaptured(oldID), to: &machine), [])
        XCTAssertEqual(send(.copyFailed(oldID, message: "late"), to: &machine), [])
        XCTAssertEqual(machine.currentCopyID, newID)
        guard case .copying(let session) = machine.phase else {
            return XCTFail("Stale callbacks must not cancel the new copy.")
        }
        XCTAssertFalse(session.isReady)
    }

    func testDuplicateSuccessAndLateFailureCannotUndoReadySnapshot() throws {
        var machine = Machine()
        let id = try startCopy(&machine)
        _ = send(.copyCaptured(id), to: &machine)
        XCTAssertEqual(send(.copyCaptured(id), to: &machine), [])
        XCTAssertEqual(send(.copyFailed(id, message: "late"), to: &machine), [])
        guard case .copying(let session) = machine.phase else {
            return XCTFail("A ready snapshot must remain available.")
        }
        XCTAssertTrue(session.isReady)
    }

    func testFirstPasteOnlyOpensPanel() {
        var machine = Machine()
        XCTAssertEqual(
            send(.shortcut(.paste, isRepeat: false), to: &machine, occupied: [0]),
            [.showOverlay(.paste, isLoading: false)]
        )
        XCTAssertEqual(machine.phase, .pasting)
    }

    func testRepeatedPasteUsesConfiguredDefaultExactlyOnce() {
        var machine = Machine()
        _ = send(.shortcut(.paste, isRepeat: false), to: &machine)
        XCTAssertEqual(
            send(.shortcut(.paste, isRepeat: false), to: &machine, defaultSlot: 6, occupied: [0, 6]),
            [.hideOverlay, .pasteSlot(6)]
        )
        XCTAssertEqual(machine.phase, .idle)
    }

    func testEmptyDefaultKeepsPastePanelOpen() {
        var machine = Machine()
        _ = send(.shortcut(.paste, isRepeat: false), to: &machine)
        XCTAssertEqual(
            send(.shortcut(.paste, isRepeat: false), to: &machine, defaultSlot: 0, occupied: [1]),
            [.showError("Ячейка 1 пуста. Сначала сохраните в неё фрагмент.")]
        )
        XCTAssertEqual(machine.phase, .pasting)
        XCTAssertEqual(send(.selectSlot(1), to: &machine, occupied: [1]), [.hideOverlay, .pasteSlot(1)])
    }

    func testSelectedEmptySlotNeverFallsBackToOtherClipboard() {
        var machine = Machine()
        _ = send(.shortcut(.paste, isRepeat: false), to: &machine)
        XCTAssertEqual(
            send(.selectSlot(9), to: &machine, occupied: [0]),
            [.showError("Ячейка 10 пуста. Сначала сохраните в неё фрагмент.")]
        )
        XCTAssertEqual(machine.phase, .pasting)
    }

    func testPasteUsesFreshOccupancyInformation() {
        var machine = Machine()
        _ = send(.shortcut(.paste, isRepeat: false), to: &machine, occupied: [2])
        XCTAssertEqual(
            send(.selectSlot(2), to: &machine, occupied: []),
            [.showError("Ячейка 3 пуста. Сначала сохраните в неё фрагмент.")]
        )
    }

    func testEscapeCancelsPasteWithoutPasting() {
        var machine = Machine()
        _ = send(.shortcut(.paste, isRepeat: false), to: &machine)
        XCTAssertEqual(send(.cancel, to: &machine), [.hideOverlay])
        XCTAssertEqual(send(.cancel, to: &machine), [])
        XCTAssertEqual(send(.selectSlot(0), to: &machine, occupied: [0]), [])
    }

    func testPasteDuringCopyDiscardsCaptureAndIgnoresLateResults() throws {
        var machine = Machine()
        let id = try startCopy(&machine)
        XCTAssertEqual(
            send(.shortcut(.paste, isRepeat: false), to: &machine),
            [.discardCopy(id), .showOverlay(.paste, isLoading: false)]
        )
        XCTAssertEqual(send(.copyCaptured(id), to: &machine), [])
        XCTAssertEqual(machine.phase, .pasting)
    }

    func testCopyDuringPasteStartsFreshNativeCopy() throws {
        var machine = Machine()
        _ = send(.shortcut(.paste, isRepeat: false), to: &machine)
        let id = try startCopy(&machine)
        XCTAssertEqual(machine.currentCopyID, id)
    }

    func testAutorepeatNeverActsAsConfirmationOrStartsSession() throws {
        var machine = Machine()
        XCTAssertEqual(send(.shortcut(.copy, isRepeat: true), to: &machine), [])
        XCTAssertEqual(send(.shortcut(.paste, isRepeat: true), to: &machine), [])
        XCTAssertEqual(machine.phase, .idle)

        let id = try startCopy(&machine)
        _ = send(.copyCaptured(id), to: &machine)
        XCTAssertEqual(send(.shortcut(.copy, isRepeat: true), to: &machine), [])
        XCTAssertEqual(machine.currentCopyID, id)
        _ = send(.cancel, to: &machine)

        _ = send(.shortcut(.paste, isRepeat: false), to: &machine)
        XCTAssertEqual(send(.shortcut(.paste, isRepeat: true), to: &machine, occupied: [0]), [])
        XCTAssertEqual(machine.phase, .pasting)
    }

    func testOutOfRangeSelectionCannotStoreOrPaste() throws {
        var machine = Machine()
        let id = try startCopy(&machine)
        _ = send(.copyCaptured(id), to: &machine)
        for slot in [-1, 10, Int.max, Int.min] {
            XCTAssertEqual(send(.selectSlot(slot), to: &machine), [.showError("Выберите ячейку от 1 до 10.")])
        }
        XCTAssertEqual(machine.currentCopyID, id)
        _ = send(.cancel, to: &machine)
        _ = send(.shortcut(.paste, isRepeat: false), to: &machine)
        XCTAssertEqual(send(.selectSlot(10), to: &machine, occupied: [10]), [.showError("Выберите ячейку от 1 до 10.")])
        XCTAssertEqual(machine.phase, .pasting)
    }

    func testInvalidDefaultUsesFirstSlotForCopyAndPaste() throws {
        var machine = Machine()
        let id = try startCopy(&machine)
        _ = send(.copyCaptured(id), to: &machine)
        XCTAssertEqual(
            send(.shortcut(.copy, isRepeat: false), to: &machine, defaultSlot: -1),
            [.storeCopy(id, slot: 0)]
        )
        _ = send(.copyStored(id), to: &machine)
        _ = send(.shortcut(.paste, isRepeat: false), to: &machine)
        XCTAssertEqual(
            send(.shortcut(.paste, isRepeat: false), to: &machine, defaultSlot: 99, occupied: [0]),
            [.hideOverlay, .pasteSlot(0)]
        )
    }

    func testStoreFailureKeepsSnapshotAndAllowsDifferentSlot() throws {
        var machine = Machine()
        let id = try startCopy(&machine)
        _ = send(.copyCaptured(id), to: &machine)
        XCTAssertEqual(send(.selectSlot(2), to: &machine), [.storeCopy(id, slot: 2)])
        XCTAssertEqual(
            send(.copyStoreFailed(id, message: "Недостаточно памяти."), to: &machine),
            [.showOverlay(.copy, isLoading: false), .showError("Недостаточно памяти.")]
        )
        XCTAssertEqual(machine.currentCopyID, id)
        guard case .copying(let session) = machine.phase else {
            return XCTFail("A failed store must leave the captured snapshot available.")
        }
        XCTAssertTrue(session.isReady)
        XCTAssertFalse(session.isStoring)
        XCTAssertEqual(send(.selectSlot(7), to: &machine), [.storeCopy(id, slot: 7)])
        XCTAssertEqual(send(.copyStored(id), to: &machine), [.discardCopy(id), .hideOverlay])
        XCTAssertEqual(machine.phase, .idle)
    }

    func testStoreAcknowledgementMustMatchActiveRequestedStore() throws {
        var machine = Machine()
        let id = try startCopy(&machine)
        XCTAssertEqual(send(.copyStored(id), to: &machine), [])
        _ = send(.copyCaptured(id), to: &machine)
        XCTAssertEqual(send(.copyStored(id), to: &machine), [])
        _ = send(.selectSlot(0), to: &machine)
        let stale = UUID()
        XCTAssertEqual(send(.copyStored(stale), to: &machine), [])
        XCTAssertEqual(send(.copyStoreFailed(stale, message: "stale"), to: &machine), [])
        XCTAssertEqual(send(.selectSlot(1), to: &machine), [])
        XCTAssertEqual(send(.shortcut(.copy, isRepeat: false), to: &machine), [])
        XCTAssertEqual(send(.copyStored(id), to: &machine), [.discardCopy(id), .hideOverlay])
        XCTAssertEqual(send(.copyStored(id), to: &machine), [])
    }

    func testCancelledStoreCannotReopenPanelThroughLateAcknowledgement() throws {
        var machine = Machine()
        let id = try startCopy(&machine)
        _ = send(.copyCaptured(id), to: &machine)
        _ = send(.selectSlot(4), to: &machine)
        XCTAssertEqual(send(.cancel, to: &machine), [.discardCopy(id), .hideOverlay])
        XCTAssertEqual(send(.copyStored(id), to: &machine), [])
        XCTAssertEqual(send(.copyStoreFailed(id, message: "late"), to: &machine), [])
        XCTAssertEqual(machine.phase, .idle)
    }
}
