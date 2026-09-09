// P1a: C ABI v1 (analysis_engine_c.h) üzerine JNI köprüsü.
//
// Bu dosya pitch kararı ÜRETMEZ: eşikleme, yumuşatma, oktav düzeltme,
// yeniden örnekleme yoktur. Yalnız C++ çekirdeğinin döndürdüğü değerleri ve
// last_error metnini JNI sınırından Kotlin'e taşır. Kotlin tarafındaki
// NativeBridge.kt bu fonksiyonlara 1:1 karşılık gelir; asıl doğrulama ve
// sarmalama orada (PitchContract/LivePitchSession/OfflineTrackSession).
//
// C ABI v1 dondurulmuştur (core/include/klarivision/core/analysis_engine_c.h)
// ve bu dosyadan hiç değiştirilmez.
//
// Kural: hiçbir C++ istisnası JNI sınırını geçmez. C ABI katmanı zaten tüm
// istisnaları yakalayıp int/NULL/last_error'a çeviriyor, ama burada da her
// fonksiyon savunma amaçlı try/catch(...) ile sarılır.
#include <jni.h>

#include <cstring>
#include <exception>

#include "klarivision/core/analysis_engine_c.h"

namespace {

// java.nio.Buffer#position() -- GetDirectBufferAddress temel adresi
// pozisyondan bağımsız döner; bir dilimlenmiş (sliced) ya da yeniden
// kullanılan buffer'da doğru işaretçiyi elde etmek için pozisyonu kendimiz
// ekliyoruz.
jclass g_buffer_class = nullptr;
jmethodID g_buffer_position_mid = nullptr;

void ensure_buffer_ids(JNIEnv *env) {
    if (g_buffer_class != nullptr) {
        return;
    }
    jclass local = env->FindClass("java/nio/Buffer");
    if (local == nullptr) {
        return;
    }
    g_buffer_class = static_cast<jclass>(env->NewGlobalRef(local));
    g_buffer_position_mid = env->GetMethodID(g_buffer_class, "position", "()I");
    env->DeleteLocalRef(local);
}

// buffer doğrudan (direct) değilse ya da pozisyon bilgisi alınamazsa
// nullptr döner -- çağıran taraf bunu "açık hata" olarak ele alır, sessiz
// kabul yoktur.
const float *direct_float_pointer(JNIEnv *env, jobject buffer) {
    if (buffer == nullptr) {
        return nullptr;
    }
    void *base = env->GetDirectBufferAddress(buffer);
    if (base == nullptr) {
        return nullptr;
    }
    ensure_buffer_ids(env);
    if (g_buffer_position_mid == nullptr) {
        return nullptr;
    }
    jint position = env->CallIntMethod(buffer, g_buffer_position_mid);
    if (env->ExceptionCheck()) {
        env->ExceptionClear();
        return nullptr;
    }
    if (position < 0) {
        return nullptr;
    }
    return reinterpret_cast<const float *>(
        static_cast<const char *>(base) + static_cast<size_t>(position) * sizeof(float));
}

jstring safe_new_string(JNIEnv *env, const char *text) {
    return env->NewStringUTF(text != nullptr ? text : "");
}

}  // namespace

extern "C" JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *, void *) {
    return JNI_VERSION_1_6;
}

// --- Sözleşme ---------------------------------------------------------

extern "C" JNIEXPORT jdoubleArray JNICALL
Java_com_aykerme_klarivision_core_NativeBridge_nativeGetContract(JNIEnv *env, jclass) {
    try {
        kv_pitch_contract_v1 contract{};
        if (kv_pitch_contract_get_v1(&contract) != 1) {
            return nullptr;
        }
        jdoubleArray result = env->NewDoubleArray(6);
        if (result == nullptr) {
            return nullptr;
        }
        const jdouble values[6] = {
            static_cast<jdouble>(contract.abi_version),
            static_cast<jdouble>(contract.capabilities),
            static_cast<jdouble>(contract.sample_rate_hz),
            static_cast<jdouble>(contract.window_size),
            static_cast<jdouble>(contract.hop_size),
            contract.default_minimum_rms,
        };
        env->SetDoubleArrayRegion(result, 0, 6, values);
        return result;
    } catch (...) {
        return nullptr;
    }
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_aykerme_klarivision_core_NativeBridge_nativeUnifiedLagFrames(JNIEnv *, jclass) {
    try {
        return static_cast<jlong>(kv_unified_lag_frames());
    } catch (...) {
        return 0;
    }
}

// --- Canlı (causal) oturum: kv_production_pitch_session_* --------------

extern "C" JNIEXPORT jlong JNICALL
Java_com_aykerme_klarivision_core_NativeBridge_nativeLiveCreate(
    JNIEnv *, jclass, jint engine, jdouble minimumRms) {
    try {
        kv_production_pitch_session *session =
            kv_production_pitch_session_create(static_cast<int>(engine), minimumRms);
        return reinterpret_cast<jlong>(session);
    } catch (...) {
        return 0;
    }
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_aykerme_klarivision_core_NativeBridge_nativeLiveSetMinimumRms(
    JNIEnv *, jclass, jlong handle, jdouble minimumRms) {
    try {
        auto *session = reinterpret_cast<kv_production_pitch_session *>(handle);
        if (session == nullptr) {
            return JNI_FALSE;
        }
        return kv_production_pitch_session_set_minimum_rms(session, minimumRms) == 1 ? JNI_TRUE
                                                                                       : JNI_FALSE;
    } catch (...) {
        return JNI_FALSE;
    }
}

extern "C" JNIEXPORT void JNICALL
Java_com_aykerme_klarivision_core_NativeBridge_nativeLiveReset(JNIEnv *, jclass, jlong handle) {
    try {
        auto *session = reinterpret_cast<kv_production_pitch_session *>(handle);
        if (session != nullptr) {
            kv_production_pitch_session_reset(session);
        }
    } catch (...) {
        // Kararlı davranış: reset başarısız görünmez, oturum yine de kullanılabilir kalır.
    }
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_aykerme_klarivision_core_NativeBridge_nativeLiveProcess(
    JNIEnv *env, jclass, jlong handle, jobject buffer, jint sampleCount, jdouble sampleRateHz,
    jdouble sourceTimeSeconds) {
    try {
        auto *session = reinterpret_cast<kv_production_pitch_session *>(handle);
        if (session == nullptr || sampleCount < 0) {
            return JNI_FALSE;
        }
        const float *samples = direct_float_pointer(env, buffer);
        if (samples == nullptr) {
            return JNI_FALSE;
        }
        int ok = kv_production_pitch_session_process_frame(
            session, samples, static_cast<size_t>(sampleCount), sampleRateHz, sourceTimeSeconds);
        return ok == 1 ? JNI_TRUE : JNI_FALSE;
    } catch (...) {
        return JNI_FALSE;
    }
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_aykerme_klarivision_core_NativeBridge_nativeLiveFinish(JNIEnv *, jclass, jlong handle) {
    try {
        auto *session = reinterpret_cast<kv_production_pitch_session *>(handle);
        if (session == nullptr) {
            return 0;
        }
        return static_cast<jlong>(kv_production_pitch_session_finish(session));
    } catch (...) {
        return 0;
    }
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_aykerme_klarivision_core_NativeBridge_nativeLiveOutputCount(
    JNIEnv *, jclass, jlong handle) {
    try {
        auto *session = reinterpret_cast<kv_production_pitch_session *>(handle);
        if (session == nullptr) {
            return 0;
        }
        return static_cast<jlong>(kv_production_pitch_session_output_count(session));
    } catch (...) {
        return 0;
    }
}

extern "C" JNIEXPORT jdoubleArray JNICALL
Java_com_aykerme_klarivision_core_NativeBridge_nativeLiveOutputFrame(
    JNIEnv *env, jclass, jlong handle, jlong index) {
    try {
        auto *session = reinterpret_cast<kv_production_pitch_session *>(handle);
        if (session == nullptr || index < 0) {
            return nullptr;
        }
        kv_pitch_frame frame{};
        if (kv_production_pitch_session_output_frame(session, static_cast<size_t>(index),
                                                       &frame) != 1) {
            return nullptr;
        }
        jdoubleArray result = env->NewDoubleArray(4);
        if (result == nullptr) {
            return nullptr;
        }
        const jdouble values[4] = {frame.time_seconds, frame.frequency_hz, frame.confidence,
                                    frame.voiced != 0 ? 1.0 : 0.0};
        env->SetDoubleArrayRegion(result, 0, 4, values);
        return result;
    } catch (...) {
        return nullptr;
    }
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_aykerme_klarivision_core_NativeBridge_nativeLiveLastError(
    JNIEnv *env, jclass, jlong handle) {
    try {
        auto *session = reinterpret_cast<kv_production_pitch_session *>(handle);
        if (session == nullptr) {
            return safe_new_string(env, "");
        }
        return safe_new_string(env, kv_production_pitch_session_last_error(session));
    } catch (...) {
        return safe_new_string(env, "");
    }
}

extern "C" JNIEXPORT void JNICALL
Java_com_aykerme_klarivision_core_NativeBridge_nativeLiveDestroy(JNIEnv *, jclass, jlong handle) {
    try {
        auto *session = reinterpret_cast<kv_production_pitch_session *>(handle);
        if (session != nullptr) {
            kv_production_pitch_session_destroy(session);
        }
    } catch (...) {
        // Yıkımda istisna yutulur: JNI sınırından geçmez, handle zaten Kotlin
        // tarafında sıfırlanmıştır.
    }
}

// --- Çevrimdışı (whole-file) oturum: kv_pitch_engine_* ------------------

extern "C" JNIEXPORT jlong JNICALL
Java_com_aykerme_klarivision_core_NativeBridge_nativeOfflineCreate(JNIEnv *, jclass, jint engine) {
    try {
        kv_pitch_engine *engine_handle =
            kv_pitch_engine_create(static_cast<int>(engine), KV_PROFILE_OFFLINE_TRACK);
        return reinterpret_cast<jlong>(engine_handle);
    } catch (...) {
        return 0;
    }
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_aykerme_klarivision_core_NativeBridge_nativeOfflinePush(
    JNIEnv *env, jclass, jlong handle, jobject buffer, jint sampleCount, jdouble sampleRateHz) {
    try {
        auto *engine = reinterpret_cast<kv_pitch_engine *>(handle);
        if (engine == nullptr || sampleCount < 0) {
            return JNI_FALSE;
        }
        const float *samples = direct_float_pointer(env, buffer);
        if (samples == nullptr) {
            return JNI_FALSE;
        }
        int ok = kv_pitch_engine_push(engine, samples, static_cast<size_t>(sampleCount),
                                       sampleRateHz);
        return ok == 1 ? JNI_TRUE : JNI_FALSE;
    } catch (...) {
        return JNI_FALSE;
    }
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_aykerme_klarivision_core_NativeBridge_nativeOfflineFinish(
    JNIEnv *, jclass, jlong handle) {
    try {
        auto *engine = reinterpret_cast<kv_pitch_engine *>(handle);
        if (engine == nullptr) {
            return 0;
        }
        // Tek bloklayıcı çağrı; kv_pitch_engine_set_progress bu P1a
        // katmanında bilinçli olarak bağlanmaz (bkz. OfflineTrackSession.kt).
        return static_cast<jlong>(kv_pitch_engine_finish(engine));
    } catch (...) {
        return 0;
    }
}

extern "C" JNIEXPORT jdoubleArray JNICALL
Java_com_aykerme_klarivision_core_NativeBridge_nativeOfflineFrame(
    JNIEnv *env, jclass, jlong handle, jlong index) {
    try {
        auto *engine = reinterpret_cast<kv_pitch_engine *>(handle);
        if (engine == nullptr || index < 0) {
            return nullptr;
        }
        kv_pitch_frame frame{};
        if (kv_pitch_engine_frame(engine, static_cast<size_t>(index), &frame) != 1) {
            return nullptr;
        }
        jdoubleArray result = env->NewDoubleArray(4);
        if (result == nullptr) {
            return nullptr;
        }
        const jdouble values[4] = {frame.time_seconds, frame.frequency_hz, frame.confidence,
                                    frame.voiced != 0 ? 1.0 : 0.0};
        env->SetDoubleArrayRegion(result, 0, 4, values);
        return result;
    } catch (...) {
        return nullptr;
    }
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_aykerme_klarivision_core_NativeBridge_nativeOfflineLastError(
    JNIEnv *env, jclass, jlong handle) {
    try {
        auto *engine = reinterpret_cast<kv_pitch_engine *>(handle);
        if (engine == nullptr) {
            return safe_new_string(env, "");
        }
        return safe_new_string(env, kv_pitch_engine_last_error(engine));
    } catch (...) {
        return safe_new_string(env, "");
    }
}

extern "C" JNIEXPORT void JNICALL
Java_com_aykerme_klarivision_core_NativeBridge_nativeOfflineDestroy(
    JNIEnv *, jclass, jlong handle) {
    try {
        auto *engine = reinterpret_cast<kv_pitch_engine *>(handle);
        if (engine != nullptr) {
            kv_pitch_engine_destroy(engine);
        }
    } catch (...) {
        // Yıkımda istisna yutulur: JNI sınırından geçmez.
    }
}
