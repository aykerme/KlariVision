package com.aykerme.klarivision.core

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.math.abs

/**
 * C ABI v1 kontratını test et: `kv_pitch_contract_get_v1` tarafından
 * döndürülen değerler beklenenleriyle birebir eşleşmeliydi. Bu testler
 * yapı (compile) zamanında, donanım/emülatörde çalışır ve sözleşmenin
 * değişmediğini doğrular.
 */
@RunWith(AndroidJUnit4::class)
class PitchContractTest {

    @Test
    fun kontratYükleniyor() {
        // PitchContract.load(), sözleşmeyi çağırır ve başarısızsa
        // PitchAbiException.ContractMismatch fırlatır. Buraya ulaşmak
        // başarılı demektir.
        val contract = PitchContract.load()
        assert(contract != null)
    }

    @Test
    fun abiSürümüBeş() {
        val contract = PitchContract.load()
        assert(contract.abiVersion == 1) {
            "ABI sürümü 1 olmalı, ${contract.abiVersion} bulundu"
        }
    }

    @Test
    fun örneklemehızı48kHz() {
        val contract = PitchContract.load()
        assert(contract.sampleRateHz == 48_000) {
            "Örnekleme hızı 48000 Hz olmalı, ${contract.sampleRateHz} bulundu"
        }
    }

    @Test
    fun pencereBoyutu1536() {
        val contract = PitchContract.load()
        assert(contract.windowSize == 1_536) {
            "Pencere boyutu 1536 olmalı, ${contract.windowSize} bulundu"
        }
    }

    @Test
    fun hopBoyutu512() {
        val contract = PitchContract.load()
        assert(contract.hopSize == 512) {
            "Hop boyutu 512 olmalı, ${contract.hopSize} bulundu"
        }
    }

    @Test
    fun varsayılanMinimumRms0Nokta015() {
        val contract = PitchContract.load()
        val expected = 0.015
        val tolerance = 1e-9
        assert(abs(contract.defaultMinimumRms - expected) < tolerance) {
            "Varsayılan minimum RMS 0.015 olmalı, ${contract.defaultMinimumRms} bulundu"
        }
    }

    @Test
    fun yeterinceLagKareleri() {
        // kv_unified_lag_frames, hop cinsinden karar gecikmesini döner.
        // unified_v1 için bu 8'dir (unified_pitch_constants.hpp'de).
        val lagFrames = PitchContract.unifiedLagFrames()
        assert(lagFrames == 8) {
            "Unified v1 karar gecikmesi 8 hop olmalı, $lagFrames bulundu"
        }
    }

    @Test
    fun yeterincRealtimeProfiliBiti() {
        val contract = PitchContract.load()
        // KV_CAP_PROFILE_REALTIME = 1u << 3 = 8
        val realtimeBit = 1 shl 3
        val hasRealtimeBit = (contract.capabilities and realtimeBit) != 0
        assert(hasRealtimeBit) {
            "Capability bitleri PROFILE_REALTIME (bit 3) içermeli, " +
                "capabilities=0x${contract.capabilities.toString(16)}"
        }
    }

    @Test
    fun yeterincOfflineTrackProfiliBiti() {
        val contract = PitchContract.load()
        // KV_CAP_PROFILE_OFFLINE_TRACK_V1 = 1u << 4 = 16
        val offlineTrackBit = 1 shl 4
        val hasOfflineTrackBit = (contract.capabilities and offlineTrackBit) != 0
        assert(hasOfflineTrackBit) {
            "Capability bitleri PROFILE_OFFLINE_TRACK_V1 (bit 4) içermeli, " +
                "capabilities=0x${contract.capabilities.toString(16)}"
        }
    }

    @Test
    fun yeterincKaynakZamanlarıBiti() {
        val contract = PitchContract.load()
        // KV_CAP_SOURCE_TIMESTAMPS = 1u << 5 = 32
        val sourceTimestampsBit = 1 shl 5
        val hasSourceTimestampsBit = (contract.capabilities and sourceTimestampsBit) != 0
        assert(hasSourceTimestampsBit) {
            "Capability bitleri SOURCE_TIMESTAMPS (bit 5) içermeli, " +
                "capabilities=0x${contract.capabilities.toString(16)}"
        }
    }

    @Test
    fun yeterincUnifiedMotorBiti() {
        val contract = PitchContract.load()
        // KV_CAP_ENGINE_UNIFIED_V1 = 1u << 8 = 256
        val unifiedBit = 1 shl 8
        val hasUnifiedBit = (contract.capabilities and unifiedBit) != 0
        assert(hasUnifiedBit) {
            "Capability bitleri ENGINE_UNIFIED_V1 (bit 8) içermeli, " +
                "capabilities=0x${contract.capabilities.toString(16)}"
        }
    }

    @Test
    fun tümBitleriYerinde() {
        val contract = PitchContract.load()
        // Tüm dört biti kontrol et (realtime, offline_track, source_timestamps, unified_v1)
        val realtimeBit = 1 shl 3       // 8
        val offlineTrackBit = 1 shl 4   // 16
        val sourceTimestampsBit = 1 shl 5  // 32
        val unifiedBit = 1 shl 8        // 256
        val expectedBits = realtimeBit or offlineTrackBit or sourceTimestampsBit or unifiedBit

        assert((contract.capabilities and expectedBits) == expectedBits) {
            "Tüm beklenen bitleri içermeli: 0x${expectedBits.toString(16)}, " +
                "alınan: 0x${contract.capabilities.toString(16)}"
        }
    }
}
