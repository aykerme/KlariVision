"""Dinleme Modu viewer'ının "Birlikte Çal" mikrofon katmanını cihazsız test eder.

Gerçek bir tarayıcı yok; bunun yerine `build_frequency_viewer` çıktısındaki
tek `<script>` gövdesi çıkarılıp, minimal bir DOM/BOM sahtesiyle birlikte
`jsc` (JavaScriptCore'un komut satırı yorumlayıcısı) altında çalıştırılır.

Viewer script'i top-level `const`/`let` bildirimleriyle yazıldığı (bir
fonksiyona sarılmadığı) için, harness + script + sürücü kodu TEK bir dosyada
art arda eklenip tek `jsc` çağrısıyla çalıştırılınca hepsi aynı global
kapsamı paylaşır. Bu sayede sürücü kodu `media`, `micFrames`, `tick`,
`restartLoopAtA`, `duration`, `loopA/loopB/loopEnabled` gibi script'in kendi
üst düzey değişkenlerine doğrudan erişip davranışı hem içeriden (micFrames
dizisi) hem de çizimden (ctx.moveTo/lineTo çağrıları) doğrulayabilir.

DOM sahtesi `tests/_mic_layer_dom_harness.js` dosyasında; kendi iç isimleri
bir IIFE içinde saklı olduğundan viewer script'inin üst düzey isimleriyle
çakışmaz.
"""

from __future__ import annotations

import importlib.util
import json
import subprocess
from pathlib import Path

import pytest

from klarivision.frequency_viewer import build_frequency_viewer

REPO_ROOT = Path(__file__).resolve().parents[1]
JSC_PATH = Path(
    "/System/Library/Frameworks/JavaScriptCore.framework/Versions/A/Helpers/jsc"
)
HARNESS_JS = (Path(__file__).parent / "_mic_layer_dom_harness.js").read_text(encoding="utf-8")

pytestmark = pytest.mark.skipif(
    not JSC_PATH.exists(),
    reason="jsc (JavaScriptCore komut satırı) bu makinede yok; DOM'suz JS testleri atlanıyor.",
)


def _extract_script(html: str) -> str:
    """Üretilen HTML'deki tek `<script>` gövdesini döndürür."""
    start = html.index("<script>") + len("<script>")
    end = html.index("</script>", start)
    return html[start:end]


def _build_script(tmp_path: Path, frames: list[dict[str, object]]) -> str:
    """Verilen pYIN karelerinden viewer HTML'i üretip script gövdesini çıkarır."""
    pitch_json = tmp_path / "pitch.json"
    pitch_json.write_text(json.dumps({"frames": frames}), encoding="utf-8")
    output = tmp_path / "viewer.html"
    build_frequency_viewer(pitch_json, "audio.wav", output)
    return _extract_script(output.read_text(encoding="utf-8"))


def _constant_pitch_frames(duration_seconds: float, step: float = 0.05, hz: float = 220.0) -> list[dict[str, object]]:
    """pYIN'in ürettiğine benzer, sabit frekanslı ve tamamen sesli bir kontur."""
    count = int(round(duration_seconds / step)) + 1
    return [
        {"time_seconds": round(i * step, 6), "frequency_hz": hz, "voiced": True, "confidence": 0.9}
        for i in range(count)
    ]


def _run_jsc(tmp_path: Path, script_js: str, driver_js: str) -> list[str]:
    """Harness + viewer script + sürücüyü tek `jsc` çağrısında çalıştırır.

    Sürücünün `print(JSON.stringify(...))` ile yazdığı her satır, sırasıyla
    döndürülen listede yer alır.
    """
    program = "\n".join([HARNESS_JS, script_js, driver_js])
    program_path = tmp_path / "program.js"
    program_path.write_text(program, encoding="utf-8")
    result = subprocess.run(
        [str(JSC_PATH), str(program_path)],
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert result.returncode == 0, (
        f"jsc başarısız oldu (exit={result.returncode}).\n"
        f"STDOUT:\n{result.stdout}\nSTDERR:\n{result.stderr}"
    )
    lines = [line for line in result.stdout.splitlines() if line.strip()]
    assert lines, f"jsc hiçbir çıktı üretmedi. STDERR:\n{result.stderr}"
    return lines


def test_backward_seek_truncates_mic_points_after_the_new_time(tmp_path: Path) -> None:
    """Geriye sıçrama: micTruncate yalnızca yeni zamandan sonrasını siler."""
    script_js = _build_script(tmp_path, _constant_pitch_frames(12.0))
    driver_js = r"""
// Noktalar canlida calma basinin gerisinden gelir; micAppend calma
// basinin belirgin onundeki (bayat) noktalari reddettigi icin kurulum
// da ayni sirayi izlemeli.
media.currentTime = 10;
var points = [];
for (var i = 0; i <= 100; i++) points.push({t: i * 0.1, hz: 300});
window.klariVisionStudyViewer.micAppend(points);

tick();
var lengthAt10 = micFrames.length;

media.currentTime = 4;
tick();

print(JSON.stringify({
    lengthAt10: lengthAt10,
    lengthAt4: micFrames.length,
    allBeforeCutoff: micFrames.every(function (p) { return p.t < 4; }),
    maxRemainingT: micFrames.length ? micFrames[micFrames.length - 1].t : null,
}));
"""
    (result,) = _run_jsc(tmp_path, script_js, driver_js)
    data = json.loads(result)
    assert data["lengthAt10"] == 101, "10 sn'ye kadar eklenen tüm noktalar önce yerinde durmalı"
    assert data["allBeforeCutoff"] is True, "4 sn'den sonraki hiçbir mikrofon noktası kalmamalı"
    assert data["lengthAt4"] == 40, "yalnızca t<4 olan noktalar (0.0..3.9) durmalı"
    assert data["maxRemainingT"] < 4


def test_forward_seek_keeps_all_points_and_breaks_the_drawn_path(tmp_path: Path) -> None:
    """İleri sıçrama: hiçbir nokta silinmez ama 5-8 sn arasında yol kırılır (moveTo)."""
    script_js = _build_script(tmp_path, _constant_pitch_frames(12.0))
    driver_js = r"""
// Noktalar canlida calma basinin gerisinden gelir; micAppend calma
// basinin belirgin onundeki (bayat) noktalari reddettigi icin kurulum
// da ayni sirayi izlemeli.
media.currentTime = 5;
var firstBatch = [];
for (var i = 0; i <= 50; i++) firstBatch.push({t: i * 0.1, hz: 300}); // 0..5 sn
window.klariVisionStudyViewer.micAppend(firstBatch);

tick();
media.currentTime = 8;
tick();

media.currentTime = 9;
var secondBatch = [];
for (var i = 0; i <= 10; i++) secondBatch.push({t: 8 + i * 0.1, hz: 320}); // 8..9 sn
window.klariVisionStudyViewer.micAppend(secondBatch);

var totalPoints = micFrames.length;

// Tüm mikrofon aralığını (0..9 sn) tek pencerede görmek için genişlet.
setWindow(20);
viewStart = -1;

// micFrames'i çizimden geçici olarak çıkarıp "mikrofonsuz" çizim izini al;
// ardından geri koyup "mikrofonlu" izi al. İkisinin farkı, yalnızca
// mikrofon eğrisine ait moveTo/lineTo dizisini verir (grid/eksen/işaretçi
// operasyonları her iki izde de birebir aynı kalır).
var savedMic = micFrames;
micFrames = [];
__resetCtxOps();
draw();
var withoutMic = __ctxOps.slice();

micFrames = savedMic;
__resetCtxOps();
draw();
var withMic = __ctxOps.slice();

function opsEqual(a, b) { return a[0] === b[0] && a[1] === b[1] && a[2] === b[2]; }
var prefixLen = 0;
while (prefixLen < withoutMic.length && prefixLen < withMic.length &&
       opsEqual(withoutMic[prefixLen], withMic[prefixLen])) prefixLen++;
var suffixLen = 0;
while (suffixLen < withoutMic.length - prefixLen && suffixLen < withMic.length - prefixLen &&
       opsEqual(withoutMic[withoutMic.length - 1 - suffixLen], withMic[withMic.length - 1 - suffixLen])) suffixLen++;
var micSegment = withMic.slice(prefixLen, withMic.length - suffixLen);

print(JSON.stringify({
    totalPoints: totalPoints,
    micSegmentLength: micSegment.length,
    micSegmentOps: micSegment.map(function (op) { return op[0]; }),
}));
"""
    (result,) = _run_jsc(tmp_path, script_js, driver_js)
    data = json.loads(result)
    assert data["totalPoints"] == 62, "ileri sıçramada hiçbir mikrofon noktası silinmemeli (51 + 11)"
    ops = data["micSegmentOps"]
    assert len(ops) == 62, "mikrofon eğrisinin görünen tüm noktaları çizilmeli"
    # İlk nokta her zaman moveTo'dur; 5 sn'deki son noktadan 8 sn'deki ilk
    # noktaya geçiş 3 sn'lik boşluk yüzünden 0.12 sn eşiğini aşar ve tekrar
    # moveTo olur. Aradaki bütün komşu noktalar (0.1 sn aralıklı) lineTo'dur.
    assert ops[0] == "M"
    assert ops[51] == "M", "5 sn ile 8 sn arasındaki boşluk yolu kırmalı (moveTo)"
    assert ops.count("M") == 2, "iki parça (0..5 ve 8..9) için tam olarak iki moveTo olmalı"
    assert ops.count("L") == 60


def test_loop_return_truncates_mic_points_the_same_way_as_a_backward_seek(tmp_path: Path) -> None:
    """Loop B'den A'ya dönüş, geriye sıçramayla aynı mekanizmayı (tick) kullanır."""
    script_js = _build_script(tmp_path, _constant_pitch_frames(12.0))
    driver_js = r"""
// Noktalar canlida calma basinin gerisinden gelir; micAppend calma
// basinin belirgin onundeki (bayat) noktalari reddettigi icin kurulum
// da ayni sirayi izlemeli.
media.currentTime = 10;
var points = [];
for (var i = 0; i <= 100; i++) points.push({t: i * 0.1, hz: 300}); // 0..10 sn
window.klariVisionStudyViewer.micAppend(points);

loopA = 2;
loopB = 6;
loopEnabled = true;

media.currentTime = 6;
tick();
var lengthBeforeLoopReturn = micFrames.length;

restartLoopAtA(); // gerçek "loop B'ye ulaşıldı, A'ya dön" fonksiyonu
var timeAfterRestart = media.currentTime;
tick();

print(JSON.stringify({
    lengthBeforeLoopReturn: lengthBeforeLoopReturn,
    timeAfterRestart: timeAfterRestart,
    lengthAfterLoopReturn: micFrames.length,
    allBeforeA: micFrames.every(function (p) { return p.t < 2; }),
}));
"""
    (result,) = _run_jsc(tmp_path, script_js, driver_js)
    data = json.loads(result)
    assert data["lengthBeforeLoopReturn"] == 101
    assert data["timeAfterRestart"] == 2, "restartLoopAtA() currentTime'ı A'ya (2 sn) almalı"
    assert data["allBeforeA"] is True, "A'dan (2 sn) sonraki mikrofon noktaları silinmeli"
    assert data["lengthAfterLoopReturn"] == 20, "yalnızca t<2 olan noktalar (0.0..1.9) durmalı"


def test_stale_points_from_before_a_loop_return_do_not_block_the_rest_of_the_lap(
    tmp_path: Path,
) -> None:
    """Regresyon: loop turlarının bazılarında mikrofon hiç çizilmiyordu.

    Loop A'ya döndüğünde Swift'in sunum saati sıçramayı ~50 ms geç görür ve o
    arada B civarına damgalanmış bayat noktalar yollar. Bunlar kabul edilirse
    `lastT` B'ye kaçar ve turun geri kalanındaki gerçek noktalar `t<lastT`
    elemesine takılıp hiç çizilmezdi.
    """
    script_js = _build_script(tmp_path, _constant_pitch_frames(12.0))
    driver_js = r"""
loopA = 2;
loopB = 6;
loopEnabled = true;

// Tur boyunca A..B arası normal çizim; çalma başı turun sonunda (B).
media.currentTime = 6;
var lap = [];
for (var i = 20; i <= 60; i++) lap.push({t: i * 0.1, hz: 300}); // 2.0..6.0 sn
window.klariVisionStudyViewer.micAppend(lap);
tick();            // B'deki kare gözlensin ki geri sıçrama tespit edilebilsin

restartLoopAtA();  // B'ye ulaşıldı, A'ya dön
tick();            // sayfa geri sıçramayı görür ve A sonrasını siler
var afterTruncate = micFrames.length;

// Swift'in bayat saati: kareler hâlâ B civarına damgalanıyor.
window.klariVisionStudyViewer.micAppend([{t: 5.95, hz: 300}, {t: 6.0, hz: 300}]);
var afterStale = micFrames.length;

// Saat A'ya oturur; turun gerçek noktaları çalma başıyla birlikte ilerleyerek
// gelir (canlıdaki akışın aynısı: her nokta o anki çalma başının gerisinde).
for (var j = 21; j <= 30; j++) {
    media.currentTime = j * 0.1;
    window.klariVisionStudyViewer.micAppend([{t: j * 0.1, hz: 310}]); // 2.1..3.0 sn
}

print(JSON.stringify({
    afterTruncate: afterTruncate,
    staleAccepted: afterStale - afterTruncate,
    freshAccepted: micFrames.length - afterStale,
    maxT: micFrames.reduce(function (m, p) { return p.t > m ? p.t : m; }, -1),
}));
"""
    (result,) = _run_jsc(tmp_path, script_js, driver_js)
    data = json.loads(result)
    assert data["afterTruncate"] == 0, "A'dan (2 sn) sonrası silinmeli; turun tamamı A..B idi"
    assert data["staleAccepted"] == 0, (
        "çalma başı 2 sn'deyken 6 sn'ye damgalanmış bayat noktalar kabul edilmemeli"
    )
    assert data["freshAccepted"] == 10, "turun gerçek noktaları elenmeden çizilmeli"
    assert data["maxT"] <= 3.0 + 1e-9


def test_mic_append_drops_out_of_order_times_and_non_finite_or_non_positive_hz(tmp_path: Path) -> None:
    """micAppend: t azalan veya hz sonlu/pozitif olmayan noktalar sessizce atılır."""
    script_js = _build_script(tmp_path, _constant_pitch_frames(4.0))
    driver_js = r"""
media.currentTime = 3;
window.klariVisionStudyViewer.micAppend([
    {t: 1.0, hz: 200},     // kabul
    {t: 0.5, hz: 210},     // reddedilir: t geriye gidiyor (son kabul edilenden küçük)
    {t: 2.0, hz: -5},      // reddedilir: hz<=0
    {t: 2.0, hz: 0},       // reddedilir: hz<=0
    {t: 3.0, hz: NaN},     // reddedilir: hz sonlu değil
    {t: 3.0, hz: Infinity},// reddedilir: hz sonlu değil
    {t: 2.5, hz: 220},     // kabul (t=1.0'dan büyük, hz geçerli)
    {t: 2.5, hz: 230},     // kabul (t eşitliği serbest; azalan değil)
]);

print(JSON.stringify({frames: micFrames}));
"""
    (result,) = _run_jsc(tmp_path, script_js, driver_js)
    data = json.loads(result)
    assert data["frames"] == [
        {"t": 1.0, "hz": 200},
        {"t": 2.5, "hz": 220},
        {"t": 2.5, "hz": 230},
    ]


def test_empty_mic_layer_draws_exactly_like_before_the_feature_existed(tmp_path: Path) -> None:
    """Regresyon: micFrames boşken, dosya eğrisinin çizimi HEAD'deki (mikrofonsuz)
    davranışla birebir aynı olmalı (moveTo/lineTo dizisi hiç değişmemiş)."""
    frames = _constant_pitch_frames(12.0)

    current_script = _build_script(tmp_path, frames)

    old_source = subprocess.run(
        ["git", "show", "HEAD:src/klarivision/frequency_viewer.py"],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    old_module_path = tmp_path / "old_frequency_viewer.py"
    old_module_path.write_text(old_source, encoding="utf-8")
    spec = importlib.util.spec_from_file_location("old_frequency_viewer_baseline", old_module_path)
    assert spec is not None and spec.loader is not None
    old_module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(old_module)

    old_pitch_json = tmp_path / "old_pitch.json"
    old_pitch_json.write_text(json.dumps({"frames": frames}), encoding="utf-8")
    old_output = tmp_path / "old_viewer.html"
    old_module.build_frequency_viewer(old_pitch_json, "audio.wav", old_output)
    old_script = _extract_script(old_output.read_text(encoding="utf-8"))

    driver_js = r"""
media.currentTime = 3;
tick();
print(JSON.stringify(__ctxOps));
"""
    new_dir = tmp_path / "new"
    old_dir = tmp_path / "old"
    new_dir.mkdir()
    old_dir.mkdir()
    (new_ops_json,) = _run_jsc(new_dir, current_script, driver_js)
    (old_ops_json,) = _run_jsc(old_dir, old_script, driver_js)

    new_ops = json.loads(new_ops_json)
    old_ops = json.loads(old_ops_json)
    assert new_ops == old_ops, "micFrames boşken dosya eğrisinin çizimi mikrofon katmanından önceki ile birebir aynı olmalı"
