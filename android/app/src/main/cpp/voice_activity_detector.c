#include <jni.h>
#include <stdint.h>
#include "fvad.h"

JNIEXPORT jlong JNICALL Java_com_aiworkdeck_mobile_services_VoiceActivityDetector_create(JNIEnv *env, jobject self) {
    Fvad *vad = fvad_new();
    if (!vad) return 0;
    // Aggressive mode matches the other clients; actual voice detection, never a volume threshold.
    if (fvad_set_sample_rate(vad, 48000) || fvad_set_mode(vad, 2)) {
        fvad_free(vad); return 0;
    }
    return (jlong)(intptr_t)vad;
}
JNIEXPORT jint JNICALL Java_com_aiworkdeck_mobile_services_VoiceActivityDetector_process(JNIEnv *env, jobject self, jlong handle, jshortArray pcm) {
    if (!handle || !pcm || (*env)->GetArrayLength(env, pcm) != 960) return -1;
    jshort samples[960];
    (*env)->GetShortArrayRegion(env, pcm, 0, 960, samples);
    if ((*env)->ExceptionCheck(env)) return -1;
    return fvad_process((Fvad *)(intptr_t)handle, (const int16_t *)samples, 960);
}
JNIEXPORT void JNICALL Java_com_aiworkdeck_mobile_services_VoiceActivityDetector_destroy(JNIEnv *env, jobject self, jlong handle) {
    if (handle) fvad_free((Fvad *)(intptr_t)handle);
}
