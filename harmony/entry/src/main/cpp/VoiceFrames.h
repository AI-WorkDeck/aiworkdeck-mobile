#pragma once
#include <fvad.h>
#include <cstdint>
#include <vector>

/** Accumulate only complete, locally classified PCM frames. Audio time, never wall time. */
class VoiceFrames {
public:
    VoiceFrames() {
        detector = fvad_new();
        if (detector && (fvad_set_sample_rate(detector, 48000) || fvad_set_mode(detector, 2))) {
            fvad_free(detector); detector = nullptr;
        }
    }
    ~VoiceFrames() { if (detector) fvad_free(detector); }
    VoiceFrames(const VoiceFrames &) = delete;
    VoiceFrames &operator=(const VoiceFrames &) = delete;
    int push(const int16_t *data, size_t count, int64_t monotonicMs) {
        if (lastMs >= 0 && monotonicMs - lastMs > 250) reset();
        lastMs = monotonicMs;
        if (!detector) return -1;
        pending.insert(pending.end(), data, data + count);
        size_t used = 0;
        while (pending.size() - used >= 480) {
            const int result = fvad_process(detector, pending.data() + used, 480);
            if (result < 0) { fvad_free(detector); detector = nullptr; pending.clear(); silentMs = 0; return -1; }
            // Clamp after a day to keep indefinitely forgotten recordings away from integer overflow.
            silentMs = result ? 0 : (silentMs < 86400000 ? silentMs + 10 : silentMs);
            used += 480;
        }
        pending.erase(pending.begin(), pending.begin() + used);
        return silentMs;
    }
    void reset() {
        pending.clear(); silentMs = 0; lastMs = -1;
        if (detector) { fvad_reset(detector); fvad_set_sample_rate(detector, 48000); fvad_set_mode(detector, 2); }
    }
private:
    Fvad *detector = nullptr;
    std::vector<int16_t> pending;
    int silentMs = 0;
    int64_t lastMs = -1;
};
