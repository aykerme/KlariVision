"""KlariVision perde motorlari — belgedeki Python orneklerinin tamami.

docs/perde-motorlari-nasil-calisir.html icindeki kod bloklari bu dosyadan
alinmistir. Ogretme amacli: gercek motorlarin karar mantigini okunabilir
bicimde yeniden yazar, uretim kodunun yerine gecmez.

Disa bagimliligi yoktur:

    python3 docs/perde-motorlari-ornekler.py
"""
import math


def sent(a, b):
    """Iki frekans arasindaki muzikal mesafe. Bir oktav = 1200 sent."""
    return abs(1200.0 * math.log2(a / b))


def kirp01(x):
    return max(0.0, min(1.0, x))



# ==========================================================================
# 2. YIN v1 — aday uretimi
# ==========================================================================
# --- 1. sentetik klarnet sesi ---
def klarnet(f0, sr, n):
    """Zayif temel, guclu 3. harmonik: kapali borunun tipik imzasi."""
    x = []
    for i in range(n):
        t = i / sr
        x.append(0.30 * math.sin(2*math.pi*f0*t)      # temel: zayif
               + 1.00 * math.sin(2*math.pi*3*f0*t)    # 3. harmonik: gur
               + 0.45 * math.sin(2*math.pi*5*f0*t))   # 5. harmonik
    return x

# --- 2. fark fonksiyonu d(tau) ---
def fark_fonksiyonu(x, tau_min, tau_max):
    d = [0.0] * (tau_max + 1)
    for tau in range(tau_min, tau_max + 1):
        toplam = 0.0
        for j in range(len(x) - tau):
            e = x[j] - x[j + tau]
            toplam += e * e            # farkin karesi
        d[tau] = toplam
    return d

# --- 3. CMND: kumulatif ortalama normalize edilmis fark ---
def cmnd(d, tau_max):
    dp = [1.0] * (tau_max + 1)         # d'(0) = 1 tanimlanir
    kosan_toplam = 0.0
    for tau in range(1, tau_max + 1):
        kosan_toplam += d[tau]
        if kosan_toplam > 0:
            dp[tau] = d[tau] * tau / kosan_toplam
    return dp

# --- 4. parabolik duzeltme ---
def parabolik(y, i):
    sol, orta, sag = y[i-1], y[i], y[i+1]
    payda = sol - 2*orta + sag
    if abs(payda) < 1e-12:
        return 0.0
    return max(-0.5, min(0.5, 0.5 * (sol - sag) / payda))

# --- 5. aday toplama: tek cevap degil, liste ---
def yin_adaylari(x, sr, f_min=120.0, f_max=1500.0, esik=0.50):
    tau_min = max(2, int(sr / f_max))
    tau_max = min(len(x) // 2, int(sr / f_min))
    d  = fark_fonksiyonu(x, tau_min, tau_max)
    dp = cmnd(d, tau_max)

    adaylar = []
    for tau in range(tau_min + 1, tau_max):
        yerel_minimum = dp[tau] <= dp[tau-1] and dp[tau] < dp[tau+1]
        if not (yerel_minimum and dp[tau] < esik):
            continue
        tau_yildiz = tau + parabolik(dp, tau)
        frekans = sr / tau_yildiz
        if f_min <= frekans <= f_max:
            adaylar.append({"frekans": frekans,
                            "guven": max(0.0, min(1.0, 1.0 - dp[tau])),
                            "lag": tau})
    adaylar.sort(key=lambda a: -a["guven"])
    return adaylar[:12]                # liste 12 adayla sinirli


# ==========================================================================
# 2. YIN v1 — secim merdiveni
# ==========================================================================
# --- 1. hayalet cezasi -------------------------------------------------
def hayalet_orani(spektrum, f):
    """spektrum: frekans -> genlik sozlugu (gercekte tek frekans DFT proble olculur)"""
    kendi = spektrum.get(f, 0.0)
    en_baskin = 0.0
    for kat in (2.0, 3.0):
        katin_genligi = spektrum.get(f * kat, 0.0)
        if katin_genligi <= 0:
            continue
        oran = katin_genligi / max(kendi, 1e-9)
        en_baskin = max(en_baskin, oran)
    return en_baskin

def hayalet_cezasi(spektrum, f, esik=6.0):
    oran = hayalet_orani(spektrum, f)
    if oran <= esik:
        return 0.0
    siddet = max(0.0, min(1.0, (oran - 6.0) / 20.0))
    return 0.15 * siddet

# --- 2. nedensel secim -------------------------------------------------
def nedensel_secim(adaylar, onceki, spektrum):
    if not adaylar:
        return None
    def duzeltilmis(a):
        return a["guven"] - hayalet_cezasi(spektrum, a["frekans"])

    if onceki is None:
        en_iyi = max(adaylar, key=duzeltilmis)
        secim = en_iyi if en_iyi["guven"] >= 0.76 else None
    else:
        secim, en_iyi_skor = None, float("-inf")
        for a in adaylar:
            if a["guven"] < 0.55:
                continue
            skor = duzeltilmis(a) - 0.30 * min(sent(a["frekans"], onceki["frekans"]) / 700.0, 1.0)
            if skor > en_iyi_skor:
                secim, en_iyi_skor = a, skor

    if secim is not None and hayalet_orani(spektrum, secim["frekans"]) > 6.0:
        return None
    return secim

# --- 3. asagi sicrama histerezisi --------------------------------------
class SicramaMuhafizi:
    def __init__(self, esik_sent=900.0, gereken_onay=3, tolerans_sent=360.0):
        self.esik_sent, self.gereken_onay, self.tolerans = esik_sent, gereken_onay, tolerans_sent
        self.bekleyen, self.onay = None, 0

    def gecir(self, secim, son_yayin):
        if secim is None or son_yayin is None:
            self.bekleyen, self.onay = None, 0
            return secim
        asagi = secim["frekans"] < son_yayin["frekans"]
        if not (asagi and sent(secim["frekans"], son_yayin["frekans"]) > self.esik_sent):
            self.bekleyen, self.onay = None, 0
            return secim
        if self.bekleyen and sent(secim["frekans"], self.bekleyen["frekans"]) < self.tolerans:
            self.onay += 1
            self.bekleyen = secim
            if self.onay < self.gereken_onay:
                return None
            self.bekleyen, self.onay = None, 0
            return secim
        self.bekleyen, self.onay = secim, 1
        return None


# ==========================================================================
# 3. Pitch Engine V2 — emisyon + sabit gecikmeli Viterbi
# ==========================================================================
# --- 1. emisyon puani --------------------------------------------------
def emisyon_puanlari(adaylar):
    """adaylar: [{'frekans','periyodiklik','kaynak','swipe'}]"""
    sonuc = []
    for a in adaylar:
        uzlasti = any(b["kaynak"] != a["kaynak"] and sent(b["frekans"], a["frekans"]) <= 55
                      for b in adaylar)
        uzlasma = 1.0 if uzlasti else 0.25
        puan = 0.40 * a["periyodiklik"] + 0.20 * uzlasma + 0.40 * a["swipe"]
        if a["kaynak"] == "spektral":
            puan = max(puan, 0.90)
        sonuc.append({**a, "uzlasti": uzlasti, "emisyon": puan})
    return sonuc

# --- 2. gecis cezasi ---------------------------------------------------
def gecis(a_hz, b_hz, genislik=700.0):
    c = sent(a_hz, b_hz)
    ceza = 0.18 * min(c / genislik, 1.0)
    if c >= 850.0:
        ceza += 0.12
    return -ceza

# --- 3. sabit gecikmeli Viterbi ---------------------------------------
def viterbi_coz(kareler):
    """kareler: her biri emisyonlu aday listesi. En eski karenin kararini dondurur."""
    onceki = [a["emisyon"] for a in kareler[0]]
    geri = []
    for k in range(1, len(kareler)):
        simdi = [float("-inf")] * len(kareler[k])
        isaret = [0] * len(kareler[k])
        for i, aday in enumerate(kareler[k]):
            for j, evvel in enumerate(kareler[k-1]):
                puan = onceki[j] + gecis(evvel["frekans"], aday["frekans"])
                if puan > simdi[i]:
                    simdi[i], isaret[i] = puan, j
            simdi[i] += aday["emisyon"]
        onceki, _ = simdi, geri.append(isaret)
    secili = max(range(len(onceki)), key=lambda i: onceki[i])
    for isaret in reversed(geri):
        secili = isaret[secili]
    return kareler[0][secili]

class SabitGecikmeliIzleyici:
    def __init__(self, gecikme=5):
        self.gecikme, self.tampon = gecikme, []
    def it(self, adaylar):
        self.tampon.append(adaylar)
        if len(self.tampon) <= self.gecikme:
            return None
        karar = viterbi_coz(self.tampon)
        self.tampon.pop(0)
        return karar
    def bitir(self):
        while self.tampon:
            yield viterbi_coz(self.tampon)
            self.tampon.pop(0)


# ==========================================================================
# 4. VPM-like — kabul kurali, rafine, veto durum makinesi
# ==========================================================================
# --- 1. kabul kurali: en guclunun %90'ini gecen EN KISA lag -------------
def kabul_edilen_lag(r, tepeler, en_az_periyodiklik=0.38, yakinlik=0.90):
    en_guclu = max(tepeler, key=lambda t: r[t])
    if r[en_guclu] < en_az_periyodiklik:
        return None, None
    esik = max(en_az_periyodiklik, r[en_guclu] * yakinlik)
    for tepe in tepeler:                 # tepeler artan lag sirasinda
        if r[tepe] >= esik:
            return tepe, en_guclu
    return en_guclu, en_guclu

# --- 2. katlardan periyot rafinesi -------------------------------------
def kat_rafinesi(r, secili, tau_max, en_az_periyodiklik=0.38, en_yuksek_kat=6):
    agirlikli = secili * r[secili]
    agirlik_toplam = r[secili]
    for kat in range(2, en_yuksek_kat + 1):
        beklenen = secili * kat
        if beklenen + 2 >= tau_max:
            break
        yaricap = max(2, secili // 6)
        aralik = range(max(1, beklenen - yaricap), min(tau_max - 1, beklenen + yaricap) + 1)
        yerel = max(aralik, key=lambda t: r[t])
        if r[yerel] < en_az_periyodiklik * 0.8:
            continue
        agirlik = r[yerel] * kat
        agirlikli += (yerel / kat) * agirlik
        agirlik_toplam += agirlik
    return agirlikli / max(1e-12, agirlik_toplam)

# --- 3. spektral akraba duzeltmesi -------------------------------------
def spektral_duzeltme(acf_hz, spektrum, secili, en_guclu,
                      f_min=120.0, f_max=1650.0,
                      goreli=0.080, mutlak=0.005):
    taban = spektrum(acf_hz)
    akrabalar = sorted([acf_hz/3, acf_hz/2, acf_hz, acf_hz*2, acf_hz*3])
    for f in akrabalar:
        if not (f_min <= f <= f_max):
            continue
        genlik = spektrum(f)
        yan = max(1.0, f * 0.012)
        yerel_tepe = genlik >= spektrum(f - yan) * 1.03 and genlik >= spektrum(f + yan) * 1.03
        if not (yerel_tepe and genlik >= mutlak and
                (taban <= 1e-12 or genlik >= taban * goreli)):
            continue
        if f > acf_hz:                       # kisit 1: yukari terfi yasak
            continue
        if f < acf_hz and secili == en_guclu:  # kisit 2: ACF zaten en gucluyu sectiyse
            continue
        return f
    return acf_hz

# --- 4. asagi harmonik sicramasi muhafizi ------------------------------
def harmonik_sicramasi(onceki, simdiki):
    if simdiki >= onceki or abs(sent(simdiki, onceki)) < 650.0:
        return False
    return any(abs(sent(simdiki / onceki, oran)) <= 110.0
               for oran in (1/3, 1/2, 2/3))

class VPMIzleyici:
    def __init__(self, gereken_onay=3):
        self.gereken_onay = gereken_onay
        self.sifirla()

    def sifirla(self):
        self.yayin, self.bekleyen, self.onay = None, None, 0

    def islet(self, tahmin, ust_hat_orani=None):
        if tahmin is None:
            self.sifirla(); return None, "sessizlik"
        if self.yayin is None:
            self.yayin = tahmin; return tahmin, "ilk"
        if not harmonik_sicramasi(self.yayin, tahmin):
            self.bekleyen, self.onay = None, 0
            self.yayin = tahmin; return tahmin, "olagan"
        if ust_hat_orani is not None and ust_hat_orani >= 2.5:
            self.bekleyen, self.onay = None, 0
            return self.yayin, "veto (ust hat 2,5x gur)"
        if ust_hat_orani is None:
            self.bekleyen, self.onay = None, 0
            self.yayin = tahmin; return tahmin, "rakip kanit yok, kabul"
        if self.bekleyen and abs(sent(tahmin, self.bekleyen)) <= 180.0:
            self.onay += 1
        else:
            self.bekleyen, self.onay = tahmin, 1
        if self.onay >= self.gereken_onay:
            self.yayin, self.bekleyen, self.onay = tahmin, None, 0
            return tahmin, "onaylandi"
        return self.yayin, f"beklet ({self.onay}/{self.gereken_onay})"


# ==========================================================================
# 5. HAPT v1 — harmonikler-arasi veto, iki esikli histerezis
# ==========================================================================
# --- 1. bir adayin veto kanitlari --------------------------------------
def izgara_vetosu(spektrum, f, kaydirmalar, harmonik_sayisi=5):
    """kaydirmalar: yarim izgara icin [-0.5], ucte bir icin [-1/3, -2/3]"""
    kendi = sum(spektrum(k * f) ** 2 for k in range(1, harmonik_sayisi + 1))
    izgara = sum(spektrum((k + kay) * f) ** 2
                 for k in range(1, harmonik_sayisi + 1) for kay in kaydirmalar)
    toplam = kendi + izgara
    return (kirp01(izgara / toplam) if toplam > 1e-18 else 0.0), kendi

def tek_harmonik_dolulugu(spektrum, f, harmonik_sayisi=5, esik=0.10):
    genlikler = {k: spektrum(k * f) for k in range(1, harmonik_sayisi + 1)}
    en_gur = max(genlikler.values())
    tekler = [k for k in (1, 3, 5) if k in genlikler]
    if not tekler:
        return 1.0
    mevcut = sum(1 for k in tekler if en_gur > 1e-12 and genlikler[k] >= esik * en_gur)
    return mevcut / len(tekler)

# --- 2. iki gecisli puanlama -------------------------------------------
def hapt_puanla(adaylar, spektrum, onceki_hz=None):
    on_hazirlik = []
    en_yuksek_enerji = 0.0
    for a in adaylar:
        f = a["frekans"]
        yarim_veto, kendi_enerjisi = izgara_vetosu(spektrum, f, [-0.5])
        ucte_bir_veto, _           = izgara_vetosu(spektrum, f, [-1/3, -2/3])
        doluluk = tek_harmonik_dolulugu(spektrum, f)
        en_yuksek_enerji = max(en_yuksek_enerji, kendi_enerjisi)
        on_hazirlik.append({**a, "yarim_veto": yarim_veto, "ucte_bir_veto": ucte_bir_veto,
                            "doluluk": doluluk, "enerji": kendi_enerjisi})

    sonuc = []
    for a in on_hazirlik:
        anlamlilik = kirp01(a["enerji"] / en_yuksek_enerji) if en_yuksek_enerji > 1e-18 else 0.0
        anlamlilik_carpani = 0.10 + 0.90 * anlamlilik
        doluluk_carpani    = 0.35 + 0.65 * a["doluluk"]
        etkin_doluluk      = 1.0 - anlamlilik * (1.0 - doluluk_carpani)
        bonus = 0.0
        if onceki_hz:
            bonus = max(0.0, min(0.10, 0.10 * (1.0 - sent(a["frekans"], onceki_hz) / 700.0)))
        puan = kirp01(a["periyodiklik"] * etkin_doluluk * anlamlilik_carpani
                      * (1.0 - 0.9 * a["yarim_veto"]) * (1.0 - 0.9 * a["ucte_bir_veto"]) + bonus)
        sonuc.append({**a, "anlamlilik": anlamlilik, "puan": puan})
    return sorted(sonuc, key=lambda a: -a["puan"])

# --- 3. iki esikli histerezis ------------------------------------------
def yayinlanabilir(aday, onceki_hz, onset=0.55, sustain=0.32, kontur_sent=180.0):
    yakin = onceki_hz is not None and sent(aday["frekans"], onceki_hz) <= kontur_sent
    esik = sustain if yakin else onset
    return aday["periyodiklik"] >= esik, esik


# ==========================================================================
# 7. Cevrimdisi katman — yol iyilestirmesi, basibos kosu
# ==========================================================================
TABAN, ISKONTO, GENISLIK, EN_COK_GECIS, BOLUM_BOSLUGU = 0.30, 0.72, 150.0, 12.0, 0.030

# --- 1. her kare icin harmonik ailesi ve fiyati -------------------------
def katmanlar(iz, spektrum, f_min=120.0, f_max=1500.0):
    cikti = []
    for indeks, kare in enumerate(iz):
        if not kare["frekans"]:
            continue
        yayin, guven = kare["frekans"], max(kare["guven"], 1e-3)
        secenekler = [{"frekans": yayin, "puan": guven}]     # nedensel karar: indirimsiz
        # Kapali silindirin gercekten urettigi merdiven: 4x ve 5x de dahil.
        oranlar = (0.2, 0.25, 1/3, 0.5, 2.0, 3.0, 4.0, 5.0)
        aile = [yayin] + [yayin * o for o in oranlar]
        aile = [f for f in aile if f_min <= f <= f_max]
        enerjiler = {f: spektrum(indeks, f) for f in aile}
        en_guclu = max(enerjiler.values()) if enerjiler else 0.0
        for f in aile[1:]:
            destek = enerjiler[f] / en_guclu if en_guclu > 0 else 0.0
            arka = TABAN + (1.0 - TABAN) * max(0.0, min(1.0, destek))
            secenekler.append({"frekans": f, "puan": guven * ISKONTO * arka})
        cikti.append({"indeks": indeks, "secenekler": secenekler})
    return cikti

# --- 2. karesel gecis cezali yol aramasi -------------------------------
def yolu_coz(iz, kat):
    if len(kat) < 3:
        return iz
    skor = [[math.log(max(s["puan"], 1e-6)) for s in kat[0]["secenekler"]]]
    geri = []
    for k in range(1, len(kat)):
        surekli = (iz[kat[k]["indeks"]]["zaman"] - iz[kat[k-1]["indeks"]]["zaman"]) <= BOLUM_BOSLUGU
        simdi, isaret = [], []
        for s in kat[k]["secenekler"]:
            en_iyi, secilen = float("-inf"), 0
            for j, evvel in enumerate(kat[k-1]["secenekler"]):
                gecis = 0.0
                if surekli:
                    d = sent(s["frekans"], evvel["frekans"]) / GENISLIK
                    gecis = -min(d * d, EN_COK_GECIS)
                toplam = skor[k-1][j] + gecis
                if toplam > en_iyi:
                    en_iyi, secilen = toplam, j
            simdi.append(en_iyi + math.log(max(s["puan"], 1e-6)))
            isaret.append(secilen)
        skor.append(simdi)
        geri.append(isaret)

    iyilestirilmis = [dict(k) for k in iz]
    imlec = max(range(len(skor[-1])), key=lambda i: skor[-1][i])
    for k in range(len(kat) - 1, -1, -1):
        secenek = kat[k]["secenekler"][imlec]
        iyilestirilmis[kat[k]["indeks"]]["frekans"] = secenek["frekans"]
        imlec = geri[k-1][imlec] if k > 0 else 0
    return iyilestirilmis

# --- 3. basibos kosu temizligi -----------------------------------------
def basibos_kosulari_at(iz, en_cok_kare=7, yalitim=0.040, guven_esigi=0.80):
    sesli = [i for i, k in enumerate(iz) if k["frekans"]]
    if len(sesli) < 2:
        return iz
    kosular, bas = [], 0
    for p in range(1, len(sesli) + 1):
        ayir = p == len(sesli) or iz[sesli[p]]["zaman"] - iz[sesli[p-1]]["zaman"] > 0.012
        if ayir:
            kosular.append((bas, p - 1)); bas = p
    at = set()
    for n, (ilk, son) in enumerate(kosular):
        if son - ilk + 1 > en_cok_kare:
            continue
        once = math.inf if n == 0 else iz[sesli[ilk]]["zaman"] - iz[sesli[kosular[n-1][1]]]["zaman"]
        sonra = math.inf if n + 1 == len(kosular) else iz[sesli[kosular[n+1][0]]]["zaman"] - iz[sesli[son]]["zaman"]
        if once < yalitim or sonra < yalitim:
            continue
        if max(iz[sesli[p]]["guven"] for p in range(ilk, son + 1)) >= guven_esigi:
            continue
        at.update(sesli[p] for p in range(ilk, son + 1))
    return [k for i, k in enumerate(iz) if i not in at]


if __name__ == "__main__":
    print("\n### 2. YIN v1 — aday uretimi")
    SR = 44100
    for a in yin_adaylari(klarnet(220.0, SR, 1536), SR):
        print(f"{a['frekans']:8.2f} Hz   guven {a['guven']:.3f}   lag {a['lag']}")

    print("\n### 2. YIN v1 — secim merdiveni")
    spektrum = {220.0: 0.02, 440.0: 0.03, 660.0: 0.90, 1100.0: 0.40}
    adaylar = [{"frekans": 220.0, "guven": 0.94}, {"frekans": 660.0, "guven": 0.88}]
    print("hayalet orani 220 Hz :", round(hayalet_orani(spektrum, 220.0), 1))
    print("ceza 220 Hz          :", round(hayalet_cezasi(spektrum, 220.0), 3))
    print("onceki yok  ->", nedensel_secim(adaylar, None, spektrum))
    print("onceki 660  ->", nedensel_secim(adaylar, {"frekans": 660.0}, spektrum))
    
    print("\n--- sicrama muhafizi ---")
    m = SicramaMuhafizi()
    son = {"frekans": 660.0}
    for i, f in enumerate([330.0, 330.0, 331.0, 329.0], 1):
        cikti = m.gecir({"frekans": f, "guven": 0.9}, son)
        if cikti:
            son = cikti                      # yayinlandi: yeni sureklilik capasi
            print(f"kare {i}: aday {f:6.1f} Hz  ->  YAYIN")
        else:
            print(f"kare {i}: aday {f:6.1f} Hz  ->  beklet (onay {m.onay}/3)")

    print("\n### 3. Pitch Engine V2 — emisyon + sabit gecikmeli Viterbi")
    def saglam_kare():
        """440 Hz iki tahminci tarafindan da bulunmus: uzlasma var."""
        return emisyon_puanlari([
            {"frekans": 440.0, "periyodiklik": 0.95, "kaynak": "yin", "swipe": 0.90},
            {"frekans": 440.0, "periyodiklik": 0.93, "kaynak": "mpm", "swipe": 0.90},
            {"frekans": 220.0, "periyodiklik": 0.60, "kaynak": "yin", "swipe": 0.30},
        ])
    
    def bozuk_kare():
        """Tek kare: 220 Hz uzlasma da kazaniyor, 440 Hz cokuyor."""
        return emisyon_puanlari([
            {"frekans": 220.0, "periyodiklik": 0.75, "kaynak": "yin", "swipe": 0.55},
            {"frekans": 220.0, "periyodiklik": 0.74, "kaynak": "mpm", "swipe": 0.55},
            {"frekans": 440.0, "periyodiklik": 0.62, "kaynak": "yin", "swipe": 0.55},
        ])
    
    dizi = [saglam_kare(), saglam_kare(), bozuk_kare(),
            saglam_kare(), saglam_kare(), saglam_kare()]
    
    print("--- nedensel (kare basina en yuksek emisyon) ---")
    for i, k in enumerate(dizi, 1):
        en = max(k, key=lambda a: a["emisyon"])
        print(f"  kare {i}: {en['frekans']:6.1f} Hz  (emisyon {en['emisyon']:.2f})")
    
    print("--- 5 kare gecikmeli Viterbi ---")
    iz = SabitGecikmeliIzleyici(gecikme=5)
    cikti = [iz.it(k) for k in dizi]
    cikti = [c for c in cikti if c] + list(iz.bitir())
    for i, c in enumerate(cikti, 1):
        print(f"  kare {i}: {c['frekans']:6.1f} Hz")

    print("\n### 4. VPM-like — kabul kurali, rafine, veto durum makinesi")
    r = [0.0] * 500
    for lag, deger in [(100, 0.92), (200, 0.95), (300, 0.88), (400, 0.90)]:
        r[lag] = deger
    tepeler = [100, 200, 300, 400]
    secili, en_guclu = kabul_edilen_lag(r, tepeler)
    print(f"en guclu tepe: lag {en_guclu} (r={r[en_guclu]})")
    print(f"secilen tepe : lag {secili} (r={r[secili]})  <- daha kisa lag, %90 esigini geciyor")
    
    print("\n--- izleyici ---")
    iz = VPMIzleyici()
    senaryo = [(440.0, None), (220.0, 3.0), (220.0, 3.0), (220.0, 1.2), (220.0, 1.2), (220.0, 1.2)]
    for i, (tahmin, oran) in enumerate(senaryo, 1):
        cikti, sebep = iz.islet(tahmin, oran)
        print(f"  kare {i}: tahmin {tahmin:6.1f}  ->  yayin {cikti:6.1f}   [{sebep}]")

    print("\n### 5. HAPT v1 — harmonikler-arasi veto, iki esikli histerezis")
    # Gercek nota 440 Hz: klarnet, tek harmonikler gur (440, 1320, 2200),
    # cift harmonikler zayif. Rakip aday 220 Hz (bir oktav asagi hayalet).
    hatlar = {440: 0.50, 880: 0.05, 1320: 1.00, 1760: 0.04, 2200: 0.45}
    def spektrum(f):
        for hat, genlik in hatlar.items():
            if abs(f - hat) < 12:
                return genlik
        return 0.002                      # gurultu tabani
    
    adaylar = [{"frekans": 220.0, "periyodiklik": 0.93},
               {"frekans": 440.0, "periyodiklik": 0.91}]
    for a in hapt_puanla(adaylar, spektrum):
        print(f"{a['frekans']:6.1f} Hz | periyodiklik {a['periyodiklik']:.2f} "
              f"| yarim veto {a['yarim_veto']:.2f} | doluluk {a['doluluk']:.2f} "
              f"| anlamlilik {a['anlamlilik']:.2f} | PUAN {a['puan']:.3f}")
    
    print("\n--- iki esikli histerezis ---")
    for onceki in (None, 435.0):
        tamam, esik = yayinlanabilir({"frekans": 440.0, "periyodiklik": 0.40}, onceki)
        etiket = "kontur yok (onset)" if onceki is None else "konturun 180 senti icinde (sustain)"
        print(f"  {etiket:38s} esik {esik:.2f}  ->  {'yayin' if tamam else 'sessiz'}")

    print("\n### 7. Cevrimdisi katman — yol iyilestirmesi, basibos kosu")
    hop = 0.0116
    iz = [{"zaman": i * hop, "frekans": 440.0, "guven": 0.90} for i in range(8)]
    iz[4]["frekans"], iz[4]["guven"] = 220.0, 0.85        # tek karelik oktav hatasi
    
    def spektrum(indeks, f):                              # 440 her karede gercekten gur
        return 1.0 if abs(f - 440.0) < 5 else 0.02
    
    print("once :", [round(k["frekans"]) for k in iz])
    print("sonra:", [round(k["frekans"]) for k in yolu_coz(iz, katmanlar(iz, spektrum))])
    
    print("\n--- basibos kosu ---")
    iz2 = ([{"zaman": i*hop, "frekans": 440.0, "guven": 0.9} for i in range(6)]
         + [{"zaman": 0.30 + i*hop, "frekans": 300.0, "guven": 0.7} for i in range(3)]
         + [{"zaman": 0.60 + i*hop, "frekans": 440.0, "guven": 0.9} for i in range(6)])
    print("once :", len(iz2), "kare")
    print("sonra:", len(basibos_kosulari_at(iz2)), "kare  (yalitilmis 3 karelik 300 Hz kosusu atildi)")
