import AVFoundation
import SwiftUI
import XCTest
@testable import Workdeck

@MainActor
final class RecordPlaybackTests: XCTestCase {
    private func audioItem() throws -> CaptureItem {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160_000))
        buffer.frameLength = buffer.frameCapacity
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for n in 0..<Int(buffer.frameLength) { samples[n] = 0.05 * sin(Float(n) * 0.04) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let fixture = TestItems.make(.arrived, kind: .audio)
        return CaptureItem(id: fixture.id, kind: .audio, state: fixture.state, manifest: fixture.manifest,
                           localURL: url, progress: 1, lastError: nil, savedToAlbum: false, project: nil)
    }

    func testReappearingRecordRetainsPlayerAndPosition() async throws {
        let item = try audioItem()
        let playback = RecordPlayback(isRecording: { false })
        await playback.prepare(item)
        let player = try XCTUnwrap(playback.player)
        await player.seek(to: CMTime(seconds: 2, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        for _ in 0..<4 { await playback.prepare(item) }
        XCTAssertTrue(playback.player === player)
        XCTAssertEqual(player.currentTime().seconds, 2, accuracy: 0.05)
        playback.stop()
    }

    func testNativeSplitCollapseKeepsTheMountedViewerPlayer() async throws {
        let item = try audioItem()
        var observed: [RecordPlayback] = []
        var viewer = ViewerView(items: [item], index: 0, onClose: {})
        viewer.playbackForTesting = { observed.append($0) }
        let columns = PlaybackSplitColumns()
        let host = UIHostingController(rootView: PlaybackSplitHarness(columns: columns, viewer: viewer))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 890, height: 626))
        window.rootViewController = host
        host.traitOverrides.horizontalSizeClass = .regular
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; observed.first?.stop() }
        host.view.layoutIfNeeded()
        for _ in 0..<50 {
            if observed.first?.player != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let playback = try XCTUnwrap(observed.first)
        let player = try XCTUnwrap(playback.player)
        await player.seek(to: CMTime(seconds: 2, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        playback.toggle()
        var previousTime = player.currentTime().seconds
        for compact in [true, false, true, false] {
            columns.visibility = compact ? .detailOnly : .all
            columns.preferred = .detail
            host.traitOverrides.horizontalSizeClass = compact ? .compact : .regular
            window.frame.size = compact ? CGSize(width: 466, height: 678) : CGSize(width: 890, height: 626)
            host.view.frame = window.bounds
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(350))
            XCTAssertTrue(observed.allSatisfy { $0 === playback })
            XCTAssertTrue(playback.player === player)
            XCTAssertTrue(playback.playing)
            XCTAssertEqual(player.rate, 1)
            XCTAssertGreaterThanOrEqual(player.currentTime().seconds, previousTime)
            previousTime = player.currentTime().seconds
        }
    }

    func testChangingRecordReleasesPreviousPlayer() async throws {
        let first = try audioItem(), second = try audioItem()
        let playback = RecordPlayback(isRecording: { false })
        await playback.prepare(first)
        let old = try XCTUnwrap(playback.player)
        await playback.prepare(second)
        XCTAssertFalse(playback.player === old)
        XCTAssertEqual(playback.itemID, second.id)
        XCTAssertEqual(old.rate, 0)
        playback.stop()
    }

    func testRecordingBlocksPreparationAndStopsExistingPlayback() async throws {
        let item = try audioItem()
        var recording = false
        let playback = RecordPlayback(isRecording: { recording })
        await playback.prepare(item)
        let old = try XCTUnwrap(playback.player)
        recording = true
        playback.toggle()
        XCTAssertNil(playback.player)
        XCTAssertFalse(playback.playing)
        XCTAssertEqual(old.rate, 0)
        await playback.prepare(item)
        XCTAssertNil(playback.player)
        XCTAssertEqual(playback.message, tr("player.stopRecordingFirst"))
        recording = false
        await playback.prepare(item)
        XCTAssertNotNil(playback.player)
        XCTAssertNil(playback.message)
        playback.stop()
    }
}

@MainActor
@Observable
private final class PlaybackSplitColumns {
    var visibility: NavigationSplitViewVisibility = .all
    var preferred: NavigationSplitViewColumn = .detail
}

private struct PlaybackSplitHarness: View {
    @Bindable var columns: PlaybackSplitColumns
    let viewer: ViewerView
    var body: some View {
        NavigationSplitView(columnVisibility: $columns.visibility, preferredCompactColumn: $columns.preferred) {
            List { Text("Synthetic recording") }
        } detail: {
            viewer
        }.navigationSplitViewStyle(.balanced)
    }
}
