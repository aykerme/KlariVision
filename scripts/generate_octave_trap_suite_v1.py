#!/usr/bin/env python3
"""Oktav hatası tuzak seti: tek monoton temel üzerinde bütün hata sebepleri.

docs/OktavHatasi-Arastirma-Raporu.pdf raporunda tespit edilen oktav / alt-harmonik
hata sebeplerinin her birini ayrı ayrı tetikleyen kontrollü bir set üretir.

Mevcut sentetik setlerden farkı: burada gerçek perde dosya boyunca 294 Hz'de sabit
kalır. Bir motor sapma raporluyorsa bu tartışmasız bir hatadır ve sebebi o an hangi
bölümün çaldığından okunur -- nota geçişi, register bölgesi ve spektral yapı aynı
anda değişmediği için değişkenler birbirine karışmaz.

294 Hz, kod tabanındaki dört ayrı eşiğin üstüne birden nişan alır:
  f/3 =  98,0 Hz -- 120 Hz perde tabanının altında (motor üretemez, dropout'a döner)
  f/2 = 147,0 Hz -- docs/TEST_BASELINE.md'nin hâlâ açık dediği 120-160 Hz zayıf bandı
  2f  = 588,0 Hz -- güvenli bölge
  3f  = 882,0 Hz -- kOctaveRecoveryFloorHz = 800 oktav-kurtarma eşiğinin üstünde

Bu set dondurulmuş bir holdout DEĞİLDİR; teşhis amaçlıdır ve yeniden ayarlanabilir.
data/benchmarks altındaki `frozen-no-retuning-after-first-result` politikalı turnuva
holdout'larıyla karıştırılmamalıdır.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import sys
from pathlib import Path

import numpy as np
import soundfile as sf

sys.path.insert(0, str(Path(__file__).resolve().parent))

from generate_pitch_tournament_holdout_v1 import (  # noqa: E402
    RATE,
    TRUTH_STEP,
    Holdout,
    add_interference,
    constant,
    curved_glide,
    room_variant,
    vibrato,
)


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUTPUT = ROOT / "data/benchmarks"
SEED = 20260905

# Monoton temel. Bütün bölümler bunun üzerinde çalışır.
BASE_HZ = 294.0

# Harmonik demetleri 2. harmonikten başlar (Holdout.add, enumerate(..., start=2)).
# Silindirik kapalı boru: çift harmonikler bastırılmış, tek harmonikler taşıyıcı.
KLARNET = (0.04, 0.62, 0.02, 0.28, 0.015, 0.13, 0.01, 0.07)
# Temel söndürme merdiveni için 3. harmonik sabit 1,00 tutulur.
MERDIVEN = (0.04, 1.00, 0.02, 0.30, 0.015, 0.14)
# Temeli hiç olmayan ton: yalnız 3f / 5f / 7f.
TEMELSIZ = (0.0, 1.00, 0.0, 0.42, 0.0, 0.20)
# Çift harmonikleri de güçlü tam seri: klarnet varsayımını bozar.
TAM_SERI = (0.85, 0.70, 0.55, 0.45, 0.35, 0.28, 0.22, 0.18)
# A(3f) / A(f) = 1,00 / 0,125 = 8,0 -> kOctaveDominanceRatio eşiğinin tam üstü.
BASKIN_UCUNCU = (0.0, 1.00, 0.0, 0.20)


class TrapSuite(Holdout):
    """Holdout'a iki şey ekler: doyum anahtarı ve bölüm başına tuzak meta verisi.

    Holdout.add() sinyale tanh(1,08x) yumuşak doyumu uygular. tanh tek simetrili bir
    doğrusalsızlık olduğu için 3f/5f/7f karışımından 2*3f - 5f = f fark tonunu üretir,
    yani olmayan temeli geri doğurur. Bu, gerçek bir kamışın yaptığı şeydir ve kendi
    başına ilginç bir bölümdür (S08) -- ama temeli hiç olmayan tonun saf hâlini (S07)
    ölçebilmek için kapatılabilmesi gerekir.
    """

    def add(  # type: ignore[override]
        self,
        label: str,
        frequencies: np.ndarray,
        *,
        kind: str,
        fundamental: np.ndarray | float = 1.0,
        amplitude: np.ndarray | float = 0.22,
        harmonics: tuple[float, ...] = KLARNET,
        saturate: bool = True,
        trap: dict[str, str] | None = None,
    ) -> None:
        count = len(frequencies)
        phase = 2 * np.pi * np.cumsum(frequencies) / RATE
        fundamental_array = np.full(count, fundamental) if np.isscalar(fundamental) else fundamental
        amplitude_array = np.full(count, amplitude) if np.isscalar(amplitude) else amplitude
        attack = min(round(0.011 * RATE), count // 6)
        release = min(round(0.019 * RATE), count // 6)
        envelope = np.ones(count)
        if attack:
            envelope[:attack] = np.sin(np.linspace(0, np.pi / 2, attack)) ** 2
        if release:
            envelope[-release:] = np.cos(np.linspace(0, np.pi / 2, release)) ** 2
        signal = fundamental_array * np.sin(phase + 0.07)
        for order, strength in enumerate(harmonics, start=2):
            signal += strength * np.sin(order * phase + 0.11 * order)
        shaped = np.tanh(1.08 * signal) / np.tanh(1.08) if saturate else signal
        signal = amplitude_array * envelope * shaped
        duration = count / RATE
        self.audio.append(signal.astype(np.float64))
        self.truth.append(frequencies.astype(np.float64))
        section: dict[str, object] = {
            "label": label,
            "kind": kind,
            "start_seconds": round(self.time, 6),
            "end_seconds": round(self.time + duration, 6),
        }
        if trap is not None:
            section["trap"] = trap
        self.sections.append(section)
        self.time += duration


def excursion(base: float, target: float, hold: float, away: float) -> np.ndarray:
    """Temelden ayrılıp geri dönen basamaklı sapma: base -> target -> base."""
    return np.concatenate((
        constant(base, hold),
        constant(target, away),
        constant(base, hold),
    ))


def ramp(start: float, finish: float, seconds: float) -> np.ndarray:
    return np.linspace(start, finish, round(seconds * RATE))


def projected_amplitude(samples: np.ndarray, hz: float) -> float:
    """Tek frekansın genliği, sin/cos izdüşümüyle.

    FFT yerine izdüşüm kullanılır: 294 Hz de 882 Hz de tam bir FFT binine oturmadığı
    için pencere sızıntısı oranları %7'ye varan biçimde çarpıtıyor ve olmayan bir
    kalibrasyon hatası gibi görünüyordu.
    """
    timeline = np.arange(len(samples)) / RATE
    cosine = 2 * np.mean(samples * np.cos(2 * np.pi * hz * timeline))
    sine = 2 * np.mean(samples * np.sin(2 * np.pi * hz * timeline))
    return float(np.hypot(cosine, sine))


def measure_section(signal: np.ndarray, start_seconds: float, end_seconds: float) -> dict[str, float]:
    """Bölümün ortasından, tam sayıda temel periyot üzerinde harmonik genlikleri."""
    span = end_seconds - start_seconds
    begin = round((start_seconds + 0.2 * span) * RATE)
    periods = int((0.6 * span) * BASE_HZ)
    count = int(round(periods * RATE / BASE_HZ))
    window = signal[begin:begin + count]
    if periods < 8 or len(window) < count:
        return {}
    reference = max(projected_amplitude(window, BASE_HZ * order) for order in (1, 2, 3, 5))
    if reference <= 1e-9:
        return {}
    return {
        f"{order}f": round(projected_amplitude(window, BASE_HZ * order) / reference, 5)
        for order in (1, 2, 3, 5)
    }


def inject_noise(
    signal: np.ndarray,
    start_seconds: float,
    end_seconds: float,
    snr_db: float,
    rng: np.random.Generator,
) -> None:
    """Tek bir bölüme, o bölümün kendi RMS'ine göre ölçeklenmiş renkli gürültü ekler."""
    begin = round(start_seconds * RATE)
    finish = min(round(end_seconds * RATE), len(signal))
    segment = signal[begin:finish]
    if len(segment) == 0:
        return
    rms = math.sqrt(float(np.mean(segment * segment)))
    white = rng.normal(0, 1, len(segment))
    coloured = np.convolve(white, np.ones(23) / 23, mode="same")
    coloured /= max(float(np.std(coloured)), 1e-12)
    signal[begin:finish] = segment + coloured * rms / 10 ** (snr_db / 20)


def build() -> tuple[np.ndarray, np.ndarray, list[dict[str, object]]]:
    suite = TrapSuite()

    # --- 1. Kontrol -------------------------------------------------------
    suite.add(
        "referans_saglikli", constant(BASE_HZ, 1.5), kind="reference",
        trap={
            "id": "S01",
            "sebep": "Sağlıklı klarnet spektrumu: temel güçlü, tek harmonikler taşıyıcı. Hiçbir tuzak yok.",
            "beklenen_hata": "yok",
            "rapor_bolumu": "kontrol grubu",
            "hedeflenen_esik": "-- burada hata çıkarsa sorun tuzakta değil, ayardadır",
        },
    )
    suite.silence(0.078)

    # --- 2. Zayıf temel merdiveni ----------------------------------------
    # 3. harmonik 1,00'de sabitken temel kademeli söndürülür. Amaç: her motorun
    # tam olarak hangi zayıflık seviyesinde kırıldığını gösteren bir ölçek.
    merdiven = (
        ("S02", 1.00, "yok"),
        ("S03", 0.30, "yok"),
        ("S04", 0.10, "1/3x"),
        ("S05", 0.03, "1/3x"),
        ("S06", 0.00, "1/3x"),
    )
    for trap_id, level, expected in merdiven:
        suite.add(
            f"zayif_temel_{level:.2f}", constant(BASE_HZ, 1.1), kind="weak_fundamental",
            fundamental=level, harmonics=MERDIVEN, saturate=False,
            trap={
                "id": trap_id,
                "sebep": (
                    f"Temel genliği {level:.2f}, 3. harmonik 1,00. Temel zayıfladıkça fark "
                    "fonksiyonunun f/3 çukuru gerçek periyot çukuruyla yarışır: hayalet periyot. "
                    "Doyum kapalıdır -- merdivenin tek işlevi ölçek olmak, dolayısıyla yazılı "
                    "seviye ile akustik gerçek birebir aynı olmalıdır."
                ),
                "beklenen_hata": expected,
                "rapor_bolumu": "§2.3 ve Çözüm 3",
                "hedeflenen_esik": "harmonic_arbitration spectral_existence, HAPT odd_harmonic_relative_threshold",
            },
        )
        suite.silence(0.064)

    # --- 3. Temeli olmayan ton, doyum kontrol çifti -----------------------
    suite.add(
        "temel_yok_doyumsuz", constant(BASE_HZ, 1.3), kind="missing_fundamental",
        fundamental=0.0, harmonics=TEMELSIZ, saturate=False,
        trap={
            "id": "S07",
            "sebep": (
                "Temel frekansta hiç enerji yok; yalnız 3f/5f/7f mevcut. Fark fonksiyonu "
                "294 Hz'de yine de çukur yapar ama spektrumda karşılığı yoktur. Hermes'in "
                "telefon bandı (300 Hz altı kesik) deneyiyle aynı durum: sanal perde."
            ),
            "beklenen_hata": "1/3x",
            "rapor_bolumu": "§2.3, Çözüm 3(c)",
            "hedeflenen_esik": "harmonic_arbitration spectral_existence",
        },
    )
    suite.silence(0.071)
    suite.add(
        "temel_yok_doyumlu", constant(BASE_HZ, 1.3), kind="missing_fundamental",
        fundamental=0.0, harmonics=TEMELSIZ, saturate=True,
        trap={
            "id": "S08",
            "sebep": (
                "S07 ile birebir aynı harmonik içerik, üstüne tanh yumuşak doyumu. Tek "
                "simetrili doğrusalsızlık 2*3f - 5f = f fark tonunu üretir, yani kamış "
                "olmayan temeli geri doğurur. S07 ile kıyas kontrolü."
            ),
            "beklenen_hata": "yok",
            "rapor_bolumu": "§2.3 (kontrol çifti)",
            "hedeflenen_esik": "S07 ile fark, spektral kanıtın ne kadar kırılgan olduğunu gösterir",
        },
    )
    suite.silence(0.083)

    # --- 4. Harmonik yapı varyasyonları ----------------------------------
    suite.add(
        "tam_harmonik_seri", constant(BASE_HZ, 1.2), kind="full_series",
        harmonics=TAM_SERI,
        trap={
            "id": "S09",
            "sebep": (
                "Çift harmonikler de güçlü. Klarnete göre ayarlanmış 'çift harmonik yoksa "
                "normaldir' varsayımı burada geçersiz; f/2 adayı bütün zirveleri açıklayabilir."
            ),
            "beklenen_hata": "2x",
            "rapor_bolumu": "Çözüm 3(b), TWM uyarısı",
            "hedeflenen_esik": "HAPT'ın çift harmonikleri kısıtsız bırakan veto kuralı",
        },
    )
    suite.silence(0.067)
    suite.add(
        "saf_sinus", constant(BASE_HZ, 1.2), kind="pure_sine",
        harmonics=(), saturate=False,
        trap={
            "id": "S10",
            "sebep": (
                "Tek bileşenli saf sinüs, hiç harmonik yok. docs/HAPTPitchEngine.md bunu "
                "bilinen zaaf olarak kaydediyor: saf sinüste sahte tek-harmonik doluluğu. "
                "Doyum kapalıdır: tanh saf sinüsten bile %7 seviyesinde 3. harmonik "
                "üretiyordu, yani bölümü tam olarak sınamak istediği şeyden uzaklaştırıyordu."
            ),
            "beklenen_hata": "2x",
            "rapor_bolumu": "Çözüm 3, Çözüm 6(h)",
            "hedeflenen_esik": "HAPT odd_harmonic_occupancy, MPM clarity sabiti k",
        },
    )
    suite.silence(0.067)
    suite.add(
        "ucuncu_harmonik_baskin", constant(BASE_HZ, 1.2), kind="dominant_third",
        fundamental=0.125, harmonics=BASKIN_UCUNCU, saturate=False,
        trap={
            "id": "S11",
            "sebep": (
                "A(3f)/A(f) = 8,0 -- kOctaveDominanceRatio eşiğinin tam üstü. Temel hâlâ "
                "mevcut ama 3. harmoniği tarafından tam eşik değerinde eziliyor: sınır durumu. "
                "Doyum bilinçli olarak kapalıdır: tanh oranı 12,9'a çekip bölümü eşikten "
                "uzaklaştırıyordu, oysa buradaki amaç eşiğe birebir oturmaktır."
            ),
            "beklenen_hata": "1/3x",
            "rapor_bolumu": "§2.3",
            "hedeflenen_esik": "analysis_engine.cpp kOctaveDominanceRatio = 8.0",
        },
    )
    suite.silence(0.083)

    # --- 5. Genlik ve zarf ------------------------------------------------
    # YIN 2002: genlik artışı ACF zirvelerini lag ile büyütür, bu da sistematik
    # "çok alçak" hataya yol açar.
    crescendo = np.concatenate((ramp(0.012, 0.30, 0.7), np.full(round(0.7 * RATE), 0.30)))
    suite.add(
        "yavas_crescendo", constant(BASE_HZ, len(crescendo) / RATE), kind="crescendo",
        amplitude=crescendo,
        trap={
            "id": "S12",
            "sebep": (
                "700 ms boyunca genlik 0,012'den 0,30'a çıkar. Artan genlik otokorelasyon "
                "zirvelerini lag ile büyütür; bu, YIN makalesinin ismen saydığı sistematik "
                "'çok alçak' hata mekanizmasıdır."
            ),
            "beklenen_hata": "1/2x",
            "rapor_bolumu": "§2.2, Çözüm 6(d)",
            "hedeflenen_esik": "minimum_rms kapısı ve onset_periodicity_threshold",
        },
    )
    suite.silence(0.064)

    decrescendo = np.concatenate((np.full(round(0.5 * RATE), 0.30), ramp(0.30, 0.004, 0.9)))
    suite.add(
        "yavas_decrescendo", constant(BASE_HZ, len(decrescendo) / RATE), kind="decrescendo",
        amplitude=decrescendo,
        trap={
            "id": "S13",
            "sebep": (
                "900 ms'lik sönüm kuyruğu. Nota bırakışı, literatürün 'oktav hatasına en "
                "yatkın an' dediği yerdir; RMS release dedektörü ile gerçek sönüm burada yarışır."
            ),
            "beklenen_hata": "dropout",
            "rapor_bolumu": "Çözüm 6(d), (e)",
            "hedeflenen_esik": "yin_release_falls, sustain_periodicity_threshold",
        },
    )
    suite.silence(0.078)

    # 8 x 90 ms staccato: her nota neredeyse tamamen atak + bırakıştan ibaret.
    # Motor karesi 1536/512 @ 48 kHz ~= 10,67 ms, analiz penceresi 32 ms.
    staccato_seconds = 8 * 0.09 + 7 * 0.085
    staccato = np.zeros(round(staccato_seconds * RATE))
    cursor = 0.0
    for _ in range(8):
        begin = round(cursor * RATE)
        finish = min(begin + round(0.09 * RATE), len(staccato))
        span = finish - begin
        staccato[begin:finish] = 0.26 * np.sin(np.linspace(0, np.pi, span)) ** 0.5
        cursor += 0.09 + 0.085
    suite.add(
        "staccato_dizisi", constant(BASE_HZ, len(staccato) / RATE), kind="staccato",
        amplitude=staccato,
        trap={
            "id": "S14",
            "sebep": (
                "8 adet 90 ms'lik kısa nota, hepsi aynı perdede. 90 ms, 32 ms'lik analiz "
                "penceresinin yalnız üç katı: her nota büyük ölçüde geçici rejimdir, "
                "kararlı periyot hiç kurulmaz."
            ),
            "beklenen_hata": "1/2x",
            "rapor_bolumu": "Çözüm 6(b), (d)",
            "hedeflenen_esik": "pencere boyu / periyot sayısı dengesi",
        },
    )
    suite.silence(0.078)

    # Sabit ton içinde kısa genlik çöküşleri: oktav hataları 1-3 kare sürüyor.
    kesinti_seconds = 1.8
    kesintiler = np.full(round(kesinti_seconds * RATE), 0.26)
    for start, duration in ((0.31, 0.025), (0.72, 0.043), (1.14, 0.032), (1.52, 0.060)):
        kesintiler[round(start * RATE):round((start + duration) * RATE)] = 0.0
    suite.add(
        "ani_kesintiler", constant(BASE_HZ, kesinti_seconds), kind="dropout",
        amplitude=kesintiler,
        trap={
            "id": "S15",
            "sebep": (
                "Sabit ton içinde 25-60 ms'lik dört ani genlik çöküşü. TEST_BASELINE.md'ye "
                "göre gerçek oktav hataları 1-3 kare (medyan 2) sürüyor; bu kesintiler tam "
                "o ölçekte, yani boşluk köprüleme mantığını sınırında yakalar."
            ),
            "beklenen_hata": "dropout",
            "rapor_bolumu": "Çözüm 6(e)",
            "hedeflenen_esik": "bridged_frames boşluk köprüleme, pending_gap_frames",
        },
    )
    suite.silence(0.083)

    # --- 6. Kısa sapmalar, temele dönüşlü --------------------------------
    suite.add(
        "register_sicramasi_12li", excursion(BASE_HZ, BASE_HZ * 3, 0.35, 0.4), kind="register_break",
        trap={
            "id": "S16",
            "sebep": (
                "294 -> 882 -> 294, tam 3x, arada sessizlik yok. Klarnet oktavdan değil "
                "on ikiliden aşırı üfler; bu gerçek bir register kırılmasıdır, hata değil. "
                "Dönüş kolu ayrıca aşağı yönlü onay gecikmesinin gerçek bir sıçramayı "
                "yanlışlıkla bastırıp bastırmadığını gösterir."
            ),
            "beklenen_hata": "3x",
            "rapor_bolumu": "§2.3, Çözüm 6(e)",
            "hedeflenen_esik": "downward_harmonic_confirmations, transition_width_cents = 700",
        },
    )
    suite.silence(0.064)
    suite.add(
        "oktav_sicramasi", excursion(BASE_HZ, BASE_HZ * 2, 0.35, 0.4), kind="octave_jump",
        trap={
            "id": "S17",
            "sebep": (
                "294 -> 588 -> 294, tam 2x. Gerçek bir oktav sıçraması ile oktav hatası "
                "sinyal düzeyinde ayırt edilemez; ayıran tek şey harmonik kanıttır."
            ),
            "beklenen_hata": "2x",
            "rapor_bolumu": "Çözüm 2, Çözüm 6(e)",
            "hedeflenen_esik": "fixed_lag_tracker oktav sıçrama cezası (+0.12)",
        },
    )
    suite.silence(0.064)
    suite.add(
        "hizli_glissando",
        np.concatenate((
            constant(BASE_HZ, 0.1),
            curved_glide(BASE_HZ, BASE_HZ * 2, 0.35, 1.0),
            curved_glide(BASE_HZ * 2, BASE_HZ, 0.35, 1.0),
            constant(BASE_HZ, 0.1),
        )),
        kind="glissando",
        trap={
            "id": "S18",
            "sebep": (
                "0,35 s'de bir oktav çıkıp aynı sürede inen glissando: ~2,9 oktav/saniye. "
                "pYIN'in perde geçiş penceresi kare başına 2,5 yarım tondur; bu hız o "
                "pencerenin sınırını zorlar."
            ),
            "beklenen_hata": "2x",
            "rapor_bolumu": "Çözüm 1 (Aşama 2), Çözüm 6(b)",
            "hedeflenen_esik": "librosa max_transition_rate, transition_width_cents",
        },
    )
    suite.silence(0.064)
    suite.add(
        "vibrato_derin_hizli", vibrato(BASE_HZ, 1.3, 8.0, 70.0), kind="vibrato",
        trap={
            "id": "S19",
            "sebep": (
                "Merkez 294 Hz, 8 Hz hızında +/-70 sent vibrato. Perde 32 ms'lik analiz "
                "penceresi içinde belirgin biçimde kayar; uzun pencerenin kararlılık "
                "kazancı burada çözünürlük kaybına döner."
            ),
            "beklenen_hata": "yok",
            "rapor_bolumu": "Çözüm 6(b)",
            "hedeflenen_esik": "pencere boyu / vibrato takası -- guard bölümü",
        },
    )
    suite.silence(0.064)
    suite.add(
        "carpma_grace",
        np.concatenate((constant(392.0, 0.04), constant(BASE_HZ, 0.66))),
        kind="grace_note",
        trap={
            "id": "S20",
            "sebep": (
                "40 ms'lik 392 Hz çarpma, ardından temele iniş. Çarpma gerçek bir süslemedir: "
                "kaçak nokta temizliği bunu silmemeli, oktav düzeltmesi de bunu bahane "
                "ederek temeli kaydırmamalı."
            ),
            "beklenen_hata": "yok",
            "rapor_bolumu": "Çözüm 6(d)",
            "hedeflenen_esik": "kaçak nokta (stray point) temizliği -- guard bölümü",
        },
    )
    suite.silence(0.083)

    # --- 7. Gürültü kademeleri -------------------------------------------
    # Sinyal burada temiz üretilir; gürültü build() sonrasında bölüm aralığına enjekte
    # edilir, çünkü Holdout.add gürültü parametresi taşımıyor.
    for trap_id, snr_db, expected in (("S21", 30.0, "yok"), ("S22", 20.0, "1/2x"), ("S23", 12.0, "dropout")):
        suite.add(
            f"gurultu_snr_{int(snr_db)}", constant(BASE_HZ, 1.2), kind="noise_step",
            trap={
                "id": trap_id,
                "sebep": (
                    f"Aynı ton, {int(snr_db)} dB sinyal/gürültü oranında. Babacan ve ark. "
                    "YIN'i reverb ve gürültüde en çok bozulan yöntem olarak ölçmüştü; bu "
                    "üç bölüm bozulmanın nerede başladığını kademeli olarak gösterir."
                ),
                "beklenen_hata": expected,
                "rapor_bolumu": "Çözüm 2 (Babacan tablosu), Çözüm 4",
                "hedeflenen_esik": "minimum_periodicity, minimum_rms",
            },
        )
        suite.silence(0.064)

    # --- 8. Kapanış kontrolü ---------------------------------------------
    suite.add(
        "referans_saglikli_kapanis", constant(BASE_HZ, 1.5), kind="reference",
        trap={
            "id": "S24",
            "sebep": (
                "S01 ile birebir aynı bölüm. S01 ve S24 farklı sonuç veriyorsa sorun "
                "sinyalde değil, motorun taşıdığı durumdadır (state leakage)."
            ),
            "beklenen_hata": "yok",
            "rapor_bolumu": "kontrol grubu",
            "hedeflenen_esik": "kontur durumu, release ve peak takipçilerinin sıfırlanması",
        },
    )
    suite.silence(0.12)

    return np.concatenate(suite.audio), np.concatenate(suite.truth), suite.sections


def write_suite(output: Path) -> dict[str, object]:
    output.mkdir(parents=True, exist_ok=True)
    clean, truth, sections = build()

    noise_rng = np.random.default_rng(SEED + 7)
    for section in sections:
        if section["kind"] == "noise_step":
            snr_db = float(str(section["label"]).rsplit("_", 1)[1])
            inject_noise(
                clean,
                float(section["start_seconds"]),
                float(section["end_seconds"]),
                snr_db,
                noise_rng,
            )

    room = room_variant(clean, np.random.default_rng(SEED), 29.0)
    adverse = add_interference(room_variant(clean, np.random.default_rng(SEED + 1), 17.0))
    peak = max(
        float(np.max(np.abs(clean))),
        float(np.max(np.abs(room))),
        float(np.max(np.abs(adverse))),
        1e-12,
    )
    variants = {
        "klarivision_octave_trap_suite_clean_v1.wav": clean * 0.87 / peak,
        "klarivision_octave_trap_suite_room_v1.wav": room * 0.87 / peak,
        "klarivision_octave_trap_suite_adverse_v1.wav": adverse * 0.87 / peak,
    }
    hashes: dict[str, str] = {}
    for name, samples in variants.items():
        path = output / name
        sf.write(path, samples, RATE, subtype="PCM_16")
        hashes[name] = hashlib.sha256(path.read_bytes()).hexdigest()

    # Bölümlerin harmonik içeriğini teslim edilen temiz dosyadan ölçüp manifeste yaz:
    # tuzak açıklamalarındaki oranlar böylece iddia değil, doğrulanmış olgu olur.
    # Perdesi sabit olmayan bölümler (S16-S20) dışarıda: sabit frekansa izdüşüm orada
    # anlamsızdır. Gürültü bölümleri de dışarıda: orada ölçülen şey gürültüdür.
    moving_or_noisy = {
        "silence", "noise_step", "register_break", "octave_jump",
        "glissando", "vibrato", "grace_note",
    }
    delivered = variants["klarivision_octave_trap_suite_clean_v1.wav"]
    for section in sections:
        if section["kind"] in moving_or_noisy:
            continue
        measured = measure_section(
            delivered, float(section["start_seconds"]), float(section["end_seconds"])
        )
        if measured:
            section["measured_harmonic_amplitudes"] = measured

    step = round(TRUTH_STEP * RATE)
    rows = [
        {
            "time_seconds": round(index / RATE, 6),
            "frequency_hz": round(float(truth[index]), 6) if truth[index] > 0 else None,
        }
        for index in range(0, len(truth), step)
    ]
    manifest = {
        "schema": "klarivision-octave-trap-suite-v1",
        "policy": "diagnostic-may-be-retuned",
        "purpose": (
            "docs/OktavHatasi-Arastirma-Raporu.pdf raporundaki oktav hatası sebeplerinin her "
            "birini tek monoton temel (294 Hz) üzerinde ayrı ayrı tetikleyen teşhis seti. "
            "Dondurulmuş turnuva holdout'u DEĞİLDİR; eşik ayarı için kullanılabilir."
        ),
        "base_frequency_hz": BASE_HZ,
        "base_frequency_note": (
            "f/3 = 98,0 Hz (120 Hz perde tabanının altında), f/2 = 147,0 Hz (açık 120-160 Hz "
            "zayıf bandının ortası), 2f = 588,0 Hz, 3f = 882,0 Hz (800 Hz oktav-kurtarma "
            "eşiğinin üstünde)."
        ),
        "expected_failure_vocabulary": ["yok", "1/2x", "1/3x", "2x", "3x", "dropout"],
        "sample_rate_hz": RATE,
        "truth_step_seconds": TRUTH_STEP,
        "duration_seconds": round(len(clean) / RATE, 6),
        "random_seed": SEED,
        "variants": list(variants),
        "sha256": hashes,
        "sections": sections,
        "ground_truth": rows,
    }
    manifest_path = output / "klarivision_octave_trap_suite_ground_truth_v1.json"
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return manifest


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT)
    arguments = parser.parse_args()
    manifest = write_suite(arguments.output_dir)
    traps = sum(1 for section in manifest["sections"] if "trap" in section)  # type: ignore[union-attr]
    print(
        f"suite={arguments.output_dir} duration={manifest['duration_seconds']} "
        f"variants={len(manifest['variants'])} traps={traps}"
    )


if __name__ == "__main__":
    main()
