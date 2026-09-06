"""Dış karşılaştırma koşucusunun ölçüm hattı.

Buradaki testler motoru ölçmez; **ölçen kodu** ölçer. Bu ayrım, bu dosyanın
var olma sebebidir: `on_hop_grid` motorun yayımladığı karelerin üçte birini
puanlamadan önce siliyordu ve sonuç tabloya motorun ötüm kusuru gibi
yansıyordu. Böyle bir hata, motorda aranan bir kusuru olmayan yerde
aratabildiği için, motorun kendi testlerinden daha ucuza yakalanmalı.
"""

from __future__ import annotations

import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

from run_external_pitch_benchmark import HOP_SECONDS, on_hop_grid  # noqa: E402


def engine_style_frames(count: int, *, window: int = 1536, hop: int = 512, rate: int = 48_000):
    """Motorun gerçekte ürettiği zaman damgaları: analiz penceresinin merkezi.

    Merkez, sıfır tabanlı hop ızgarasının tam yarısına düşer (0.5, 1.5, ...);
    bu testlerin tamamı o yarım hop kaymasıyla ilgilidir.
    """
    return [
        ((index * hop + window / 2) / rate, 440.0 + index, 0.9)
        for index in range(count)
    ]


def test_every_published_frame_gets_its_own_slot() -> None:
    """Bir hop arayla yayımlanan kareler aynı yuvaya düşemez.

    Eski eşleme `round(t / hop)` idi. Motorun damgası yarım hop kaymış olduğu
    için karar, izin metinde yuvarlanmasının hangi tarafa düştüğüne kalıyordu:
    ölçülen 1994 karenin 1336 yuvaya indiği koşuda, kaybolan kareler ötümsüz
    sayılıyordu.
    """
    frames = engine_style_frames(200)
    _times, hz = on_hop_grid(frames, duration=200 * HOP_SECONDS + 1.0)
    assert int((hz > 0).sum()) == len(frames)


def test_grid_preserves_frequencies_in_order() -> None:
    frames = engine_style_frames(50)
    _times, hz = on_hop_grid(frames, duration=50 * HOP_SECONDS + 1.0)
    published = hz[hz > 0]
    assert list(published) == [frame[1] for frame in frames]


def test_withheld_frames_stay_silent_between_published_ones() -> None:
    """Yayımlanmayan kare ızgarada açık bir 0 Hz olmalı.

    Izgaranın asıl işi bu: motor sessiz kaldığı kareyi hiç yayımlamaz, ve
    mir_eval boşluğun iki ucunu birleştirirse aradaki her şeyi ötümlü sayar.
    """
    frames = engine_style_frames(10)
    del frames[3:6]  # motor bu üç karede çekimser kaldı
    _times, hz = on_hop_grid(frames, duration=10 * HOP_SECONDS + 1.0)
    assert int((hz > 0).sum()) == 7
    # Yayımlanan ilk ve son karenin ARASINDA tam üç sessiz yuva olmalı.
    # Izgara dosyanın başından başlayıp sonuna kadar uzandığı için dışarıdaki
    # sessiz yuvalar bu sayıya karışmamalı.
    published = np.flatnonzero(hz > 0)
    interior = hz[published[0]:published[-1] + 1]
    assert int((interior == 0).sum()) == 3


def test_reference_style_frames_on_the_zero_grid_also_survive() -> None:
    """pYIN kareleri sıfır tabanlı ızgarada ve iki elemanlı gelir.

    Referans hiç çakışmıyordu; motorlar çakışıyordu. Karşılaştırmanın iki
    tarafı aynı yoldan geçtiği için bu asimetri tabloyu tek yönde bozuyordu,
    ve bu testin varlığı o asimetrinin geri gelmediğini söyler.
    """
    frames = [(index * HOP_SECONDS, 220.0 + index) for index in range(100)]
    _times, hz = on_hop_grid(frames, duration=100 * HOP_SECONDS + 1.0)
    assert int((hz > 0).sum()) == len(frames)


def test_grid_still_covers_the_silence_before_the_first_published_frame() -> None:
    """Izgara faza kilitlenir ama sıfırdan başlar.

    İlk *ötümlü* kareye demirlemek indeksleme sorununu çözer ve yenisini
    yaratır: dosyanın başındaki sessizlik ızgaradan düşer, mir_eval o bölgeyi
    ötümlü sayar. Ölçüldü -- yanlış alarm, ızgara hatasından hiç etkilenmeyen
    pYIN referansında bile 0,025'ten 0,124'e çıkıyordu.
    """
    frames = engine_style_frames(20)
    late = [(time + 5.0, hz, confidence) for time, hz, confidence in frames]
    times, hz = on_hop_grid(late, duration=10.0)
    assert times[0] < HOP_SECONDS  # ilk yuva dosyanın başında
    assert times[-1] >= 10.0 - HOP_SECONDS  # ve sonuna kadar uzanıyor
    assert int((hz > 0).sum()) == len(late)
    assert not np.any(hz[: int(4.0 / HOP_SECONDS)] > 0)  # baştaki sessizlik sessiz


def test_grid_aligned_trace_starts_exactly_at_zero() -> None:
    """Zaten ızgarada olan bir iz sıfırdan başlamalı, 3e-18'den değil.

    pYIN kareleri hop'un tam katlarında. `t % hop` bunlarda sıfır değil,
    sıfıra çok yakın bir kayan nokta artığı verir. Artığı faz sayarsak
    mir_eval başa bir t=0 örneği ekler, zamanları 10 ondalığa yuvarlar ve
    iki sıfır yan yana gelir -- ölçümü çökerten şey buydu.
    """
    frames = [(index * HOP_SECONDS, 220.0 + index) for index in range(30)]
    times, _hz = on_hop_grid(frames, duration=1.0)
    assert times[0] == 0.0


def test_empty_trace_produces_a_silent_grid_rather_than_failing() -> None:
    times, hz = on_hop_grid([], duration=1.0)
    assert times.size == hz.size > 0
    assert not np.any(hz > 0)
