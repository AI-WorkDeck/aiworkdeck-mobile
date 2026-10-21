#include "../../harmony/entry/src/main/cpp/VoiceFrames.h"
#include "../../harmony/entry/src/main/cpp/EncodedPacket.h"
#include <cassert>
#include <cstdio>
#include <fstream>
#include <iterator>
#include <vector>
int main(int argc, char **argv) {
    std::vector<int> events;
    const auto write = [&events] { events.push_back(1); return true; };
    const auto end = [&events] { events.push_back(2); };
    assert(consumeEncodedPacket(128, false, true, write, end));
    assert((events == std::vector<int>{1, 2})); // final payload before EOS acknowledgement
    events.clear();
    assert(consumeEncodedPacket(2, true, true, write, end));
    assert((events == std::vector<int>{2})); // codec config is not audio
    events.clear();
    assert(!consumeEncodedPacket(128, false, true, [] { return false; }, end));
    assert((events == std::vector<int>{2})); // failure retained, EOS still wakes finalizer
    events.clear();
    assert(consumeEncodedPacket(0, false, true, write, end));
    assert((events == std::vector<int>{2}));
    EncodedPackets packets;
    const uint8_t payload[] = {0x01, 0x18, 0x20, 0x07};
    const uint8_t distinct[] = {0x01, 0x18, 0x20, 0x08};
    events.clear();
    assert(packets.consume(payload, 4, 1000, false, false, write, end));
    assert(packets.consume(payload, 4, 1000, false, true, write, end));
    assert((events == std::vector<int>{1, 2})); // platform EOS repeats preceding PTS AND full payload
    events.clear();
    assert(packets.consume(payload, 4, 22333, false, true, write, end));
    assert((events == std::vector<int>{1, 2})); // repeated silence bytes at a new PTS are valid audio
    events.clear();
    assert(!packets.consume(distinct, 4, 22333, false, true, write, end));
    assert((events == std::vector<int>{2})); // same PTS but different audio cannot be silently dropped
    events.clear();
    assert(!packets.consume(payload, 4, 20000, false, false, write, end));
    assert(events.empty()); // unexplained timestamp regression is visible failure
    EncodedPackets single;
    assert(single.consume(payload, 4, 0, false, true, write, end)); // first/final payload retained
    EncodedPackets mutatingWriter;
    uint8_t mutablePayload[] = {1, 2, 3};
    const uint8_t original[] = {1, 2, 3};
    assert(mutatingWriter.consume(mutablePayload, 3, 0, false, false, [&] { mutablePayload[0] = 9; return true; }, end));
    events.clear();
    assert(mutatingWriter.consume(original, 3, 0, false, true, write, end));
    assert((events == std::vector<int>{2})); // compare bytes captured before a muxer modifies the buffer
    assert(argc == 2);
    VoiceFrames voice;
    std::vector<int16_t> zero(480, 0);
    int status = 0;
    for (int i = 0; i < 30000; ++i) {
        status = voice.push(zero.data(), zero.size(), i * 10);
        assert(status == (i + 1) * 10);
    }
    assert(status == 300000);
    // An absent callback is unknown; five minutes of wall-time cannot create a reminder.
    assert(voice.push(zero.data(), zero.size(), 900000) == 10);
    voice.reset(); // pause/resume/keep recording
    assert(voice.push(zero.data(), 240, 900010) == 0);
    assert(voice.push(zero.data(), 240, 900015) == 10);
    std::ifstream input(argv[1], std::ios::binary);
    std::vector<char> bytes((std::istreambuf_iterator<char>(input)), {});
    assert(bytes.size() > 44);
    // The fixture is converted to raw s16le/48k/mono by the documented test command.
    const auto *pcm = reinterpret_cast<const int16_t *>(bytes.data());
    bool heardVoice = false;
    int64_t t = 900020;
    for (size_t i = 0; i + 480 <= bytes.size() / 2; i += 480, t += 10)
        if (voice.push(pcm + i, 480, t) == 0) heardVoice = true;
    assert(heardVoice);
    std::puts("PASS: real WebRTC 300 s threshold; AAC final payload and duplicate EOS; missing frames; pause/reset; partial frames; voice PCM resets silence");
}
