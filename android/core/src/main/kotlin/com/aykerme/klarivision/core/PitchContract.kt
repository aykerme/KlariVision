package com.aykerme.klarivision.core

/**
 * `kv_pitch_contract_v1`'in Kotlin yansıması. `iPadPitchABIAdapter.contract()`
 * (PitchABIAdapter.swift) ile BİREBİR aynı sert doğrulamayı uygular: ABI
 * sürümü/örnekleme hızı/pencere/hop boyutu beklenenden farklıysa
 * `kv_pitch_contract_get_v1` 1 dönse bile hata fırlatılır.
 *
 * Bu port yalnız KV_ENGINE_UNIFIED_V1 (4) motorunu kullanır; 0-3 kimlikleri
 * (D-039 ile kaldırılan motorlar) rezervedir ve bu katmandan hiç seçilmez.
 */
data class PitchContract(
    val abiVersion: Int,
    val capabilities: Int,
    val sampleRateHz: Int,
    val windowSize: Int,
    val hopSize: Int,
    val defaultMinimumRms: Double,
) {
    companion object {
        const val EXPECTED_ABI_VERSION: Int = 1
        const val EXPECTED_SAMPLE_RATE_HZ: Int = 48_000
        const val EXPECTED_WINDOW_SIZE: Int = 1_536
        const val EXPECTED_HOP_SIZE: Int = 512

        /**
         * `kv_pitch_contract_get_v1`'i çağırır ve mobil ABI v1 sözleşmesini
         * doğrular. Sözleşme okunamazsa ya da beklenen sabitlerle
         * uyuşmuyorsa [PitchAbiException.ContractMismatch] fırlatılır —
         * sessiz kabul yoktur.
         */
        fun load(): PitchContract {
            val raw = NativeBridge.nativeGetContract()
                ?: throw PitchAbiException.ContractMismatch(
                    "Pitch çekirdeği mobil ABI v1 sözleşmesiyle uyuşmuyor."
                )
            val contract = PitchContract(
                abiVersion = raw[0].toInt(),
                capabilities = raw[1].toInt(),
                sampleRateHz = raw[2].toInt(),
                windowSize = raw[3].toInt(),
                hopSize = raw[4].toInt(),
                defaultMinimumRms = raw[5],
            )
            val valid = contract.abiVersion == EXPECTED_ABI_VERSION &&
                contract.sampleRateHz == EXPECTED_SAMPLE_RATE_HZ &&
                contract.windowSize == EXPECTED_WINDOW_SIZE &&
                contract.hopSize == EXPECTED_HOP_SIZE
            if (!valid) {
                throw PitchAbiException.ContractMismatch(
                    "Pitch çekirdeği mobil ABI v1 sözleşmesiyle uyuşmuyor."
                )
            }
            return contract
        }

        /**
         * unified_v1'in kendi karar gecikmesi (hop cinsinden). Bilinçli
         * olarak `load().v2_fixed_lag_frames`'ten AYRI tutulur: o alan
         * kv_pitch_contract_v1'in dondurulmuş, pitch_engine_v2'ye ait bir
         * kalıntısıdır ve yeni bir motor için asla değiştirilemez (bkz.
         * kv_unified_lag_frames, analysis_engine_c.h).
         */
        fun unifiedLagFrames(): Int = NativeBridge.nativeUnifiedLagFrames().toInt()
    }
}

/**
 * Bu port için tek geçerli motor kimliği. analysis_engine_c.h'de 0-3
 * rezervedir (D-039 ile kaldırılan motorlar); Android katmanı bunları hiç
 * göstermez ve hiç seçmez.
 */
internal object PitchEngine {
    const val UNIFIED_V1: Int = 4
}
