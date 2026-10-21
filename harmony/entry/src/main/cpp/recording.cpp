#include <napi/native_api.h>
#include <multimedia/player_framework/native_avcodec_audiocodec.h>
#include <multimedia/player_framework/native_avformat.h>
#include <multimedia/player_framework/native_avbuffer.h>
#include <multimedia/player_framework/native_avmuxer.h>
#include "VoiceFrames.h"
#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <deque>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

// One process recorder. AudioCapturer owns the sole microphone; these exact PCM samples
// go to AAC and WebRTC VAD. No speech/audio is sent to a network service.
namespace {
constexpr int RATE = 48000;
struct Input { uint32_t index; OH_AVBuffer *buffer; };
class Recording {
public:
    std::atomic<bool> failed{false};
    bool start(int fd) {
        codec = OH_AudioCodec_CreateByMime(OH_AVCODEC_MIMETYPE_AUDIO_AAC, true);
        muxer = OH_AVMuxer_Create(fd, AV_OUTPUT_FORMAT_M4A);
        if (!codec || !muxer) return false;
        OH_AVFormat *format = OH_AVFormat_Create();
        OH_AVFormat_SetStringValue(format, OH_MD_KEY_CODEC_MIME, OH_AVCODEC_MIMETYPE_AUDIO_AAC);
        OH_AVFormat_SetIntValue(format, OH_MD_KEY_AUD_SAMPLE_RATE, RATE);
        OH_AVFormat_SetIntValue(format, OH_MD_KEY_AUD_CHANNEL_COUNT, 1);
        OH_AVFormat_SetIntValue(format, OH_MD_KEY_AUDIO_SAMPLE_FORMAT, SAMPLE_S16LE);
        OH_AVFormat_SetLongValue(format, OH_MD_KEY_BITRATE, 64000);
        OH_AVFormat_SetIntValue(format, OH_MD_KEY_AAC_IS_ADTS, 0);
        OH_AVFormat_SetIntValue(format, OH_MD_KEY_PROFILE, AAC_PROFILE_LC);
        OH_AVCodecCallback callbacks{error, changed, input, output};
        bool ok = OH_AudioCodec_RegisterCallback(codec, callbacks, this) == AV_ERR_OK &&
            OH_AudioCodec_Configure(codec, format) == AV_ERR_OK &&
            OH_AudioCodec_Prepare(codec) == AV_ERR_OK;
        // AAC-LC AudioSpecificConfig: object type 2, sample-rate index 3 (48 kHz), mono.
        const uint8_t asc[] = {0x11, 0x88};
        OH_AVFormat_SetBuffer(format, OH_MD_KEY_CODEC_CONFIG, asc, sizeof(asc));
        ok = ok && OH_AVMuxer_AddTrack(muxer, &track, format) == AV_ERR_OK &&
            OH_AVMuxer_Start(muxer) == AV_ERR_OK;
        OH_AVFormat_Destroy(format);
        if (!ok) return false;
        muxerStarted = true;
        if (OH_AudioCodec_Start(codec) != AV_ERR_OK) return false;
        worker = std::thread([this] { feed(); });
        return true;
    }
    int push(const int16_t *data, size_t count) {
        if (failed || count == 0 || count > RATE) return -2;
        {
            std::lock_guard<std::mutex> lock(mutex);
            // Backpressure must never silently drop evidence. Stop/save with a visible failure.
            if (ending || pcm.size() + count > RATE * 2) { failed = true; ready.notify_all(); return -2; }
            pcm.insert(pcm.end(), data, data + count);
        }
        ready.notify_all();
        const int64_t now = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now().time_since_epoch()).count();
        return voice.push(data, count, now);
    }
    void resetVoice() { voice.reset(); }
    bool finish() {
        {
            std::lock_guard<std::mutex> lock(mutex);
            ending = true;
        }
        ready.notify_all();
        {
            std::unique_lock<std::mutex> lock(mutex);
            if (!ready.wait_for(lock, std::chrono::seconds(4), [this] { return eos || failed; })) failed = true;
            quitting = true;
        }
        ready.notify_all();
        if (worker.joinable()) worker.join();
        if (codec) { OH_AudioCodec_Stop(codec); OH_AudioCodec_Destroy(codec); codec = nullptr; }
        // Finalize even after a codec failure: already encoded evidence may still be playable.
        if (muxerStarted && OH_AVMuxer_Stop(muxer) != AV_ERR_OK) failed = true;
        muxerStarted = false;
        return !failed;
    }
    ~Recording() {
        { std::lock_guard<std::mutex> lock(mutex); quitting = true; }
        ready.notify_all();
        if (worker.joinable()) worker.join();
        if (codec) { OH_AudioCodec_Stop(codec); OH_AudioCodec_Destroy(codec); }
        if (muxer) { if (muxerStarted) OH_AVMuxer_Stop(muxer); OH_AVMuxer_Destroy(muxer); }
    }
private:
    OH_AVCodec *codec = nullptr;
    OH_AVMuxer *muxer = nullptr;
    VoiceFrames voice;
    int32_t track = -1;
    bool muxerStarted = false;
    std::mutex mutex;
    std::condition_variable ready;
    std::deque<Input> inputs;
    std::deque<int16_t> pcm;
    std::thread worker;
    bool ending = false, quitting = false, eos = false;
    uint64_t samples = 0;
    static void error(OH_AVCodec *, int32_t, void *user) {
        auto *r = static_cast<Recording *>(user); r->failed = true; r->ready.notify_all();
    }
    static void changed(OH_AVCodec *, OH_AVFormat *, void *) {}
    static void input(OH_AVCodec *, uint32_t index, OH_AVBuffer *buffer, void *user) {
        auto *r = static_cast<Recording *>(user);
        { std::lock_guard<std::mutex> lock(r->mutex); r->inputs.push_back({index, buffer}); }
        r->ready.notify_all();
    }
    static void output(OH_AVCodec *codec, uint32_t index, OH_AVBuffer *buffer, void *user) {
        auto *r = static_cast<Recording *>(user);
        OH_AVCodecBufferAttr attr{};
        if (OH_AVBuffer_GetBufferAttr(buffer, &attr) != AV_ERR_OK) r->failed = true;
        else if (attr.flags & AVCODEC_BUFFER_FLAGS_EOS) {
            std::lock_guard<std::mutex> lock(r->mutex); r->eos = true;
        } else if (!(attr.flags & AVCODEC_BUFFER_FLAGS_CODEC_DATA) && attr.size > 0 &&
                   OH_AVMuxer_WriteSampleBuffer(r->muxer, r->track, buffer) != AV_ERR_OK) r->failed = true;
        OH_AudioCodec_FreeOutputBuffer(codec, index);
        r->ready.notify_all();
    }
    void feed() {
        while (true) {
            Input in{};
            OH_AVCodecBufferAttr attr{};
            {
                std::unique_lock<std::mutex> lock(mutex);
                ready.wait(lock, [this] { return quitting || failed || (!inputs.empty() && (!pcm.empty() || ending)); });
                if (quitting || failed) return;
                in = inputs.front(); inputs.pop_front();
                const size_t count = std::min(pcm.size(), static_cast<size_t>(OH_AVBuffer_GetCapacity(in.buffer)) / 2);
                auto *dest = reinterpret_cast<int16_t *>(OH_AVBuffer_GetAddr(in.buffer));
                if (!dest || (count == 0 && !pcm.empty())) { failed = true; ready.notify_all(); return; }
                for (size_t i = 0; i < count; ++i) { dest[i] = pcm.front(); pcm.pop_front(); }
                attr.pts = static_cast<int64_t>(samples * 1000000 / RATE);
                attr.size = static_cast<int32_t>(count * 2);
                attr.flags = count == 0 && ending ? AVCODEC_BUFFER_FLAGS_EOS : AVCODEC_BUFFER_FLAGS_NONE;
                samples += count;
            }
            if (OH_AVBuffer_SetBufferAttr(in.buffer, &attr) != AV_ERR_OK ||
                OH_AudioCodec_PushInputBuffer(codec, in.index) != AV_ERR_OK) { failed = true; ready.notify_all(); return; }
            if (attr.flags & AVCODEC_BUFFER_FLAGS_EOS) return;
        }
    }
};
std::unique_ptr<Recording> recording;
bool finishing = false;
napi_value boolean(napi_env env, bool value) { napi_value result; napi_get_boolean(env, value, &result); return result; }
napi_value Start(napi_env env, napi_callback_info info) {
    size_t argc = 1; napi_value args[1]; int32_t fd = -1;
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc != 1 || napi_get_value_int32(env, args[0], &fd) != napi_ok || fd < 0 || recording || finishing)
        return boolean(env, false);
    auto next = std::make_unique<Recording>();
    if (!next->start(fd)) return boolean(env, false);
    recording = std::move(next);
    return boolean(env, true);
}
napi_value Push(napi_env env, napi_callback_info info) {
    size_t argc = 1, bytes = 0; napi_value args[1]; void *data = nullptr;
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int status = -2;
    if (argc == 1 && recording && !finishing && napi_get_arraybuffer_info(env, args[0], &data, &bytes) == napi_ok && bytes % 2 == 0)
        status = recording->push(static_cast<int16_t *>(data), bytes / 2);
    napi_value result; napi_create_int32(env, status, &result); return result;
}
napi_value Reset(napi_env env, napi_callback_info) {
    if (recording && !finishing) recording->resetVoice();
    napi_value result; napi_get_undefined(env, &result); return result;
}
struct FinishWork { napi_async_work work; napi_deferred deferred; std::unique_ptr<Recording> value; bool ok = true; };
napi_value Finish(napi_env env, napi_callback_info) {
    auto *work = new FinishWork{};
    napi_value promise, name;
    napi_create_promise(env, &work->deferred, &promise);
    if (finishing) { napi_resolve_deferred(env, work->deferred, boolean(env, false)); delete work; return promise; }
    work->value = std::move(recording); finishing = true;
    napi_create_string_utf8(env, "finishRecording", NAPI_AUTO_LENGTH, &name);
    napi_create_async_work(env, nullptr, name,
        [](napi_env, void *data) { auto *w = static_cast<FinishWork *>(data); if (w->value) w->ok = w->value->finish(); w->value.reset(); },
        [](napi_env env, napi_status, void *data) { auto *w = static_cast<FinishWork *>(data); finishing = false;
            napi_resolve_deferred(env, w->deferred, boolean(env, w->ok)); napi_delete_async_work(env, w->work); delete w; },
        work, &work->work);
    napi_queue_async_work(env, work->work);
    return promise;
}
napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor methods[] = {
        {"start", nullptr, Start, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"push", nullptr, Push, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"resetVoice", nullptr, Reset, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"finish", nullptr, Finish, nullptr, nullptr, nullptr, napi_default, nullptr}
    };
    napi_define_properties(env, exports, sizeof(methods) / sizeof(methods[0]), methods);
    return exports;
}
napi_module module = {1, 0, nullptr, Init, "recording", nullptr, {0}};
}
extern "C" __attribute__((constructor)) void RegisterRecording() { napi_module_register(&module); }
