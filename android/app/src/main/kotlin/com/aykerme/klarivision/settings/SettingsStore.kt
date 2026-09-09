// KlariVision Android — DataStore Preferences ayarlar sarmalayıcısı.
// Okuma Flow aracılığıyla, yazma suspend fonksiyonlarıyla. Geçersiz
// kalıcı değerler varsayılan/clamp'e düşer, hiçbir zaman çökmez.

package com.aykerme.klarivision.settings

import android.content.Context
import androidx.datastore.preferences.core.Preferences
import androidx.datastore.preferences.core.doublePreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map

private val Context.settingsDataStore by preferencesDataStore(name = "klarivision_settings")

/**
 * KlariVision Android uygulaması için ayarlar deposu.
 * DataStore Preferences'i sarmalamış ve tüm okuma/yazma işlemlerini merkezi hale getiren.
 *
 * Okuma: Flow<T> aracılığıyla collector modeli
 * Yazma: suspend fonksiyonları aracılığıyla
 *
 * Kalıcı değerlerin doğrulanması otomatiktir; geçersiz değerler
 * varsayılana veya clamp'lenmiş değere düşer.
 */
class SettingsStore(private val context: Context) {
    private val dataStore = context.settingsDataStore

    // ==================== Pitch Motor Tercihlerine ====================

    fun studyPitchEngine(): Flow<String> = dataStore.data.map { preferences ->
        SettingsValidation.validateEngine(
            preferences[stringPreferencesKey(SettingsKeys.STUDY_PITCH_ENGINE)]
        )
    }

    suspend fun setStudyPitchEngine(engine: String) {
        dataStore.edit { preferences ->
            preferences[stringPreferencesKey(SettingsKeys.STUDY_PITCH_ENGINE)] =
                SettingsValidation.validateEngine(engine)
        }
    }

    fun livePitchEngine(): Flow<String> = dataStore.data.map { preferences ->
        SettingsValidation.validateEngine(
            preferences[stringPreferencesKey(SettingsKeys.LIVE_PITCH_ENGINE)]
        )
    }

    suspend fun setLivePitchEngine(engine: String) {
        dataStore.edit { preferences ->
            preferences[stringPreferencesKey(SettingsKeys.LIVE_PITCH_ENGINE)] =
                SettingsValidation.validateEngine(engine)
        }
    }

    // ==================== Tema ====================

    fun theme(): Flow<String> = dataStore.data.map { preferences ->
        SettingsValidation.validateTheme(
            preferences[stringPreferencesKey(SettingsKeys.THEME)]
        )
    }

    suspend fun setTheme(theme: String) {
        dataStore.edit { preferences ->
            preferences[stringPreferencesKey(SettingsKeys.THEME)] =
                SettingsValidation.validateTheme(theme)
        }
    }

    // ==================== Canlı Sinyal Kapısı ====================

    fun liveSignalGateDbFS(): Flow<Double> = dataStore.data.map { preferences ->
        SettingsValidation.clampGate(
            preferences[doublePreferencesKey(SettingsKeys.LIVE_SIGNAL_GATE_DBFS)]
                ?: SettingsKeys.LIVE_SIGNAL_GATE_DBFS_DEFAULT
        )
    }

    suspend fun setLiveSignalGateDbFS(dbFS: Double) {
        dataStore.edit { preferences ->
            preferences[doublePreferencesKey(SettingsKeys.LIVE_SIGNAL_GATE_DBFS)] =
                SettingsValidation.clampGate(dbFS)
        }
    }

    fun liveSignalGateRMS(): Flow<Double> = dataStore.data.map { preferences ->
        val dbFS = preferences[doublePreferencesKey(SettingsKeys.LIVE_SIGNAL_GATE_DBFS)]
            ?: SettingsKeys.LIVE_SIGNAL_GATE_DBFS_DEFAULT
        SettingsValidation.rmsForDbFs(dbFS)
    }

    // ==================== Grafik Renkleri ====================

    fun graphPitchColor(): Flow<String> = dataStore.data.map { preferences ->
        SettingsValidation.validateColor(
            preferences[stringPreferencesKey(SettingsKeys.GRAPH_PITCH_COLOR)],
            SettingsKeys.GRAPH_PITCH_COLOR_DEFAULT
        )
    }

    suspend fun setGraphPitchColor(color: String) {
        dataStore.edit { preferences ->
            preferences[stringPreferencesKey(SettingsKeys.GRAPH_PITCH_COLOR)] =
                SettingsValidation.validateColor(color, SettingsKeys.GRAPH_PITCH_COLOR_DEFAULT)
        }
    }

    fun graphGuideColor(): Flow<String> = dataStore.data.map { preferences ->
        SettingsValidation.validateColor(
            preferences[stringPreferencesKey(SettingsKeys.GRAPH_GUIDE_COLOR)],
            SettingsKeys.GRAPH_GUIDE_COLOR_DEFAULT
        )
    }

    suspend fun setGraphGuideColor(color: String) {
        dataStore.edit { preferences ->
            preferences[stringPreferencesKey(SettingsKeys.GRAPH_GUIDE_COLOR)] =
                SettingsValidation.validateColor(color, SettingsKeys.GRAPH_GUIDE_COLOR_DEFAULT)
        }
    }

    fun graphKararColor(): Flow<String> = dataStore.data.map { preferences ->
        SettingsValidation.validateColor(
            preferences[stringPreferencesKey(SettingsKeys.GRAPH_KARAR_COLOR)],
            SettingsKeys.GRAPH_KARAR_COLOR_DEFAULT
        )
    }

    suspend fun setGraphKararColor(color: String) {
        dataStore.edit { preferences ->
            preferences[stringPreferencesKey(SettingsKeys.GRAPH_KARAR_COLOR)] =
                SettingsValidation.validateColor(color, SettingsKeys.GRAPH_KARAR_COLOR_DEFAULT)
        }
    }

    // ==================== 53-Koma Sistem ====================

    fun komaIntervals53(): Flow<List<Int>> = dataStore.data.map { preferences ->
        // DataStore tek bir string anahtarında JSON/serialized list tutamayacağından,
        // 12 ayrı anahtar kullanarak depolanır.
        val intervals = mutableListOf<Int>()
        for (i in 0..11) {
            val key = stringPreferencesKey("${SettingsKeys.KOMA_INTERVALS_53}[$i]")
            val value = preferences[key]?.toIntOrNull()
            intervals.add(value ?: SettingsKeys.KOMA_INTERVALS_53_DEFAULT[i])
        }
        // Doğrula ve varsayılana dön gereken ise
        SettingsValidation.sanitizeKomaIntervals(intervals)
    }

    suspend fun setKomaIntervals53(intervals: List<Int>) {
        if (!SettingsValidation.validateKomaIntervals(intervals)) return  // Geçersiz, yazma
        dataStore.edit { preferences ->
            for ((i, value) in intervals.withIndex()) {
                val key = stringPreferencesKey("${SettingsKeys.KOMA_INTERVALS_53}[$i]")
                preferences[key] = value.toString()
            }
        }
    }

    // ==================== Makam Koma Aralıkları ====================

    fun makamKomaIntervals(makamName: String): Flow<List<Int>> = dataStore.data.map { preferences ->
        if (!SettingsKeys.EDITABLE_MAKAMS.contains(makamName)) {
            return@map SettingsValidation.defaultIntervalsForMakam(makamName)
        }

        val intervals = mutableListOf<Int>()
        for (i in 0..6) {  // 7 aralık
            val key = stringPreferencesKey("${SettingsKeys.MAKAM_KOMA_INTERVALS}[${makamName}][$i]")
            val value = preferences[key]?.toIntOrNull()
            val default = SettingsValidation.defaultIntervalsForMakam(makamName)
            intervals.add(value ?: (if (i < default.size) default[i] else 1))
        }

        // Doğrula ve varsayılana dön gereken ise
        if (SettingsValidation.validateMakamIntervals(intervals)) intervals else
            SettingsValidation.defaultIntervalsForMakam(makamName)
    }

    suspend fun setMakamKomaIntervals(makamName: String, intervals: List<Int>) {
        if (!SettingsKeys.EDITABLE_MAKAMS.contains(makamName)) return  // Ayarlanabilir değil
        if (!SettingsValidation.validateMakamIntervals(intervals)) return  // Geçersiz

        dataStore.edit { preferences ->
            for ((i, value) in intervals.withIndex()) {
                val key = stringPreferencesKey("${SettingsKeys.MAKAM_KOMA_INTERVALS}[${makamName}][$i]")
                preferences[key] = value.toString()
            }
        }
    }

    suspend fun resetMakamKomaIntervals(makamName: String) {
        if (!SettingsKeys.EDITABLE_MAKAMS.contains(makamName)) return

        dataStore.edit { preferences ->
            for (i in 0..6) {
                val key = stringPreferencesKey("${SettingsKeys.MAKAM_KOMA_INTERVALS}[${makamName}][$i]")
                preferences.remove(key)
            }
        }
    }

    // ==================== Makam Seçimi (Canlı Mod) ====================

    fun liveMakam(): Flow<String> = dataStore.data.map { preferences ->
        SettingsValidation.validateMakam(
            preferences[stringPreferencesKey(SettingsKeys.LIVE_MAKAM)]
        )
    }

    suspend fun setLiveMakam(makam: String) {
        dataStore.edit { preferences ->
            preferences[stringPreferencesKey(SettingsKeys.LIVE_MAKAM)] =
                SettingsValidation.validateMakam(makam)
        }
    }

    // ==================== Karar Seçimi (Tonal Merkez) ====================

    fun liveKarar(): Flow<String> = dataStore.data.map { preferences ->
        SettingsValidation.validateKarar(
            preferences[stringPreferencesKey(SettingsKeys.LIVE_KARAR)]
        )
    }

    suspend fun setLiveKarar(karar: String) {
        dataStore.edit { preferences ->
            preferences[stringPreferencesKey(SettingsKeys.LIVE_KARAR)] =
                SettingsValidation.validateKarar(karar)
        }
    }

    // ==================== Ölçek Gösterimi Modu ====================

    fun liveScaleDisplay(): Flow<String> = dataStore.data.map { preferences ->
        SettingsValidation.validateScaleDisplay(
            preferences[stringPreferencesKey(SettingsKeys.LIVE_SCALE_DISPLAY)]
        )
    }

    suspend fun setLiveScaleDisplay(mode: String) {
        dataStore.edit { preferences ->
            preferences[stringPreferencesKey(SettingsKeys.LIVE_SCALE_DISPLAY)] =
                SettingsValidation.validateScaleDisplay(mode)
        }
    }

    // ==================== Birlikte Çal Modu Ayarları ====================

    fun togetherMicAlignmentMs(): Flow<Double> = dataStore.data.map { preferences ->
        SettingsValidation.clampMicAlignmentMs(
            preferences[doublePreferencesKey(SettingsKeys.TOGETHER_MIC_ALIGNMENT_MS)]
                ?: SettingsKeys.TOGETHER_MIC_ALIGNMENT_MS_DEFAULT
        )
    }

    suspend fun setTogetherMicAlignmentMs(valueMs: Double) {
        dataStore.edit { preferences ->
            preferences[doublePreferencesKey(SettingsKeys.TOGETHER_MIC_ALIGNMENT_MS)] =
                SettingsValidation.clampMicAlignmentMs(valueMs)
        }
    }

    fun graphMicColor(): Flow<String> = dataStore.data.map { preferences ->
        SettingsValidation.validateColor(
            preferences[stringPreferencesKey(SettingsKeys.GRAPH_MIC_COLOR)],
            SettingsKeys.GRAPH_MIC_COLOR_DEFAULT
        )
    }

    suspend fun setGraphMicColor(color: String) {
        dataStore.edit { preferences ->
            preferences[stringPreferencesKey(SettingsKeys.GRAPH_MIC_COLOR)] =
                SettingsValidation.validateColor(color, SettingsKeys.GRAPH_MIC_COLOR_DEFAULT)
        }
    }
}
