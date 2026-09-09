package com.aykerme.klarivision.music

// KlariVision Android — tam 53-komalı Türk müziği perde referansı.
//
// data/reference/Turk_Muzigi_Perdeleri_ve_Mikrotonal_Notasyon.xlsx içindeki
// müzisyen tarafından derlenmiş çalışma kitabından, macOS görüntüleyicisinin
// "Türk Müziği · Sol Klarnet" modunun kullandığı AYNI kaynak ve AYNI ±1 oktav
// genişletmesiyle üretildi (bkz. frequency_viewer.py'deki turkishNotes() ve
// klarivision.pitch_reference.extend_reference_octaves). Bu tablo mac'teki
// gibi tam perde adlarını (♯/♭ + koma miktarı) taşır; frekans mobilde
// gösterilmiyor (isim yeterli).
//
// Çalışma kitabı güncellenirse şu script ile yeniden üretilir:
//   .venv/bin/python3 -c "
//   import sys, json
//   sys.path.insert(0, 'src')
//   from klarivision.pitch_reference import load_turkish_pitch_reference, extend_reference_octaves
//   recs = sorted(extend_reference_octaves(load_turkish_pitch_reference()), key=lambda r: r.frequency_hz)
//   for r in recs:
//       print(f'        PitchNote(\"{r.display_notation}\", {round(r.frequency_hz, 3)}),')
//   "

data class PitchNote(val name: String, val hz: Double)

object TurkishPitchReference {
    val notes: List<PitchNote> = listOf(
        PitchNote("Do", 97.78),
        PitchNote("Do ♯4", 103.035),
        PitchNote("Re ♭5", 104.39),
        PitchNote("Re ♭1", 108.575),
        PitchNote("Re", 110.0),
        PitchNote("Re ♯4", 115.915),
        PitchNote("Mi ♭5", 117.44),
        PitchNote("Mi ♭1", 122.14),
        PitchNote("Mi", 123.75),
        PitchNote("Fa", 130.37),
        PitchNote("Fa ♯1", 132.09),
        PitchNote("Fa ♯4", 137.375),
        PitchNote("Sol ♭5", 139.185),
        PitchNote("Sol ♭1", 144.755),
        PitchNote("Sol", 146.665),
        PitchNote("Sol ♯4", 154.55),
        PitchNote("La ♭5", 156.585),
        PitchNote("La ♭1", 162.85),
        PitchNote("La", 165.0),
        PitchNote("La ♯4", 173.87),
        PitchNote("Si ♭5", 176.155),
        PitchNote("Si ♭1", 183.205),
        PitchNote("Si", 185.625),
        PitchNote("Si ♯3", 193.01),
        PitchNote("Do", 195.56),
        PitchNote("Do ♯4", 206.07),
        PitchNote("Re ♭5", 208.78),
        PitchNote("Re ♭1", 217.15),
        PitchNote("Re", 220.0),
        PitchNote("Re ♯4", 231.83),
        PitchNote("Mi ♭5", 234.88),
        PitchNote("Mi ♭1", 244.28),
        PitchNote("Mi", 247.5),
        PitchNote("Fa", 260.74),
        PitchNote("Fa ♯1", 264.18),
        PitchNote("Fa ♯4", 274.75),
        PitchNote("Sol ♭5", 278.37),
        PitchNote("Sol ♭1", 289.51),
        PitchNote("Sol", 293.33),
        PitchNote("Sol ♯4", 309.1),
        PitchNote("La ♭5", 313.17),
        PitchNote("La ♭1", 325.7),
        PitchNote("La", 330.0),
        PitchNote("La ♯4", 347.74),
        PitchNote("Si ♭5", 352.31),
        PitchNote("Si ♭1", 366.41),
        PitchNote("Si", 371.25),
        PitchNote("Si ♯3", 386.02),
        PitchNote("Do", 391.12),
        PitchNote("Do ♯4", 412.14),
        PitchNote("Re ♭5", 417.56),
        PitchNote("Re ♭1", 434.3),
        PitchNote("Re", 440.0),
        PitchNote("Re ♯4", 463.66),
        PitchNote("Mi ♭5", 469.76),
        PitchNote("Mi ♭1", 488.56),
        PitchNote("Mi", 495.0),
        PitchNote("Fa", 521.48),
        PitchNote("Fa ♯1", 528.36),
        PitchNote("Fa ♯4", 549.5),
        PitchNote("Sol ♭5", 556.74),
        PitchNote("Sol ♭1", 579.02),
        PitchNote("Sol", 586.66),
        PitchNote("Sol ♯4", 618.2),
        PitchNote("La ♭5", 626.34),
        PitchNote("La ♭1", 651.4),
        PitchNote("La", 660.0),
        PitchNote("La ♯4", 695.48),
        PitchNote("Si ♭5", 704.62),
        PitchNote("Si ♭1", 732.82),
        PitchNote("Si", 742.5),
        PitchNote("Si ♯3", 772.04),
        PitchNote("Do", 782.24),
    )
}
