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

    # frequency_viewer.py -- the graph page's own HTML/JS control UI. "Karar"
    # and "koma" stay unchanged in English by explicit product decision, as
    # do makam/perde/interval-name terms (Koma, Eksik bakiye, Bakiye, Küçük
    # mücennep, Büyük mücennep, Tanini, Artık ikili -- specialised Turkish
    # music theory names, same treatment as makam names). CSS classes/ids and
    # JS variable/function names are never touched -- only text nodes.
    "viewer-description": {
        "tr": "Pitch eğrisi pYIN'in ölçtüğü fiziksel frekanstır (Hz). Türk Müziği (Sol Klarnet) ekseni, koma miktarını taşınabilir biçimde gösterir: ör. Re ♭5, Fa ♯1. Ölçülen eğri değiştirilmez.",
        "en": "The pitch curve is the physical frequency (Hz) pYIN measured. The Turkish Music (Sol Clarinet) axis shows the koma amount in a portable way: e.g. Re ♭5, Fa ♯1. The measured curve is never altered.",
    },
    "viewer-layout-label": {"tr": "Yerleşim", "en": "Layout"},
    "viewer-layout-stacked": {"tr": "Üst üste", "en": "Stacked"},
    "viewer-layout-side": {"tr": "Video solda · yan yana", "en": "Video left · side by side"},
    "viewer-layout-side-right": {"tr": "Video sağda · yan yana", "en": "Video right · side by side"},
    "viewer-zoom-time-word": {"tr": "Zaman", "en": "Time"},
    "viewer-vertical-word": {"tr": "Dikey", "en": "Vertical"},
    "viewer-visible-duration-label": {"tr": "Görünür süre", "en": "Visible duration"},
    "viewer-seconds-unit": {"tr": "sn", "en": "sec"},
    "viewer-axis-label": {"tr": "Eksen", "en": "Axis"},
    "viewer-axis-turkish": {"tr": "Türk Müziği · Sol Klarnet", "en": "Turkish Music · Sol Clarinet"},
    # "major"/"minor" is a Western scale name, not a Turkish makam name --
    # translates, unlike the other axis options.
    "viewer-scale-major": {"tr": "Majör", "en": "Major"},
    "viewer-scale-minor": {"tr": "Minör", "en": "Minor"},
    "viewer-settings-button": {"tr": "Ayarlar", "en": "Settings"},
    "viewer-countdown-label": {"tr": "Geri sayım", "en": "Countdown"},
    "viewer-play-button": {"tr": "Oynat", "en": "Play"},
    "viewer-pause-button": {"tr": "Duraklat", "en": "Pause"},
    "viewer-cancel-countdown": {"tr": "İptal", "en": "Cancel"},
    "viewer-mark-b-end": {"tr": "Son", "en": "End"},
    "viewer-back-to-start": {"tr": "Başa dön", "en": "Back to start"},
    "viewer-scroll-legend": {
        "tr": "Tekerlek: imleç çevresinde zaman yakınlaştır · Shift+tekerlek: dikey yakınlaştır · sürükle: kayıtta gezin",
        "en": "Wheel: zoom time around cursor · Shift+wheel: zoom pitch · drag: navigate recording",
    },
    "viewer-vertical-scroll-aria": {"tr": "Dikey grafiği kaydır", "en": "Scroll the graph vertically"},
    "viewer-time-scroll-aria": {"tr": "Kayıtta gezin", "en": "Navigate in recording"},
    "viewer-scroll-note": {
        "tr": "Yatay çubuk kayıtta gezinir; sağdaki çubuk dikey merkezi değiştirir.",
        "en": "The horizontal bar navigates the recording; the bar on the right changes the vertical center.",
    },
    "viewer-koma-guide-summary": {"tr": "Koma rehberi", "en": "Koma guide"},
    "viewer-koma-guide-abbr": {"tr": "Rumuz", "en": "Abbr."},
    "viewer-koma-guide-interval": {"tr": "Aralık", "en": "Interval"},
    "viewer-koma-guide-koma": {"tr": "Koma", "en": "Koma"},
    "viewer-koma-guide-notation": {"tr": "Gösterim", "en": "Notation"},
    "viewer-settings-title": {"tr": "Ayarlar", "en": "Settings"},
    "viewer-settings-description": {
        "tr": "Makam aralıklarını, dikey eğri takibini ve çalma hızını buradan düzenleyebilirsin.",
        "en": "You can edit makam intervals, vertical curve following, and playback speed here.",
    },
    "viewer-vertical-follow-checkbox": {"tr": "Eğriyi dikey takip et", "en": "Follow curve vertically"},
    "viewer-playback-speed-label": {"tr": "Çalma hızı", "en": "Playback speed"},
    "viewer-makam-label": {"tr": "Makam", "en": "Makam"},
    "viewer-reset-to-theory": {"tr": "Teoriye dön", "en": "Reset to Theory"},
    "viewer-cancel-button": {"tr": "Vazgeç", "en": "Cancel"},
    "viewer-apply-button": {"tr": "Uygula", "en": "Apply"},
    "viewer-interval-word": {"tr": "Aralık", "en": "Interval"},
    "viewer-total-koma-prefix": {"tr": "Toplam:", "en": "Total:"},
    "viewer-appearance-heading": {"tr": "Görünüm", "en": "Appearance"},
    "viewer-theme-label": {"tr": "Tema ", "en": "Theme "},
    "viewer-theme-focus": {"tr": "Çalışma odaklı", "en": "Focus"},
    "viewer-theme-studio": {"tr": "Stüdyo", "en": "Studio"},
    "viewer-theme-classic": {"tr": "Sıcak klasik", "en": "Warm Classic"},
    "viewer-transport-aria": {"tr": "Oynatma ve A B Loop kontrolleri", "en": "Playback and A/B loop controls"},
    "viewer-mark-a-title": {"tr": "İmleçte A işaretini oluştur", "en": "Create mark A at cursor"},
    "viewer-mark-b-title": {"tr": "İmleçte B işaretini oluştur", "en": "Create mark B at cursor"},
    "viewer-loop-toggle-title": {"tr": "A ile B arasında döngü", "en": "Loop between A and B"},
    "viewer-graph-colors-heading": {"tr": "Grafik renkleri", "en": "Graph colors"},
    "viewer-pitch-curve-label": {"tr": "Pitch eğrisi", "en": "Pitch curve"},
    "viewer-note-guides-label": {"tr": "Nota kılavuzları", "en": "Note guides"},
    "viewer-mic-curve-label": {"tr": "Mikrofon eğrisi", "en": "Microphone curve"},
    "viewer-karar-tone-label": {"tr": "Karar sesi", "en": "Karar tone"},
    "viewer-reset-default-colors": {"tr": "Varsayılan renklere dön", "en": "Reset to default colors"},
    "viewer-study-heading": {"tr": "Çalışma", "en": "Study"},
    "viewer-frequency-description": {
        "tr": "Pitch eğrisi duyulan fiziksel frekansı (Hz) gösterir.",
        "en": "The pitch curve shows the sounding physical frequency (Hz).",
    },
    "viewer-starting-countdown-prefix": {"tr": "Başlıyor:", "en": "Starting:"},
    "viewer-video-preparing": {"tr": "Video hazırlanıyor…", "en": "Video preparing…"},
    "viewer-loop-min-duration": {
        "tr": "Loop için A ile B arasında en az 0,02 sn olmalı.",
        "en": "There must be at least 0.02 sec between A and B for a loop.",
    },
    # installTooltips() copy object
    "viewer-tooltip-zoom-in": {"tr": "Görünür zaman aralığını büyüt", "en": "Increase the visible time range"},
    "viewer-tooltip-zoom-out": {"tr": "Görünür zaman aralığını küçült", "en": "Decrease the visible time range"},
    "viewer-tooltip-window-seconds": {"tr": "Grafikte gösterilecek saniye sayısı", "en": "Number of seconds shown on the graph"},
    "viewer-tooltip-vertical-expand": {"tr": "Dikey görünümü genişlet", "en": "Expand the vertical view"},
    "viewer-tooltip-vertical-shrink": {"tr": "Dikey görünümü daralt", "en": "Shrink the vertical view"},
    "viewer-tooltip-scale-mode": {"tr": "Grafikteki makam veya dizi ekseni", "en": "The makam or scale axis on the graph"},
    "viewer-tooltip-tonic": {"tr": "Seçili karar sesi", "en": "Selected karar tone"},
    "viewer-tooltip-countdown": {"tr": "Oynatma öncesi geri sayım", "en": "Countdown before playback"},
    "viewer-tooltip-play-toggle": {"tr": "Medyayı oynat veya duraklat", "en": "Play or pause the media"},
    "viewer-tooltip-reset": {"tr": "Oynatmayı başa al", "en": "Rewind playback to start"},
    "viewer-tooltip-time-scroll": {"tr": "Kayıtta zamanda gezin", "en": "Navigate the recording timeline"},
    "viewer-tooltip-vertical-scroll": {"tr": "Grafiğin dikey merkezini değiştir", "en": "Change the graph vertical center"},
    "viewer-tooltip-makam-settings": {"tr": "Makam aralıklarını ve görünümü düzenle", "en": "Edit makam intervals and appearance"},
    # koma interval names (specialised Turkish music theory terminology, kept
    # unchanged in English -- same rule as makam/perde names)
    "koma-interval-1": {"tr": "F · Koma", "en": "F · Koma"},
    "koma-interval-3": {"tr": "E · Eksik bakiye", "en": "E · Eksik bakiye"},
    "koma-interval-4": {"tr": "B · Bakiye", "en": "B · Bakiye"},
    "koma-interval-5": {"tr": "S · Küçük mücennep", "en": "S · Küçük mücennep"},
    "koma-interval-8": {"tr": "K · Büyük mücennep", "en": "K · Büyük mücennep"},
    "koma-interval-9": {"tr": "T · Tanini", "en": "T · Tanini"},
    "koma-interval-12": {"tr": "A · Artık ikili", "en": "A · Artık ikili"},
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


def translate_js(key: str, lang: str | None = None, **kwargs: object) -> str:
    """Like `translate`, but escaped for embedding inside a single-quoted JS
    string literal in `frequency_viewer.py`'s generated page. A translation
    with an apostrophe (e.g. "the recording's timeline") would otherwise
    terminate the JS string early and throw a real, WKWebView-visible syntax
    error -- confirmed by the WKWebView harness in
    docs/app-store/... (see l10n verification notes) before this existed.
    """
    return translate(key, lang, **kwargs).replace("\\", "\\\\").replace("'", "\\'")


def engine_label(engine_id: str, lang: str | None = None) -> str:
    resolved_lang = lang if lang in SUPPORTED_LANGUAGES else get_language()
    entry = ENGINE_LABELS.get(engine_id)
    if entry is None:
        return engine_id
    return entry.get(resolved_lang, entry.get(DEFAULT_LANGUAGE, engine_id))
