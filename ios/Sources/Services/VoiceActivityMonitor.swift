@preconcurrency import AVFoundation
@preconcurrency import SoundAnalysis
import Foundation

/// Independent best-effort analysis: recording and its durable file stay with AVAudioRecorder.
/// All analyzer work is confined to this queue. No audio leaves the device.
final class VoiceActivityMonitor: NSObject, SNResultsObserving, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.aiworkdeck.mobile.voice-analysis")
    private let engine = AVAudioEngine()
    private let available = DispatchSemaphore(value: 1)
    private var analyzer: SNAudioStreamAnalyzer?
    private let onResult: @Sendable (TimeInterval, TimeInterval, Bool) -> Void
    private let onFailure: @Sendable () -> Void
    private var tapped = false

    init(onResult: @escaping @Sendable (TimeInterval, TimeInterval, Bool) -> Void,
         onFailure: @escaping @Sendable () -> Void) {
        self.onResult = onResult
        self.onFailure = onFailure
    }

    func start() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw CocoaError(.coderInvalidValue) }
        let analyzer = SNAudioStreamAnalyzer(format: format)
        let request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        request.windowDuration = CMTime(seconds: 1.5, preferredTimescale: 48_000)
        request.overlapFactor = 0.5
        try analyzer.add(request, withObserver: self)
        queue.sync { self.analyzer = analyzer }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, time in
            // Never block the real-time microphone callback or retain its reusable buffer.
            // Drop analysis when busy; timestamp gaps reset the silence countdown.
            guard let self, self.available.wait(timeout: .now()) == .success else { return }
            guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
                self.available.signal()
                return
            }
            copy.frameLength = buffer.frameLength
            let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
            for index in source.indices {
                if let from = source[index].mData, let to = target[index].mData {
                    memcpy(to, from, Int(source[index].mDataByteSize))
                }
            }
            let position = time.sampleTime
            self.queue.async {
                defer { self.available.signal() }
                self.analyzer?.analyze(copy, atAudioFramePosition: position)
            }
        }
        tapped = true
        do { try engine.start() }
        catch { stop(); throw error }
    }

    func stop() {
        engine.stop()
        if tapped { engine.inputNode.removeTap(onBus: 0); tapped = false }
        queue.sync { analyzer?.removeAllRequests(); analyzer = nil }
    }

    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        let voice = result.classifications.contains {
            ($0.identifier.contains("speech") || $0.identifier == "singing" ||
             $0.identifier == "laughter" || $0.identifier == "conversation") && $0.confidence >= 0.4
        }
        onResult(result.timeRange.start.seconds, CMTimeRangeGetEnd(result.timeRange).seconds, voice)
    }

    func request(_ request: SNRequest, didFailWithError error: Error) { onFailure() }
    func requestDidComplete(_ request: SNRequest) {}
}
