package com.aykerme.klarivision.live

/**
 * Ses rotası değişikliği kararı.
 *
 * Swift kaynağı: `iPadLiveRouteChangeAction` (LiveModels.swift).
 */
sealed class RouteChangeAction {
    object ContinueCapturing : RouteChangeAction()
    data class Stop(val message: String) : RouteChangeAction()
}

/**
 * Rota değişikliği kararını AVAudioSession/AudioManager'dan bağımsız, SAF bir
 * fonksiyon olarak verir.
 *
 * Swift kaynağı: `iPadLiveRouteChangePolicy.action(reasonRawValue:expectedOwnCategoryChange:)`
 * (LiveModels.swift). Android karşılığında girdi, `AudioManager`/
 * `AudioDeviceCallback` tarafında gözlemlenen bir sebep koduna (Int) eşlenir —
 * ancak bu obje Android sınıflarını İÇE AKTARMAZ: yalnız Int sebep kodu ve
 * Boolean bayrak alır, böylece JVM birim testiyle (Android çalışma zamanı
 * olmadan) koşabilir.
 *
 * Sebep kodları, Swift tarafındaki `AVAudioSession.RouteChangeReason` ham
 * değerleriyle birebir eşlenir (çağıran taraf, kendi platform sebebini bu
 * tamsayı sözleşmesine çevirmekle yükümlüdür):
 *   1 = newDeviceAvailable
 *   2 = oldDeviceUnavailable
 *   3 = categoryChange
 *   4 = override
 *   6 = wakeFromSleep
 *   7 = noSuitableRouteForCategory
 *   8 = routeConfigurationChange
 */
object RouteChangePolicy {
    const val REASON_NEW_DEVICE_AVAILABLE = 1
    const val REASON_OLD_DEVICE_UNAVAILABLE = 2
    const val REASON_CATEGORY_CHANGE = 3
    const val REASON_OVERRIDE = 4
    const val REASON_WAKE_FROM_SLEEP = 6
    const val REASON_NO_SUITABLE_ROUTE_FOR_CATEGORY = 7
    const val REASON_ROUTE_CONFIGURATION_CHANGE = 8

    private const val GENERIC_STOP_MESSAGE = "Ses rotası değişti. Yeniden başlatmak için Başlat'a dokunun."
    private const val OLD_DEVICE_UNAVAILABLE_MESSAGE =
        "Mikrofon rotası kaldırıldı. Yeniden başlatmak için Başlat'a dokunun."
    private const val NO_SUITABLE_ROUTE_MESSAGE =
        "Mikrofon için uygun ses rotası bulunamadı. Yeniden başlatmak için Başlat'a dokunun."

    /**
     * @param reasonRawValue Platformun bildirdiği ham sebep kodu, ya da bilinmiyorsa/yoksa null.
     * @param expectedOwnCategoryChange Uygulamanın kendi başlattığı, beklenen bir kategori
     *   değişikliğinin (yeni başlatma sırasında setCategory çağrısının) sürmekte olup olmadığı.
     */
    fun action(reasonRawValue: Int?, expectedOwnCategoryChange: Boolean): RouteChangeAction {
        if (reasonRawValue == null) return RouteChangeAction.Stop(GENERIC_STOP_MESSAGE)
        return when (reasonRawValue) {
            REASON_CATEGORY_CHANGE ->
                if (expectedOwnCategoryChange) {
                    // setCategory, yeni bir başlatma sırasında motor kurulumu
                    // sonrasında bu bildirimi yayınlayabilir; yalnız bu
                    // sınırlı, açıkça izlenen bildirimi tüketiriz.
                    RouteChangeAction.ContinueCapturing
                } else {
                    RouteChangeAction.Stop(GENERIC_STOP_MESSAGE)
                }
            REASON_OVERRIDE ->
                // AVAudioSession'ın override sebebi yalnız çıkış portunu değiştirir.
                RouteChangeAction.ContinueCapturing
            REASON_OLD_DEVICE_UNAVAILABLE -> RouteChangeAction.Stop(OLD_DEVICE_UNAVAILABLE_MESSAGE)
            REASON_NO_SUITABLE_ROUTE_FOR_CATEGORY -> RouteChangeAction.Stop(NO_SUITABLE_ROUTE_MESSAGE)
            REASON_NEW_DEVICE_AVAILABLE,
            REASON_WAKE_FROM_SLEEP,
            REASON_ROUTE_CONFIGURATION_CHANGE,
            -> RouteChangeAction.Stop(GENERIC_STOP_MESSAGE)
            else -> RouteChangeAction.Stop(GENERIC_STOP_MESSAGE)
        }
    }
}
