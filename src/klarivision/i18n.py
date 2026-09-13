"""Küçük, bağımlılıksız iki dilli (tr/en) mesaj sözlüğü.

Swift katmanı kullanıcının çözdüğü arayüz dilini (`Bundle.main.preferredLocalizations`
/ SwiftPM'de `Bundle.module`) motora `--lang tr|en` argümanıyla verir; bu modül
o kodu okuyup ilerleme/hata metinlerini ve grafik sayfası başlıklarını seçer.

Yalnız bu dosyada tutulan sabit bir sözlük -- `gettext`/`babel` gibi harici bir
bağımlılık eklenmez (bkz. docs/app-store/localization-inventory.md, F.2).
Anahtarlar makine tarafından üretilmez; her çağıran taraf hangi anahtarı
kullandığını doğrudan bilir, bu yüzden eksik bir çeviri sessizce anahtarın
kendisini (Türkçe kaynak metni) döndürür.
"""

from __future__ import annotations

SUPPORTED_LANGUAGES = ("tr", "en")
DEFAULT_LANGUAGE = "tr"

_CURRENT_LANGUAGE = DEFAULT_LANGUAGE

# key -> {"tr": ..., "en": ...}. Değer bir `str.format` şablonu olabilir.
_MESSAGES: dict[str, dict[str, str]] = {
    "invalid-byte-range": {
        "tr": "Geçersiz byte aralığı.",
        "en": "Invalid byte range.",
    },
    "unsatisfiable-byte-range": {
        "tr": "Karşılanamayan byte aralığı.",
        "en": "Unsatisfiable byte range.",
    },
    "invalid-internet-connection": {
        "tr": "Geçerli bir internet bağlantısı gir.",
        "en": "Provide a valid internet connection.",
    },
    "media-from-link-failed": {
        "tr": "Bağlantıdan medya alınamadı: {error}",
        "en": "Media could not be extracted from link: {error}",
    },
    "media-from-link-failed-generic": {
        "tr": "Bağlantıdan medya alınamadı.",
        "en": "Media could not be extracted from link.",
    },
    "invalid-makam-or-karar": {
        "tr": "Geçersiz makam veya karar sesi seçimi.",
        "en": "Invalid makam or karar tone selection.",
    },
    "invalid-pitch-engine": {
        "tr": "Geçersiz pitch motoru seçimi.",
        "en": "Invalid pitch engine selection.",
    },
    "invalid-recording-viewer": {
        "tr": "Geçersiz kayıt görünümü.",
        "en": "Invalid recording viewer.",
    },
    "saved-study-not-found": {
        "tr": "Kaydedilmiş çalışma bulunamadı.",
        "en": "Saved study not found.",
    },
    "audio-cache-not-found": {
        "tr": "Bu çalışma için ses önbelleği bulunamadı.",
        "en": "Audio cache not found for this study.",
    },
    "pitch-data-not-found": {
        "tr": "Bu çalışma için pitch verisi bulunamadı.",
        "en": "Pitch data not found for this study.",
    },
    "choose-portable-engine": {
        "tr": "Çalışma için taşınabilir bir C++ motor seç.",
        "en": "Choose a portable C++ engine for the study.",
    },
    "choose-video-or-audio": {
        "tr": "Lütfen bir video veya ses dosyası seç.",
        "en": "Please choose a video or audio file.",
    },
    "extension-not-recognized": {
        "tr": "Dosyanın uzantısı tanınamadı.",
        "en": "File extension not recognized.",
    },
    "analysis-failed": {
        "tr": "Analiz oluşturulamadı: {error}",
        "en": "Analysis could not be created: {error}",
    },
    "analysis-from-link-failed": {
        "tr": "Linkten analiz oluşturulamadı: {error}",
        "en": "Analysis from link could not be created: {error}",
    },
    "server-ready": {
        "tr": "KlariVision hazır: {url}",
        "en": "KlariVision ready: {url}",
    },
    "cli-source-required": {
        "tr": "Bir ses/video dosyası veya --refresh-viewer gerekli.",
        "en": "An audio/video file or --refresh-viewer is required.",
    },
    "cached-analysis-used": {
        "tr": "Önceki pitch analizi kullanıldı.",
        "en": "Previous pitch analysis was used.",
    },
    "new-analysis-created": {
        "tr": "Yeni pitch analizi oluşturuldu.",
        "en": "New pitch analysis created.",
    },
    "viewer-title-frequency": {
        "tr": "Duyulan frekans",
        "en": "Sounding Frequency",
    },
    "viewer-title-contour": {
        "tr": "Pitch konturu",
        "en": "Pitch Contour",
    },
    "viewer-new-recording": {
        "tr": "Yeni video / ses seç",
        "en": "Choose new video / audio",
    },
    "viewer-audio-recording": {
        "tr": "Ses kaydı",
        "en": "Audio recording",
    },
    "viewer-engine-prefix": {
        "tr": "Motor: {engine}",
        "en": "Engine: {engine}",
    },
    "pitch-data-not-found-for-engine": {
        "tr": "Seçilen {engine} motoru için pitch verisi bulunamadı: {file}",
        "en": "Pitch data not found for the selected {engine} engine: {file}",
    },
    "cached-analysis-used-and-refreshed": {
        "tr": "Önceki pitch analizi kullanıldı. Arayüz güncellendi.",
        "en": "Previous pitch analysis was used. Interface refreshed.",
    },
    "default-engine-used-and-refreshed": {
        "tr": "Varsayılan {engine} motoru kullanıldı. Arayüz güncellendi.",
        "en": "Default {engine} engine was used. Interface refreshed.",
    },
    "cpp-track-in-use": {
        "tr": "{engine} C++ çalışma eğrisi kullanılıyor.",
        "en": "Using the {engine} C++ study curve.",
    },
    "uploading-file": {
        "tr": "Dosya yükleniyor…",
        "en": "Uploading file…",
    },
    "running-analysis-or-cache": {
        "tr": "Pitch analizi yapılıyor veya cache kontrol ediliyor…",
        "en": "Running pitch analysis or checking cache…",
    },
}

# Motor kimliği -> arayüz etiketi. D-039 ile kaldırılan dört motorun etiketi,
# o motorla üretilmiş eski bir çalışma yeniden açıldığında doğru kalsın diye
# korunuyor (bkz. frequency_viewer.py).
ENGINE_LABELS: dict[str, dict[str, str]] = {
    "unified_v1": {"tr": "Birleşik (Unified v1)", "en": "Unified (Unified v1)"},
    "yin_v1": {"tr": "YIN v1 (kaldırıldı)", "en": "YIN v1 (removed)"},
    "pitch_engine_v2": {"tr": "Pitch Engine v2 (kaldırıldı)", "en": "Pitch Engine v2 (removed)"},
    "vpm_like": {"tr": "VPM-benzeri (kaldırıldı)", "en": "VPM-like (removed)"},
    "hapt_v1": {"tr": "Harmonik-Faz (HAPT) (kaldırıldı)", "en": "Harmonic-Phase (HAPT) (removed)"},
    "vamp": {"tr": "Vamp pYIN (referans)", "en": "Vamp pYIN (reference)"},
    "python": {"tr": "librosa pYIN (geliştirme)", "en": "librosa pYIN (development)"},
}


def set_language(lang: str | None) -> str:
    """Süreç genelindeki mevcut dili ayarlar; tanınmayan/`None` değer `tr`'a düşer."""
    global _CURRENT_LANGUAGE
    _CURRENT_LANGUAGE = lang if lang in SUPPORTED_LANGUAGES else DEFAULT_LANGUAGE
    return _CURRENT_LANGUAGE


def get_language() -> str:
    return _CURRENT_LANGUAGE


def translate(key: str, lang: str | None = None, **kwargs: object) -> str:
    """`key` için `lang` (verilmezse mevcut süreç dili) çevirisini döndürür.

    Bilinmeyen bir `key` ya da dil, anahtarın kendisini (hata ayıklamayı
    kolaylaştırmak için) döndürür -- sessizce çökmez.
    """
    resolved_lang = lang if lang in SUPPORTED_LANGUAGES else get_language()
    entry = _MESSAGES.get(key)
    if entry is None:
        return key
    template = entry.get(resolved_lang, entry.get(DEFAULT_LANGUAGE, key))
    if kwargs:
        try:
            return template.format(**kwargs)
        except (KeyError, IndexError):
            return template
    return template


def engine_label(engine_id: str, lang: str | None = None) -> str:
    resolved_lang = lang if lang in SUPPORTED_LANGUAGES else get_language()
    entry = ENGINE_LABELS.get(engine_id)
    if entry is None:
        return engine_id
    return entry.get(resolved_lang, entry.get(DEFAULT_LANGUAGE, engine_id))
