// KlariVision Android — gerçek zaman çarpanı (RTF) ölçümü.
//
// Bu bir kabul testi DEĞİL, bir ölçümdür: donanıma göre değişen sayılar
// ürettiği için eşiği yalnız çok gevşek bir "gerçek zamanın altında mı"
// kontrolüyle sınırlıdır. Asıl çıktı loglanan p50/p95/max değerleridir.
//
// Gerekçe: masaüstünde `pyin_ladder.cpp` içindeki iç çarpım `vDSP_dotpr`
// ile hızlandırılır; Android'de Accelerate yoktur ve skaler `#else` yolu
// çalışır (bkz. core/src/pyin_ladder.cpp). Bu, portun bilinen tek sıcak
// noktasıdır — masaüstü RTF rakamları Android kabulü sayılmaz.

package com.aykerme.klarivision.core

import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlin.math.PI
import kotlin.math.sin
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class RealtimeFactorBenchmark {

    private companion object {
        const val TAG = "KlariVisionRTF"
        const val SAMPLE_RATE = 48_000.0
        const val WINDOW_SIZE = 1536
        const val HOP_SIZE = 512
        const val TARGET_FREQUENCY = 440.0

        /** Ölçülecek kaynak süresi (saniye). */
        const val DURATION_SECONDS = 20.0
    }

    /** Tek bir analiz penceresi; ardışık pencereler hop kadar ilerler. */
    private fun window(startSample: Long): java.nio.FloatBuffer {
        val buffer = ByteBuffer.allocateDirect(WINDOW_SIZE * 4)
            .order(ByteOrder.nativeOrder())
            .asFloatBuffer()
        for (i in 0 until WINDOW_SIZE) {
            val t = (startSample + i) / SAMPLE_RATE
            // Klarnet benzeri tek sayılı harmonikler — düz sinüsten daha
            // gerçekçi bir iş yükü verir (harmonik kanıt katmanı çalışır).
            val s = sin(2.0 * PI * TARGET_FREQUENCY * t) +
                0.5 * sin(2.0 * PI * 3 * TARGET_FREQUENCY * t) +
                0.25 * sin(2.0 * PI * 5 * TARGET_FREQUENCY * t)
            buffer.put((s * 0.3).toFloat())
        }
        buffer.flip()
        return buffer
    }

    @Test
    fun canliYolGercekZamanCarpani() {
        val session = LivePitchSession.create()
        val perWindowNanos = mutableListOf<Long>()
        try {
            val totalHops = (DURATION_SECONDS * SAMPLE_RATE / HOP_SIZE).toInt()

            // Isınma: JIT, sayfa hataları ve ilk tahsisler ölçüme girmesin.
            repeat(32) { i -> session.process(window(i.toLong() * HOP_SIZE), i * HOP_SIZE / SAMPLE_RATE) }
            session.reset()

            for (i in 0 until totalHops) {
                val startSample = i.toLong() * HOP_SIZE
                val buf = window(startSample)
                val sourceTime = (startSample + WINDOW_SIZE / 2) / SAMPLE_RATE
                val t0 = System.nanoTime()
                session.process(buf, sourceTime)
                perWindowNanos += System.nanoTime() - t0
            }
            session.finish()
        } finally {
            session.close()
        }

        val sorted = perWindowNanos.sorted()
        val hopBudgetNanos = HOP_SIZE / SAMPLE_RATE * 1e9   // 512 / 48000 ≈ 10,67 ms
        fun pct(p: Double) = sorted[((sorted.size - 1) * p).toInt()]
        val totalNanos = perWindowNanos.sum()
        val rtf = totalNanos / (DURATION_SECONDS * 1e9)

        Log.i(TAG, "--- unified_v1 canlı yol, arm64, ${DURATION_SECONDS}s kaynak ---")
        Log.i(TAG, "pencere sayısı      : ${sorted.size}")
        Log.i(TAG, "hop bütçesi         : ${"%.3f".format(hopBudgetNanos / 1e6)} ms")
        Log.i(TAG, "pencere p50         : ${"%.3f".format(pct(0.50) / 1e6)} ms")
        Log.i(TAG, "pencere p95         : ${"%.3f".format(pct(0.95) / 1e6)} ms")
        Log.i(TAG, "pencere max         : ${"%.3f".format(sorted.last() / 1e6)} ms")
        Log.i(TAG, "RTF (toplam/kaynak) : ${"%.4f".format(rtf)}")
        Log.i(TAG, "hop bütçesi doluluğu: p50 %${"%.1f".format(pct(0.50) / hopBudgetNanos * 100)}" +
            ", p95 %${"%.1f".format(pct(0.95) / hopBudgetNanos * 100)}")

        // Çok gevşek kapı: gerçek zamanın altında kalmalı. Asıl değer loglarda.
        assert(rtf < 1.0) { "RTF $rtf — gerçek zamanın üstünde, canlı yol bu cihazda yetişmiyor" }
    }
}
