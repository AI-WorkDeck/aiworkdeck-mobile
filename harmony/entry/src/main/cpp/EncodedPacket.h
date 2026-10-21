#pragma once
#include <cstdint>
#include <vector>

// EOS is an independent flag: the same output buffer may contain the final audio payload.
// Drain that payload before acknowledging EOS, including when the writer reports a failure.
template<class Write, class End>
bool consumeEncodedPacket(int size, bool codecData, bool eos, Write write, End end) {
    bool ok = true;
    if (size > 0 && !codecData) ok = write();
    if (eos) end();
    return ok;
}

// Some platform AAC encoders emit EOS with the preceding packet's PTS and bytes.
// Suppress only that proven duplicate, not an independent final payload. Copy before
// writing because a muxer may consume/transform the buffer (for example strip ADTS).
class EncodedPackets {
public:
    template<class Write, class End>
    bool consume(const uint8_t *data, int size, int64_t pts, bool codecData, bool eos, Write write, End end) {
        return consumeEncodedPacket(size, codecData, eos, [&] {
            std::vector<uint8_t> payload(data, data + size);
            if (eos && hasPacket && pts == lastPts && payload == lastPayload) return true;
            // An unexplained overlap is a codec failure; do not invent timestamps or drop evidence silently.
            if (hasPacket && pts <= lastPts) return false;
            if (!write()) return false;
            lastPayload = std::move(payload);
            lastPts = pts;
            hasPacket = true;
            return true;
        }, end);
    }
private:
    bool hasPacket = false;
    int64_t lastPts = 0;
    std::vector<uint8_t> lastPayload;
};
