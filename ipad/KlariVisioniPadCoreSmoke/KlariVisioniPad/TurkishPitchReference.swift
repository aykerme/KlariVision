// KlariVision iPhone/iPad — tam 53-komalı Türk müziği perde referansı.
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
//       print(f'        (\"{r.display_notation}\", {round(r.frequency_hz, 3)}),')
//   "

enum iPadTurkishPitchReference {
    static let notes: [(name: String, hz: Double)] = [
        ("Do", 97.78),
        ("Do ♯4", 103.035),
        ("Re ♭5", 104.39),
        ("Re ♭1", 108.575),
        ("Re", 110.0),
        ("Re ♯4", 115.915),
        ("Mi ♭5", 117.44),
        ("Mi ♭1", 122.14),
        ("Mi", 123.75),
        ("Fa", 130.37),
        ("Fa ♯1", 132.09),
        ("Fa ♯4", 137.375),
        ("Sol ♭5", 139.185),
        ("Sol ♭1", 144.755),
        ("Sol", 146.665),
        ("Sol ♯4", 154.55),
        ("La ♭5", 156.585),
        ("La ♭1", 162.85),
        ("La", 165.0),
        ("La ♯4", 173.87),
        ("Si ♭5", 176.155),
        ("Si ♭1", 183.205),
        ("Si", 185.625),
        ("Si ♯3", 193.01),
        ("Do", 195.56),
        ("Do ♯4", 206.07),
        ("Re ♭5", 208.78),
        ("Re ♭1", 217.15),
        ("Re", 220.0),
        ("Re ♯4", 231.83),
        ("Mi ♭5", 234.88),
        ("Mi ♭1", 244.28),
        ("Mi", 247.5),
        ("Fa", 260.74),
        ("Fa ♯1", 264.18),
        ("Fa ♯4", 274.75),
        ("Sol ♭5", 278.37),
        ("Sol ♭1", 289.51),
        ("Sol", 293.33),
        ("Sol ♯4", 309.1),
        ("La ♭5", 313.17),
        ("La ♭1", 325.7),
        ("La", 330.0),
        ("La ♯4", 347.74),
        ("Si ♭5", 352.31),
        ("Si ♭1", 366.41),
        ("Si", 371.25),
        ("Si ♯3", 386.02),
        ("Do", 391.12),
        ("Do ♯4", 412.14),
        ("Re ♭5", 417.56),
        ("Re ♭1", 434.3),
        ("Re", 440.0),
        ("Re ♯4", 463.66),
        ("Mi ♭5", 469.76),
        ("Mi ♭1", 488.56),
        ("Mi", 495.0),
        ("Fa", 521.48),
        ("Fa ♯1", 528.36),
        ("Fa ♯4", 549.5),
        ("Sol ♭5", 556.74),
        ("Sol ♭1", 579.02),
        ("Sol", 586.66),
        ("Sol ♯4", 618.2),
        ("La ♭5", 626.34),
        ("La ♭1", 651.4),
        ("La", 660.0),
        ("La ♯4", 695.48),
        ("Si ♭5", 704.62),
        ("Si ♭1", 732.82),
        ("Si", 742.5),
        ("Si ♯3", 772.04),
        ("Do", 782.24),
    ]
}
