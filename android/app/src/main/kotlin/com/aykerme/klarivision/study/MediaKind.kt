// KlariVision Android — içe aktarılan medyanın ses mi görüntü mü olduğunu ayırt eder.
// Study.isVideoSource ile aynı uzantı kümesini kullanır, tek bir yerde tutulur.

package com.aykerme.klarivision.study

/**
 * Sandbox'a kopyalanan bir dosyanın türü. `Study.isVideoSource`'un kullandığı
 * uzantı kümesiyle (mp4/mov/m4v/mpeg4 → video) tutarlı tutulur.
 */
enum class MediaKind {
    AUDIO,
    VIDEO;

    /** Ne uzantı ne de MIME türünden gerçek bir uzantı türetilebildiğinde kullanılacak varsayılan. */
    val defaultExtension: String
        get() = when (this) {
            AUDIO -> "m4a"
            VIDEO -> "mp4"
        }

    companion object {
        // Study.isVideoSource'daki kümeyle birebir aynı.
        private val VIDEO_EXTENSIONS = setOf("mp4", "mov", "m4v", "mpeg4")
        private val AUDIO_EXTENSIONS = setOf(
            "mp3", "wav", "m4a", "aac", "flac", "ogg", "opus", "3gp", "amr", "wma", "caf"
        )

        /** Dosya adı/uzantısından tür türetir; tanınmayan bir uzantı için null döner. */
        fun fromExtension(extension: String): MediaKind? = when (extension.lowercase()) {
            in VIDEO_EXTENSIONS -> VIDEO
            in AUDIO_EXTENSIONS -> AUDIO
            else -> null
        }

        /** ContentResolver.getType()'ın döndürdüğü MIME türünden tür türetir. */
        fun fromMimeType(mimeType: String?): MediaKind? = when {
            mimeType == null -> null
            mimeType.startsWith("video/") -> VIDEO
            mimeType.startsWith("audio/") -> AUDIO
            else -> null
        }
    }
}
