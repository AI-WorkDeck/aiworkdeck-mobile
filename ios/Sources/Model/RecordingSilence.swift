import Foundation

/// Count only audio actually classified; missing analysis is never evidence of silence.
struct RecordingSilence {
    private var silentSince: TimeInterval?
    private var lastEnd: TimeInterval?
    private(set) var needsConfirmation = false

    mutating func observe(start: TimeInterval, end: TimeInterval, voice: Bool) {
        guard start.isFinite, end.isFinite, end > start else { return }
        if let lastEnd, end <= lastEnd { return }
        if let lastEnd, start > lastEnd + 1 {
            silentSince = nil
            needsConfirmation = false
        }
        lastEnd = end
        if voice {
            silentSince = end
            needsConfirmation = false
        } else {
            if silentSince == nil { silentSince = start }
            if end - (silentSince ?? end) >= 300 { needsConfirmation = true }
        }
    }

    mutating func keepRecording() {
        silentSince = lastEnd
        needsConfirmation = false
    }
}
