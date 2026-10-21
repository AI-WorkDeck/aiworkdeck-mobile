import XCTest
@testable import Workdeck

final class RecordingSilenceTests: XCTestCase {
    private func observeSilence(_ state: inout RecordingSilence, from: Int = 0, through: Int) {
        for second in from..<through {
            state.observe(start: Double(second), end: Double(second + 1), voice: false)
        }
    }

    func testFiveMinutesRequiresContinuousClassifiedAudio() {
        var state = RecordingSilence()
        observeSilence(&state, through: 299)
        XCTAssertFalse(state.needsConfirmation)
        state.observe(start: 299, end: 300, voice: false)
        XCTAssertTrue(state.needsConfirmation)
    }

    func testVoiceResetsCountdownAndDismissesPendingReminder() {
        var state = RecordingSilence()
        observeSilence(&state, through: 300)
        state.observe(start: 300, end: 301, voice: true)
        XCTAssertFalse(state.needsConfirmation)
        observeSilence(&state, from: 301, through: 600)
        XCTAssertFalse(state.needsConfirmation)
        state.observe(start: 600, end: 601, voice: false)
        XCTAssertTrue(state.needsConfirmation)
    }

    func testContinueWaitsAnotherFiveMinutes() {
        var state = RecordingSilence()
        observeSilence(&state, through: 300)
        state.keepRecording()
        observeSilence(&state, from: 300, through: 599)
        XCTAssertFalse(state.needsConfirmation)
        state.observe(start: 599, end: 600, voice: false)
        XCTAssertTrue(state.needsConfirmation)
    }

    func testMissingAnalysisDoesNotCountAsSilence() {
        var state = RecordingSilence()
        observeSilence(&state, through: 299)
        state.observe(start: 400, end: 401, voice: false)
        XCTAssertFalse(state.needsConfirmation)
        observeSilence(&state, from: 401, through: 699)
        XCTAssertFalse(state.needsConfirmation)
        state.observe(start: 699, end: 700, voice: false)
        XCTAssertTrue(state.needsConfirmation)
    }

    func testOverlappingWindowsDoNotDoubleCountAndOldResultsAreIgnored() {
        var state = RecordingSilence()
        for n in 0..<398 {
            let start = Double(n) * 0.75
            state.observe(start: start, end: start + 1.5, voice: false)
        }
        XCTAssertFalse(state.needsConfirmation)
        state.observe(start: 298.5, end: 300, voice: false)
        XCTAssertTrue(state.needsConfirmation)
        state.observe(start: 1, end: 2, voice: true)
        XCTAssertTrue(state.needsConfirmation)
        state = RecordingSilence()
        XCTAssertFalse(state.needsConfirmation)
    }
}
