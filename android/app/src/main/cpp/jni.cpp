// Small JNI bridge so Kotlin can load a whisper model and turn 16 kHz audio into text.
#include <jni.h>
#include <string>
#include <android/log.h>
#include "whisper.h"

#define LOG(...) __android_log_print(ANDROID_LOG_INFO, "UtterWhisper", __VA_ARGS__)

extern "C" JNIEXPORT jlong JNICALL
Java_local_utter_Whisper_nativeInit(JNIEnv *env, jclass, jstring path) {
    const char *p = env->GetStringUTFChars(path, nullptr);
    whisper_context_params cp = whisper_context_default_params();
    cp.use_gpu = false;
    cp.flash_attn = true;
    whisper_context *ctx = whisper_init_from_file_with_params(p, cp);
    LOG("loaded %s: %p", p, ctx);
    env->ReleaseStringUTFChars(path, p);
    return reinterpret_cast<jlong>(ctx);
}

extern "C" JNIEXPORT jstring JNICALL
Java_local_utter_Whisper_nativeTranscribe(JNIEnv *env, jclass, jlong handle, jfloatArray audio,
                                          jstring language, jstring prompt, jint threads, jint audioCtx, jboolean fallback) {
    auto *ctx = reinterpret_cast<whisper_context *>(handle);
    if (!ctx) return env->NewStringUTF("");

    const char *l = env->GetStringUTFChars(language, nullptr);
    std::string lang(l);
    env->ReleaseStringUTFChars(language, l);
    // A short mixed Chinese/English primer keeps code-switching as spoken instead of translating it.
    const char *pr = env->GetStringUTFChars(prompt, nullptr);
    std::string primer(pr);
    env->ReleaseStringUTFChars(prompt, pr);

    whisper_full_params p = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    p.language = lang.c_str();
    p.n_threads = threads;
    // Timestamp mode: with no_timestamps whisper often stops after the first sentence of a chunk.
    p.no_timestamps = false;
    p.print_progress = false;
    p.print_realtime = false;
    p.print_timestamps = false;
    p.print_special = false;
    p.suppress_nst = true;
    if (!primer.empty()) p.initial_prompt = primer.c_str();
    // Short chunks don't need the full 30 s encoder window; ~15 s (768) was as accurate in tests and much faster.
    p.audio_ctx = audioCtx;
    // Temperature fallback can loop for many seconds on a short leftover; the re-run skips it.
    if (!fallback) p.temperature_inc = 0.0f;

    jsize n = env->GetArrayLength(audio);
    jfloat *data = env->GetFloatArrayElements(audio, nullptr);
    int rc = whisper_full(ctx, p, data, n);
    env->ReleaseFloatArrayElements(audio, data, JNI_ABORT);

    if (rc != 0) { LOG("whisper_full failed: %d", rc); return nullptr; }  // Kotlin sees null and retries later
    std::string out;
    {
        for (int i = 0; i < whisper_full_n_segments(ctx); i++) out += whisper_full_get_segment_text(ctx, i);
    }
    // Java wants UTF-16; go through a byte array so Chinese and emoji survive.
    jbyteArray bytes = env->NewByteArray((jsize) out.size());
    env->SetByteArrayRegion(bytes, 0, (jsize) out.size(), reinterpret_cast<const jbyte *>(out.data()));
    jclass str = env->FindClass("java/lang/String");
    jmethodID ctor = env->GetMethodID(str, "<init>", "([BLjava/lang/String;)V");
    return (jstring) env->NewObject(str, ctor, bytes, env->NewStringUTF("UTF-8"));
}

// End of the last segment of the last transcription, in ms (whisper sometimes stops early,
// e.g. right after a switch between Chinese and English; Kotlin then re-runs the rest).
extern "C" JNIEXPORT jint JNICALL
Java_local_utter_Whisper_nativeLastEndMs(JNIEnv *, jclass, jlong handle) {
    auto *ctx = reinterpret_cast<whisper_context *>(handle);
    if (!ctx) return 0;
    int n = whisper_full_n_segments(ctx);
    if (n == 0) return 0;
    return (jint) (whisper_full_get_segment_t1(ctx, n - 1) * 10);
}

extern "C" JNIEXPORT void JNICALL
Java_local_utter_Whisper_nativeFree(JNIEnv *, jclass, jlong handle) {
    if (handle) whisper_free(reinterpret_cast<whisper_context *>(handle));
}
