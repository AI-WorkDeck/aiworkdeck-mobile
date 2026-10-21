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
    std::puts("PASS: real WebRTC 300 s threshold; AAC final payload before EOS; missing frames; pause/reset; partial frames; voice PCM resets silence");
}
