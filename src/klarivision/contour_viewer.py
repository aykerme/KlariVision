"""Create a local audio-synchronised pitch contour viewer."""

from __future__ import annotations

import json
import math
from pathlib import Path


AEU_COMMA_CENTS = 1200 / 53
"""Arel–Ezgi–Uzdilek sistemindeki bir koma aralığının sent karşılığı."""

# Sol klarnet için yazılı perde, duyulan sesten tam dörtlü (22 koma) yukarıdadır.
# Bu dönüşüm hem eğriye hem çizgilere birlikte uygulanır.
SOL_CLARINET_WRITTEN_OFFSET = round(-22 * AEU_COMMA_CENTS, 1)

# Koma numarası Kaba Çârgâh'a (Do) göredir. Dügâh 40. komadadır.
# Böylece eğrinin konumu ve etiketler aynı teorik referansı kullanır.
_PERDE_COMMAS = (
    (0, "Kaba Çârgâh", "Do"), (4, "Kaba Nîm Hicaz", "Do"),
    (5, "Kaba Hicaz", "Do"), (8, "Kaba Dik Hicaz", "Do"),
    (9, "Yegâh", "Re"), (13, "Kaba Nîm Hisar", "Re"),
    (14, "Kaba Hisar", "Re"), (17, "Kaba Dik Hisar", "Re"),
    (18, "Hüseynî Aşiran", "Mi"), (22, "Acem Aşiran", "Fa"),
    (23, "Dik Acem Aşiran", "Fa"), (26, "Irak", "Fa"),
    (27, "Geveşt", "Fa"), (30, "Dik Geveşt", "Fa"),
    (31, "Rast", "Sol"), (35, "Nîm Zirgüle", "Sol"),
    (36, "Zirgüle", "Sol"), (39, "Dik Zirgüle", "Sol"),
    (40, "Dügâh", "La"), (44, "Kürdî", "La"),
    (45, "Dik Kürdî", "La"), (48, "Segâh", "Si"),
    (49, "Bûselik", "Si"), (52, "Dik Bûselik", "Si"),
    (53, "Çârgâh", "Do"), (57, "Nîm Hicaz", "Do"),
    (58, "Hicaz", "Do"), (61, "Dik Hicaz", "Do"),
    (62, "Neva", "Re"), (66, "Nîm Hisar", "Re"),
    (67, "Hisar", "Re"), (70, "Dik Hisar", "Re"),
    (71, "Hüseynî", "Mi"), (75, "Acem", "Fa"),
    (79, "Eviç", "Fa"), (80, "Mâhur", "Fa"),
    (83, "Dik Mâhur", "Fa"), (84, "Gerdâniye", "Sol"),
    (88, "Nîm Şehnaz", "Sol"), (89, "Şehnaz", "Sol"),
    (92, "Dik Şehnaz", "Sol"), (93, "Muhayyer", "La"),
    (97, "Sünbüle", "La"), (98, "Dik Sünbüle", "La"),
    (101, "Tiz Segâh", "Si"), (102, "Tiz Bûselik", "Si"),
    (105, "Tiz Dik Bûselik", "Si"), (106, "Tiz Çârgâh", "Do"),
)

_LOWER_EXTENSION = tuple(
    (comma - 106, f"Alt oktav · {name}", western_note)
    for comma, name, western_note in _PERDE_COMMAS
    if 53 < comma < 106
)
_UPPER_EXTENSION = tuple(
    (comma + 106, f"Üst oktav · {name}", western_note)
    for comma, name, western_note in _PERDE_COMMAS
    if 0 < comma < 53
)

LEVELS = tuple(
    (round((comma - 40) * AEU_COMMA_CENTS, 1), name, western_note, comma % 53)
    for comma, name, western_note in (*_LOWER_EXTENSION, *_PERDE_COMMAS, *_UPPER_EXTENSION)
)

# Makamsal eşleme henüz doğrulanmadan önce kullanılabilecek, sade fiziksel
# referans: yalnızca doğal ana notalar ve eşit aralıklı frekansları.
_MAIN_NOTE_FREQUENCIES = (
    ("La2", 110.00), ("Si2", 123.47), ("Do3", 130.81), ("Re3", 146.83),
    ("Mi3", 164.81), ("Fa3", 174.61), ("Sol3", 196.00), ("La3", 220.00),
    ("Si3", 246.94), ("Do4", 261.63), ("Re4", 293.66), ("Mi4", 329.63),
    ("Fa4", 349.23), ("Sol4", 392.00), ("La4", 440.00), ("Si4", 493.88),
    ("Do5", 523.25), ("Re5", 587.33), ("Mi5", 659.25), ("Fa5", 698.46),
    ("Sol5", 783.99), ("La5", 880.00),
)


def main_note_levels(pitch_offset_cents: float = 0.0) -> tuple[tuple[float, str, str, int], ...]:
    """Return a simple frequency grid for calibrating an individual recording."""
    return tuple(
        (
            round(1200 * math.log2(frequency / 440) + pitch_offset_cents, 1),
            note_name,
            f"{frequency:.2f} Hz",
            40,
        )
        for note_name, frequency in _MAIN_NOTE_FREQUENCIES
    )

MAKAM_PROFILES = {
    "huzzam": "Hüzzam",
    "ussak": "Uşşak",
    "hicaz": "Hicaz",
    "rast": "Rast",
    "kurdi": "Kürdî",
}

# Her profil, 53-koma oktavı içindeki perde derecelerinden oluşur. Aynı
# dereceler tüm alt ve üst oktavlarda otomatik olarak görünür.
MAKAM_DEGREES = {
    "huzzam": (40, 48, 0, 4, 9, 18, 26, 31),
    "ussak": (40, 48, 0, 9, 18, 22, 31),
    "hicaz": (40, 44, 4, 9, 18, 22, 31),
    "rast": (31, 40, 48, 0, 9, 18, 22),
    "kurdi": (40, 44, 0, 9, 18, 22, 31),
}

# Karar seçimi, Dügâh (La / A4) tabanlı ham pitch verisini bu perdeye taşır.
KARAR_TONES = {
    "dugah": {"degree": 40, "cents": 0, "name": "Dügâh (La)"},
    "rast": {"degree": 31, "cents": 0, "name": "Rast (Sol)"},
    "neva": {"degree": 9, "cents": 0, "name": "Neva (Re)"},
    "huseyni": {"degree": 18, "cents": 0, "name": "Hüseynî (Mi)"},
    "yegah": {"degree": 9, "cents": 0, "name": "Yegâh (Re)"},
}


def build_viewer(
    pitch_json: Path,
    audio_relative_path: str,
    output: Path,
    *,
    default_makam: str = "huzzam",
    default_karar: str = "dugah",
    ornament_candidates: list[dict[str, object]] | None = None,
    video_relative_path: str | None = None,
    manual_annotations: list[dict[str, object]] | None = None,
    show_ornament_tools: bool = False,
    default_reference: str = "heard",
    pitch_offset_cents: float = 0.0,
    display_levels: tuple[tuple[float, str, str, int], ...] | None = None,
) -> None:
    """Build a standalone viewer with makam, karar and pitch-reference controls."""
    if default_makam not in MAKAM_PROFILES:
        raise ValueError(f"Unknown makam profile: {default_makam}")
    if default_karar not in KARAR_TONES:
        raise ValueError(f"Unknown karar tone: {default_karar}")
    if default_reference not in {"heard", "sol_clarinet"}:
        raise ValueError(f"Unknown pitch reference: {default_reference}")
    frames = json.loads(pitch_json.read_text(encoding="utf-8"))["frames"]
    # pYIN sessizlikte en alt arama frekansına (110 Hz) kilitlenebiliyor.
    # Bu değerler gerçek bir nota değildir ve otomatik dikey yakınlaştırmayı bozar.
    data = [[round(f["time_seconds"], 3), round(1200 * math.log2(f["frequency_hz"] / 440) + pitch_offset_cents, 1)]
            for f in frames if f["frequency_hz"] is not None and f["frequency_hz"] > 112]
    values = [point[1] for point in data]
    natural_low, natural_high = min(values), max(values)
    padding = max(120, (natural_high - natural_low) * 0.1)
    if -1300 <= natural_low and natural_high <= 1300:
        initial_pitch_low, initial_pitch_high = -1300, 1300
    else:
        initial_pitch_low = math.floor((natural_low - padding) / 100) * 100
        initial_pitch_high = math.ceil((natural_high + padding) / 100) * 100
    output.write_text(
        _html(
            data,
            audio_relative_path,
            default_makam,
            default_karar,
            ornament_candidates or [],
            video_relative_path,
            manual_annotations or [],
            initial_pitch_low,
            initial_pitch_high,
            show_ornament_tools,
            default_reference,
            display_levels or LEVELS,
        ),
        encoding="utf-8",
    )


def _html(
    data: list[list[float]],
    audio_path: str,
    default_makam: str,
    default_karar: str,
    ornament_candidates: list[dict[str, object]],
    video_path: str | None,
    manual_annotations: list[dict[str, object]],
    initial_pitch_low: float,
    initial_pitch_high: float,
    show_ornament_tools: bool,
    default_reference: str,
    display_levels: tuple[tuple[float, str, str, int], ...],
) -> str:
    media = (
        f'<video id="a" controls src="{video_path}"></video>'
        if video_path
        else f'<audio id="a" controls src="{audio_path}"></audio>'
    )
    if video_path:
        media_layout = (
            '<div class="workbench"><section class="media-pane">'
            f"{media}</section><section class=\"analysis-pane\">"
        )
        layout_close = "</section></div>"
    else:
        media_layout = f"{media}<section class=\"analysis-pane\">"
        layout_close = "</section>"
    return f'''<!doctype html><meta charset="utf-8"><title>KlariVision</title>
<style>
body{{font-family:system-ui;margin:24px;color:#1e1e1e}}audio,canvas{{width:100%}}video{{display:block;width:100%;max-height:72vh;margin:0 auto}}canvas{{border:1px solid #ddd}}
.controls{{display:flex;gap:12px;align-items:center;margin:16px 0}}label{{font-weight:650}}select{{font:inherit;padding:6px 8px}}
.hint{{color:#666;margin:0 0 14px}}
.actions{{display:flex;gap:8px;align-items:center;flex-wrap:wrap;margin:12px 0}}button{{font:inherit;padding:6px 10px}}button:disabled{{opacity:.45}}
.selection{{color:#555;margin:0 0 10px}}
.candidates{{margin:12px 0}}.candidate-list{{display:flex;gap:8px;flex-wrap:wrap}}.candidate-list button{{background:#fff4ce;border:1px solid #d8b24b}}
.annotations{{margin:12px 0}}.annotation-list{{display:flex;gap:8px;flex-wrap:wrap;margin-top:8px}}.annotation-list button{{background:#eaf4ff;border:1px solid #7baee5}}
.workbench{{display:grid;grid-template-columns:minmax(250px,32%) minmax(0,1fr);gap:20px;align-items:start}}.media-pane{{position:sticky;top:12px}}.analysis-pane{{min-width:0}}
@media(max-width:900px){{.workbench{{display:block}}.media-pane{{position:static;margin-bottom:18px}}video{{max-height:520px}}}}
</style>
<h1 id="title">Pitch Contour</h1>
<div class="controls"><label for="makam">Makam:</label><select id="makam">
<option value="huzzam">Hüzzam</option><option value="ussak">Uşşak</option>
<option value="hicaz">Hicaz</option><option value="rast">Rast</option><option value="kurdi">Kürdî</option></select>
<label for="karar">Karar sesi:</label><select id="karar">
<option value="dugah">Dügâh (La)</option><option value="rast">Rast (Sol)</option>
<option value="neva">Neva (Re)</option><option value="huseyni">Hüseynî (Mi)</option>
<option value="yegah">Yegâh (Re)</option></select>
<label for="reference">Perde referansı:</label><select id="reference"><option value="heard">Duyulan ses (Makampedia)</option><option value="sol_clarinet">Sol klarnet yazılı sesi</option></select>
</div>
<p class="hint" id="hint"></p>{media_layout}
<div class="actions"><button id="play-selection" disabled>Seçimi dinle</button><button id="loop-selection" disabled>Seçimi döngüle</button><button id="zoom-selection" disabled>Seçime yakınlaş</button><button id="reset-view">Görünümü sıfırla</button><label><input id="follow-playback" type="checkbox" checked> Çalımı takip et</label><label for="window-seconds">Ekran süresi:</label><select id="window-seconds"><option value="6">6 sn</option><option value="12" selected>12 sn</option><option value="20">20 sn</option><option value="30">30 sn</option></select><label for="vertical-range">Dikey görünüm:</label><select id="vertical-range"><option value="auto" selected>Otomatik (detay)</option><option value="three-octaves">3 oktav (bağlam)</option></select><button id="time-zoom-in">Zamanda +</button><button id="time-zoom-out">Zamanda −</button><button id="pan-left">←</button><button id="pan-right">→</button></div>
<p class="selection" id="selection">Grafik üzerinde sürükleyerek bir bölüm seç.</p>
<div id="ornament-tools"{"" if show_ornament_tools else " hidden"}><section class="annotations"><strong>Seçimi etiketle</strong><div class="actions"><label for="annotation-type">Tür:</label><select id="annotation-type"><option value="vibrato">Vibrato</option><option value="carpma">Çarpma</option><option value="glissando">Glissando</option><option value="trill">Trill</option><option value="diger">Diğer</option></select><button id="add-annotation" disabled>Etiketi ekle</button><button id="export-annotations" disabled>Etiketleri indir</button></div><div class="annotation-list" id="annotation-list"></div></section>
<section class="candidates"><label><input id="show-candidates" type="checkbox" checked> Süsleme aday ipuçlarını göster</label><div class="candidate-list" id="candidate-list"></div></section></div>
<canvas id="c" width="1200" height="620"></canvas>{layout_close}<script>
const d={json.dumps(data,separators=(",",":"))},l={json.dumps(display_levels,ensure_ascii=False)},profiles={json.dumps(MAKAM_PROFILES,ensure_ascii=False,separators=(",",":"))},makamDegrees={json.dumps(MAKAM_DEGREES,separators=(",",":"))},tones={json.dumps(KARAR_TONES,ensure_ascii=False,separators=(",",":"))},candidates={json.dumps(ornament_candidates,separators=(",",":"))},manualAnnotations={json.dumps(manual_annotations,separators=(",",":"))},initialPitchLow={initial_pitch_low},initialPitchHigh={initial_pitch_high},writtenOffset={SOL_CLARINET_WRITTEN_OFFSET},a=document.querySelector("#a"),c=document.querySelector("#c"),x=c.getContext("2d"),m=document.querySelector("#makam"),k=document.querySelector("#karar"),title=document.querySelector("#title"),hint=document.querySelector("#hint"),selectionText=document.querySelector("#selection"),candidateList=document.querySelector("#candidate-list"),annotationList=document.querySelector("#annotation-list"),annotationType=document.querySelector("#annotation-type"),addAnnotationButton=document.querySelector("#add-annotation"),exportAnnotationsButton=document.querySelector("#export-annotations"),showCandidatesInput=document.querySelector("#show-candidates"),playButton=document.querySelector("#play-selection"),loopButton=document.querySelector("#loop-selection"),zoomButton=document.querySelector("#zoom-selection"),resetButton=document.querySelector("#reset-view"),followPlaybackInput=document.querySelector("#follow-playback"),windowSelect=document.querySelector("#window-seconds"),verticalRangeSelect=document.querySelector("#vertical-range"),timeZoomInButton=document.querySelector("#time-zoom-in"),timeZoomOutButton=document.querySelector("#time-zoom-out"),panLeftButton=document.querySelector("#pan-left"),panRightButton=document.querySelector("#pan-right"),L=180,R=20,T=20,B=45,D=d.at(-1)[0];
let profile=profiles[{json.dumps(default_makam)}],karar=tones[{json.dumps(default_karar)}];m.value={json.dumps(default_makam)};k.value={json.dumps(default_karar)};
let viewStart=0,viewEnd=Math.min(D,12),pitchLow=initialPitchLow,pitchHigh=initialPitchHigh,targetPitchLow=initialPitchLow,targetPitchHigh=initialPitchHigh,selection=null,dragStart=null,dragCurrent=null,loopEnabled=false,selectionPlaying=false,annotations=manualAnnotations.map(annotation=>({{...annotation}})),showCandidates=true,followEnabled=true,windowSeconds=12,verticalMode="auto";
const reference=document.querySelector("#reference"),rawData=d.map(point=>[...point]),rawLevels=l.map(level=>[...level]);reference.value={json.dumps(default_reference)};
const baseMakamDegrees=Object.fromEntries(Object.entries(makamDegrees).map(([name,degrees])=>[name,[...degrees]]));
function setReference(){{const offset=reference.value==="sol_clarinet"?writtenOffset:0;d.forEach((point,index)=>point[1]=rawData[index][1]+offset);l.forEach((level,index)=>level[0]=rawLevels[index][0]+writtenOffset+offset);setProfile();fitVerticalToWindow()}}
reference.addEventListener("change",setReference);setReference();
const X=t=>L+(t-viewStart)/(viewEnd-viewStart)*(c.width-L-R),toTime=px=>viewStart+(px-L)/(c.width-L-R)*(viewEnd-viewStart),Y=v=>T+(pitchHigh-v)/(pitchHigh-pitchLow)*(c.height-T-B);
function setProfile(){{profile=profiles[m.value];karar=tones[k.value];makamDegrees[m.value]=[...baseMakamDegrees[m.value]];const kararLevels=l.filter(level=>level[3]===karar.degree).map(level=>level[0]-writtenOffset),currentPitch=d.reduce((nearest,point)=>Math.abs(point[0]-a.currentTime)<Math.abs(nearest[0]-a.currentTime)?point:nearest,d[0])[1];karar.cents=kararLevels.length?kararLevels.reduce((nearest,value)=>Math.abs(value-currentPitch)<Math.abs(nearest-currentPitch)?value:nearest,kararLevels[0]):0;title.textContent=profile+" — Pitch Contour";const referenceName=reference.value==="sol_clarinet"?"Sol klarnet yazılı sesi":"duyulan ses (Makampedia)";hint.textContent="Dikey eksen "+referenceName+" ile "+profile+" makamının perdelerini gösterir. Karar sesi: "+karar.name+".";if(followEnabled)followViewport(a.currentTime)}}
function followHorizontal(time){{const width=Math.min(D,windowSeconds),start=Math.max(0,Math.min(D-width,time-width*.5));viewStart=start;viewEnd=start+width;}}
function fitVerticalToWindow(){{const pitches=d.filter(point=>point[0]>=viewStart&&point[0]<=viewEnd).map(point=>point[1]+karar.cents);if(!pitches.length)return;const low=Math.min(...pitches),high=Math.max(...pitches),center=(low+high)/2,span=verticalMode==="three-octaves"?3600:Math.max(180,high-low+120);targetPitchLow=center-span/2;targetPitchHigh=center+span/2;}}
function followViewport(time){{followHorizontal(time);fitVerticalToWindow();}}
function stopFollowing(){{followEnabled=false;followPlaybackInput.checked=false;}}
function zoomTime(factor){{const width=Math.max(.5,Math.min(D,(viewEnd-viewStart)*factor));windowSeconds=width;if(followEnabled){{followViewport(a.currentTime);return}}const center=a.currentTime;viewStart=Math.max(0,Math.min(D-width,center-width/2));viewEnd=viewStart+width;fitVerticalToWindow();}}
function panTime(direction){{stopFollowing();const width=viewEnd-viewStart;viewStart=Math.max(0,Math.min(D-width,viewStart+direction*width*.6));viewEnd=viewStart+width;fitVerticalToWindow();}}
function activeRange(){{return dragStart===null?selection:[Math.min(dragStart,dragCurrent),Math.max(dragStart,dragCurrent)]}}
function updateSelection(){{const range=selection;if(!range){{selectionText.textContent="Grafik üzerinde sürükleyerek bir bölüm seç.";playButton.disabled=loopButton.disabled=zoomButton.disabled=addAnnotationButton.disabled=true;loopButton.textContent="Seçimi döngüle";return}}const seconds=(range[1]-range[0]).toFixed(2);selectionText.textContent=range[0].toFixed(2)+"–"+range[1].toFixed(2)+" sn ("+seconds+" sn)";playButton.disabled=loopButton.disabled=zoomButton.disabled=addAnnotationButton.disabled=false;loopButton.textContent=loopEnabled?"Döngüyü durdur":"Seçimi döngüle"}}
function renderAnnotations(){{annotationList.replaceChildren();exportAnnotationsButton.disabled=!annotations.length;if(!annotations.length){{annotationList.textContent="Henüz elle eklenmiş etiket yok.";return}}annotations.forEach((annotation,index)=>{{const focus=document.createElement("button");focus.textContent=annotation.kind+" · "+annotation.start_seconds.toFixed(2)+"–"+annotation.end_seconds.toFixed(2)+" sn";focus.addEventListener("click",()=>{{selection=[annotation.start_seconds,annotation.end_seconds];viewStart=Math.max(0,annotation.start_seconds-.15);viewEnd=Math.min(D,annotation.end_seconds+.15);a.currentTime=annotation.start_seconds;updateSelection()}});const remove=document.createElement("button");remove.textContent="Sil";remove.addEventListener("click",()=>{{annotations.splice(index,1);renderAnnotations()}});annotationList.append(focus,remove)}})}}
function p(){{if(followEnabled)followHorizontal(a.currentTime);pitchLow+=(targetPitchLow-pitchLow)*.16;pitchHigh+=(targetPitchHigh-pitchHigh)*.16;x.clearRect(0,0,c.width,c.height);x.font="16px system-ui";let previousLabelY=Infinity;l.forEach(q=>{{const displayPitch=q[0]-writtenOffset,isKararLine=Math.abs(displayPitch-karar.cents)<.1;if(!makamDegrees[m.value].includes(q[3])&&!isKararLine)return;const y=Y(displayPitch);if(y<T-10||y>c.height-B+10)return;x.beginPath();x.moveTo(L,y);x.lineTo(c.width-R,y);x.strokeStyle=isKararLine?"#e75a5a":"#ddd";x.lineWidth=isKararLine?2:1;x.stroke();const labelIsSpaced=previousLabelY-y>=16;if(labelIsSpaced||isKararLine){{x.fillStyle="#1e1e1e";x.fillText(q[1]+" ("+q[2]+")",10,y+5);previousLabelY=y}}}});if(showCandidates)candidates.forEach(candidate=>{{if(candidate.end_seconds<viewStart||candidate.start_seconds>viewEnd)return;x.fillStyle="rgba(219,164,40,.22)";x.fillRect(X(Math.max(viewStart,candidate.start_seconds)),T,X(Math.min(viewEnd,candidate.end_seconds))-X(Math.max(viewStart,candidate.start_seconds)),c.height-T-B)}});annotations.forEach(annotation=>{{if(annotation.end_seconds<viewStart||annotation.start_seconds>viewEnd)return;x.fillStyle=annotation.kind==="vibrato"?"rgba(46,145,92,.28)":"rgba(54,113,204,.28)";x.fillRect(X(Math.max(viewStart,annotation.start_seconds)),T,X(Math.min(viewEnd,annotation.end_seconds))-X(Math.max(viewStart,annotation.start_seconds)),c.height-T-B)}});const range=activeRange();if(range){{x.fillStyle="rgba(116,80,200,.16)";x.fillRect(X(range[0]),T,X(range[1])-X(range[0]),c.height-T-B)}}x.strokeStyle="#111";x.lineWidth=2;x.beginPath();let started=false;d.forEach(q=>{{if(q[0]<viewStart||q[0]>viewEnd)return;if(started)x.lineTo(X(q[0]),Y(q[1]+karar.cents));else{{x.moveTo(X(q[0]),Y(q[1]+karar.cents));started=true}}}});x.stroke();x.strokeStyle="#7450c8";x.lineWidth=1;x.beginPath();x.moveTo(X(a.currentTime),T);x.lineTo(X(a.currentTime),c.height-B);x.stroke();requestAnimationFrame(p)}}
function canvasTime(event){{const box=c.getBoundingClientRect(),px=(event.clientX-box.left)*c.width/box.width;return Math.max(viewStart,Math.min(viewEnd,toTime(px)))}}
c.addEventListener("mousedown",event=>{{dragStart=canvasTime(event);dragCurrent=dragStart}});c.addEventListener("mousemove",event=>{{if(dragStart!==null)dragCurrent=canvasTime(event)}});c.addEventListener("mouseup",event=>{{if(dragStart===null)return;dragCurrent=canvasTime(event);const range=activeRange();if(range[1]-range[0]<.06){{a.currentTime=range[0];selection=null;loopEnabled=false;selectionPlaying=false}}else{{selection=range;loopEnabled=false;selectionPlaying=false}}dragStart=dragCurrent=null;updateSelection()}});c.addEventListener("mouseleave",event=>{{if(dragStart!==null)c.dispatchEvent(new MouseEvent("mouseup",{{clientX:event.clientX}}))}});
function zoomToSelection(){{if(!selection)return;stopFollowing();viewStart=Math.max(0,selection[0]-.15);viewEnd=Math.min(D,selection[1]+.15);const pitches=d.filter(point=>point[0]>=selection[0]&&point[0]<=selection[1]).map(point=>point[1]+karar.cents);if(!pitches.length)return;const low=Math.min(...pitches),high=Math.max(...pitches),center=(low+high)/2,span=Math.max(80,high-low+40);pitchLow=targetPitchLow=center-span/2;pitchHigh=targetPitchHigh=center+span/2}}
playButton.addEventListener("click",()=>{{if(selection){{loopEnabled=false;selectionPlaying=true;a.currentTime=selection[0];a.play();updateSelection()}}}});loopButton.addEventListener("click",()=>{{if(!selection)return;loopEnabled=!loopEnabled;selectionPlaying=loopEnabled;a.currentTime=selection[0];if(loopEnabled)a.play();updateSelection()}});zoomButton.addEventListener("click",zoomToSelection);resetButton.addEventListener("click",()=>{{viewStart=0;viewEnd=D;pitchLow=initialPitchLow;pitchHigh=initialPitchHigh;targetPitchLow=initialPitchLow;targetPitchHigh=initialPitchHigh;selection=null;loopEnabled=false;selectionPlaying=false;updateSelection()}});addAnnotationButton.addEventListener("click",()=>{{if(!selection)return;annotations.push({{kind:annotationType.value,start_seconds:selection[0],end_seconds:selection[1]}});renderAnnotations()}});exportAnnotationsButton.addEventListener("click",()=>{{const record={{version:1,annotations}};const blob=new Blob([JSON.stringify(record,null,2)],{{type:"application/json"}});const link=document.createElement("a");link.href=URL.createObjectURL(blob);link.download="klarivision-annotations.json";link.click();URL.revokeObjectURL(link.href)}});showCandidatesInput.addEventListener("change",()=>{{showCandidates=showCandidatesInput.checked}});a.addEventListener("timeupdate",()=>{{if(!selection||!selectionPlaying||a.currentTime<selection[1])return;if(loopEnabled){{a.currentTime=selection[0];a.play()}}else{{a.pause();a.currentTime=selection[0];selectionPlaying=false}}}});candidates.forEach((candidate,index)=>{{const button=document.createElement("button");const detail=candidate.kind==="vibrato"?candidate.rate_hz+" Hz":Math.round(candidate.amplitude_cents)+" sent";button.textContent=candidate.kind+" adayı "+(index+1)+" · "+Math.round(candidate.confidence*100)+"% · "+detail;button.addEventListener("click",()=>{{selection=[candidate.start_seconds,candidate.end_seconds];loopEnabled=false;selectionPlaying=false;zoomToSelection();a.currentTime=candidate.start_seconds;updateSelection()}});candidateList.appendChild(button)}});if(!candidates.length)candidateList.textContent="Bu kayıtta eşik değerini geçen süsleme adayı bulunamadı.";m.addEventListener("change",setProfile);k.addEventListener("change",setProfile);followPlaybackInput.addEventListener("change",()=>{{followEnabled=followPlaybackInput.checked;if(followEnabled)followViewport(a.currentTime)}});windowSelect.addEventListener("change",()=>{{windowSeconds=Number(windowSelect.value);if(followEnabled)followViewport(a.currentTime)}});verticalRangeSelect.addEventListener("change",()=>{{verticalMode=verticalRangeSelect.value;fitVerticalToWindow()}});timeZoomInButton.addEventListener("click",()=>zoomTime(.6));timeZoomOutButton.addEventListener("click",()=>zoomTime(1.6));panLeftButton.addEventListener("click",()=>panTime(-1));panRightButton.addEventListener("click",()=>panTime(1));a.addEventListener("timeupdate",()=>{{if(followEnabled)fitVerticalToWindow()}});resetButton.addEventListener("click",()=>{{followEnabled=true;followPlaybackInput.checked=true;followViewport(a.currentTime)}});setProfile();followViewport(0);updateSelection();renderAnnotations();p();</script>'''
