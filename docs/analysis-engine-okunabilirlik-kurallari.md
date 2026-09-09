# analysis_engine.cpp — "Python kadar okunaklı C++" kuralları

## A. Değişmezler (ihlal = iş reddedilir)
A1. Davranış birebir korunur. Aritmetik ifadelerin OPERAND SIRASI ve PARANTEZLEME
    aynen kalır. Floating-point yeniden ilişkilendirme (a+b+c -> c+b+a, ortak çarpan
    dışarı alma, `x*0.5` -> `x/2`) YASAK. Golden JSON çıktıları bit bit aynı olmalı.
A2. Public API değişmez: header'daki imzalar, sınıf/üye adları, dosya dışına görünen
    her şey aynı. `core/include/**` DEĞİŞTİRİLMEZ.
A3. Yeni `#include` eklenmez, mevcutlar silinmez. Yeni bağımlılık/kütüphane yok.
A4. Mevcut yorumlardaki bilgi kaybolmaz; taşınabilir, yeniden yazılabilir, ama
    açıklanan olgu (eşik neden 0.80, neden iki düşüş vs.) korunur.
A5. Değerler aynen: `.80` -> `0.80` gibi yazım normalizasyonu serbest, sayısal
    değer değişikliği yasak.

## B. Yapı (Python okunaklılığı)
B1. Bir satır = bir ifade. Aynı satırda birden çok statement yok. Tek satırlık
    `{ ... }` gövde yok. Tek istisna: `if (kosul) return {};` biçimindeki guard.
B2. Satır uzunluğu <= 100 karakter. Uzun ifadeler operatörden ÖNCE kırılır ve
    4 boşluk girintilenir.
B3. Fonksiyon <= ~40 satır ve tek bir iş yapar. Daha uzunsa, kod içindeki
    `// ...` blok başlıklarının her biri ayrı bir fonksiyona çıkarılır.
    - Anonim namespace'teki kod -> aynı anonim namespace'te serbest fonksiyon.
    - `ProductionPitchSession::process_frame` -> `Impl`'in private üye
      fonksiyonları (state zaten Impl'de; parametre trafiği böyle en az olur).
    Çıkarılan fonksiyonun adı, yerini aldığı yorum başlığının özetidir.
B4. Guard clause / erken çıkış tercih edilir; 3+ seviye iç içe `if` düzleştirilir.
B5. `impl_->` / uzun üye zincirleri fonksiyon başında yerel referansa alınır:
    `auto& state = *impl_;`

## C. İsimlendirme ve sabitler
C1. Sihirli sayı yok. Her eşik/katsayı, kullanıldığı kapsamda `constexpr` isimli
    sabit olur; tanımının ÜSTÜNDE ne olduğunu ve birimini söyleyen bir yorum durur.
    Örn. `constexpr double kSharpRmsDropRatio = 0.80;`
C2. Kısaltma yok, tam kelime: `idx`->`index`, `cfg`->`config`, `freq`->`frequency`.
C3. Bool isimleri `is_` / `has_` / `should_` / `_active` ile okunur cümle kurar.
C4. Yerel değişkenler mümkün olan en dar kapsamda ve `const`.

## D. Yorumlar
D1. Çok satırlı / "neden böyle" açıklamaları satır SONUNDA değil, açıkladığı
    satırın veya bloğun ÜSTÜNDE durur.
    İstisna (Python'daki `x = y  # not` muadili): tek satırlık kısa ek not,
    satır 100 karakteri aşmadığı sürece satır sonunda kalabilir.
    Ayrıca enum/struct alan listeleri hizalı tablo olarak bırakılabilir.
D2. Her fonksiyonun üstünde 1-4 satırlık, "ne yapar + neden böyle" anlatan bir
    blok yorum (Python docstring muadili) bulunur.
D3. Yorum kodu tekrar etmez; niyeti/nedeni anlatır.
D4. Yorum dili: mevcut dosyada İngilizce -> İngilizce kalır.

## E. Cast ve döngü gürültüsü
E1. İndeks döngüsü yerine range-for, indeks gerçekten gerekmiyorsa.
E2. `static_cast` yığını tekrarlanıyorsa, anonim namespace'te tek satırlık
    `to_index(int)` / `to_int(std::size_t)` gibi bir yardımcıya toplanır.
    Yardımcı, ORİJİNAL cast'ın tipini ve davranışını birebir korur.
E3. `std::size_t` <-> `int` dönüşümlerinde orijinal tipler değişmez.
