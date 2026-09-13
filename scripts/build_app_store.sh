#!/bin/zsh
#
# Mac App Store arşivi: motoru iki mimari için ayrı ayrı derler (Apple
# Silicon + Intel), Release archive alır, her iki motor klasöründeki her
# Mach-O'yu içten dışa imzalar, ana app'i imzalar ve App Store Connect'e
# yüklenebilir bir paket üretmek üzere -exportArchive çalıştırır.
#
# `imageio_ffmpeg` bilerek paketten dışlanır: motor artık ffmpeg'e ihtiyaç
# duymuyor -- ses/video kaynağı native Swift katmanında AVFoundation ile
# 48 kHz mono WAV'a çözülüp motora hazır veriliyor (bkz.
# macos/KlariVision/Sources/KlariVisionApp/MediaToWAVConverter.swift ve
# docs/app-store/ffmpeg-replacement.md). `yt_dlp` zaten ffmpeg'e bağlıydı;
# ikisi de dışlanınca linkten açma App Store paketinde koddan erişilemez
# kalır (Yönerge 5.2.3).
#
# Universal (arm64 + x86_64): PyInstaller'ın universal2 modu numpy gibi
# derlenmiş bağımlılıklarla güvenilir değil, bu yüzden motor iki mimari için
# ayrı ayrı kurulur ve pakete `Contents/Resources/Engine-arm64` ile
# `Engine-x86_64` olarak konur; native Swift tarafı (`bundledEngineExecutable()`,
# KlariVisionApp.swift + LivePitchAnalyzer.swift) çalışma zamanı mimarisine
# göre doğru klasörü seçer. x86_64 motoru için gereken x86_64 Python ortamı
# bu betik tarafından KURULMAZ/İNDİRİLMEZ -- `KV_X86_PYTHON` ile verilmesi
# gerekir (ön koşullar için aşağıdaki hata mesajına bak).
#
# Gerçek imzalamayı çalıştırma (kimlik yok); bu betik ortam değişkenleri
# eksikse anlaşılır bir hatayla çıkar, sahte kimlikle imzalamayı denemez.
#
# Zorunlu ortam değişkenleri:
#   KV_TEAM_ID            Apple Developer Team ID (ör. ABCDE12345)
#   KV_APP_IDENTITY       "Apple Distribution: ..." imza kimliği (app + Engine)
#   KV_INSTALLER_IDENTITY "3rd Party Mac Developer Installer: ..." kimliği
#                         (yalnız -exportArchive'ın installer paketi ürettiği
#                         akışlarda kullanılır; App Store Connect app'leri için
#                         xcodebuild -exportArchive bunu kendi profil/kimlik
#                         seçimiyle yönetir, burada yalnız doğrulanır)
#   KV_PROVISIONING_PROFILE  developer.apple.com'dan indirilen "Mac App Store
#                         Connect" dağıtım profili (.provisionprofile) yolu.
#                         Pakete Contents/embedded.provisionprofile olarak
#                         gömülür; App Store Connect profilsiz Mac uygulamasını
#                         kabul etmez.
#   KV_X86_PYTHON         x86_64 için PyInstaller + proje bağımlılıklarının
#                         (numpy, openpyxl, ...) kurulu olduğu bir Python
#                         yorumlayıcısının yolu (ör. Rosetta altında kurulmuş
#                         ayrı bir venv'in "bin/python"ı). Bu betik böyle bir
#                         ortam kurmaz; önceden hazırlanmış olmalı:
#                           arch -x86_64 /usr/bin/python3 -m venv .venv-x86_64
#                           arch -x86_64 .venv-x86_64/bin/pip install \
#                             -r requirements.txt pyinstaller
#                         (tam bağımlılık listesi için mevcut .venv'in nasıl
#                         kurulduğuna bak; iki venv'in sürümleri eşleşmeli.)

set -euo pipefail

fail() {
  echo "HATA: $1" >&2
  exit 1
}

: "${KV_TEAM_ID:?KV_TEAM_ID ortam değişkeni gerekli (Apple Developer Team ID).}"
: "${KV_APP_IDENTITY:?KV_APP_IDENTITY ortam değişkeni gerekli (\"Apple Distribution: ...\" imza kimliği).}"
: "${KV_INSTALLER_IDENTITY:?KV_INSTALLER_IDENTITY ortam değişkeni gerekli (\"3rd Party Mac Developer Installer: ...\" kimliği).}"
: "${KV_PROVISIONING_PROFILE:?KV_PROVISIONING_PROFILE ortam değişkeni gerekli (Mac App Store Connect dağıtım profili .provisionprofile yolu).}"
[ -f "$KV_PROVISIONING_PROFILE" ] || fail "KV_PROVISIONING_PROFILE ($KV_PROVISIONING_PROFILE) bulunamadı."
: "${KV_X86_PYTHON:?KV_X86_PYTHON ortam değişkeni gerekli: x86_64 motoru için PyInstaller + proje bağımlılıklarının kurulu olduğu bir Python yorumlayıcısının yolu (bkz. bu betiğin başındaki açıklama). Universal derleme bu ortam olmadan yapılamaz.}"

[ -x "$KV_X86_PYTHON" ] || fail "KV_X86_PYTHON ($KV_X86_PYTHON) çalıştırılabilir bir dosya değil."
if ! "$KV_X86_PYTHON" -c 'import platform, sys; sys.exit(0 if platform.machine() == "x86_64" else 1)'; then
  fail "KV_X86_PYTHON ($KV_X86_PYTHON) x86_64 mimarisinde çalışmıyor (platform.machine() x86_64 döndürmedi)."
fi

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_FILE="$PROJECT_ROOT/macos/KlariVision/KlariVision.xcodeproj"
ENTITLEMENTS_APP="$PROJECT_ROOT/macos/KlariVision/KlariVision.entitlements"
ENTITLEMENTS_ENGINE="$PROJECT_ROOT/macos/KlariVision/Engine.entitlements"

[ -f "$ENTITLEMENTS_APP" ] || fail "$ENTITLEMENTS_APP bulunamadı."
[ -f "$ENTITLEMENTS_ENGINE" ] || fail "$ENTITLEMENTS_ENGINE bulunamadı."

DERIVED_DATA="$PROJECT_ROOT/build/KlariVisionAppStoreDD"
ARCHIVE_PATH="$PROJECT_ROOT/build/KlariVision.xcarchive"
EXPORT_PATH="$PROJECT_ROOT/build/KlariVisionAppStoreExport"
EXPORT_OPTIONS="$PROJECT_ROOT/build/ExportOptions.plist"
ARCHIVE_APP="$ARCHIVE_PATH/Products/Applications/KlariVision.app"
ICON_FILE="$PROJECT_ROOT/macos/KlariVision/Resources/KlariVision.icns"
PITCH_TRACK_CLI="$PROJECT_ROOT/build/klarivision-pitch-track-cli-universal"

rm -rf "$ARCHIVE_PATH" "$EXPORT_PATH"

# Profilden kimlikleri oku: ExportOptions eşlemesi ve imza izinleri bunlara dayanır.
PROFILE_PLIST="$PROJECT_ROOT/build/provisioning-profile.plist"
mkdir -p "$PROJECT_ROOT/build"
security cms -D -i "$KV_PROVISIONING_PROFILE" > "$PROFILE_PLIST"
PROFILE_UUID="$(plutil -extract UUID raw "$PROFILE_PLIST")"
PROFILE_TEAM="$(plutil -extract TeamIdentifier.0 raw "$PROFILE_PLIST")"
BUNDLE_ID="$(xcodebuild -project "$PROJECT_FILE" -scheme KlariVision -configuration Release -showBuildSettings 2>/dev/null | awk -F' = ' '/ PRODUCT_BUNDLE_IDENTIFIER = / {print $2; exit}')"
PROFILE_APP_ID="$(plutil -extract Entitlements.com\\.apple\\.application-identifier raw "$PROFILE_PLIST")"
[ "$PROFILE_TEAM" = "$KV_TEAM_ID" ] || fail "Profilin takımı ($PROFILE_TEAM) KV_TEAM_ID ($KV_TEAM_ID) ile aynı değil."
[ "$PROFILE_APP_ID" = "$KV_TEAM_ID.$BUNDLE_ID" ] || fail "Profil $PROFILE_APP_ID için; uygulama $KV_TEAM_ID.$BUNDLE_ID."

# App Store imzası uygulama kimliğini ve takımı izinlerde taşımalı; Xcode bunu
# otomatik imzada profilden ekler, burada elle imzaladığımız için biz ekliyoruz.
SIGNING_ENTITLEMENTS="$PROJECT_ROOT/build/KlariVision.signing.entitlements"
cp "$ENTITLEMENTS_APP" "$SIGNING_ENTITLEMENTS"
plutil -insert "com\\.apple\\.application-identifier" -string "$KV_TEAM_ID.$BUNDLE_ID" "$SIGNING_ENTITLEMENTS"
plutil -insert "com\\.apple\\.developer\\.team-identifier" -string "$KV_TEAM_ID" "$SIGNING_ENTITLEMENTS"

CORE_SOURCES=(
  "$PROJECT_ROOT/core/src/analysis_engine.cpp"
  "$PROJECT_ROOT/core/src/analysis_engine_c.cpp"
  "$PROJECT_ROOT/core/src/harmonic_arbitration.cpp"
  "$PROJECT_ROOT/core/src/harmonic_probe.cpp"
  "$PROJECT_ROOT/core/src/mpm.cpp"
  "$PROJECT_ROOT/core/src/fixed_lag_tracker.cpp"
  "$PROJECT_ROOT/core/src/swipe_prime.cpp"
  "$PROJECT_ROOT/core/src/pyin_ladder.cpp"
  "$PROJECT_ROOT/core/src/frame_spectrum.cpp"
  "$PROJECT_ROOT/core/src/harmonic_evidence.cpp"
  "$PROJECT_ROOT/core/src/unified_track_decoder.cpp"
  "$PROJECT_ROOT/core/src/unified_pitch_session.cpp"
  "$PROJECT_ROOT/core/tools/pitch_track_cli.cpp"
)

# --- 1. Native pitch-track CLI: tek bir universal (arm64 + x86_64) ikili ---
# --- olarak derlenir, her iki motor klasörüne de aynı dosya eklenir.       ---

clang++ -std=c++20 -O3 -arch arm64 -arch x86_64 -I "$PROJECT_ROOT/core/include" \
  "${CORE_SOURCES[@]}" \
  -framework Accelerate \
  -o "$PITCH_TRACK_CLI"

build_engine() {
  local arch_name="$1"
  local python_bin="$2"
  local dist_dir="$PROJECT_ROOT/build/KlariVisionEngineDist-${arch_name}"
  local work_dir="$PROJECT_ROOT/build/KlariVisionEngineWork-${arch_name}"
  local spec_dir="$PROJECT_ROOT/build/KlariVisionEngineSpec-${arch_name}"

  rm -rf "$dist_dir" "$work_dir" "$spec_dir"

  "$python_bin" -m PyInstaller \
    --noconfirm \
    --clean \
    --onedir \
    --name KlariVisionEngine \
    --distpath "$dist_dir" \
    --workpath "$work_dir" \
    --specpath "$spec_dir" \
    --paths "$PROJECT_ROOT/src" \
    --collect-all numpy \
    --collect-all openpyxl \
    --exclude-module yt_dlp \
    --exclude-module imageio_ffmpeg \
    --exclude-module curl_cffi \
    --exclude-module librosa \
    --exclude-module scipy \
    --exclude-module soundfile \
    --exclude-module numba \
    --exclude-module sklearn \
    --add-data "$PROJECT_ROOT/data/reference/perde-esleme.xlsx:data/reference" \
    --add-data "$PROJECT_ROOT/data/reference/Turk_Muzigi_Perdeleri_ve_Mikrotonal_Notasyon.xlsx:data/reference" \
    --add-binary="${PITCH_TRACK_CLI}:tools" \
    "$PROJECT_ROOT/src/klarivision/engine_cli.py"

  echo "$dist_dir/KlariVisionEngine"
}

# --- 2. Motoru iki mimari için ayrı ayrı kur ---

echo "KlariVision: arm64 motoru kuruluyor…"
ENGINE_ARM64="$(build_engine arm64 "$PROJECT_ROOT/.venv/bin/python")"
echo "KlariVision: x86_64 motoru kuruluyor (KV_X86_PYTHON)…"
ENGINE_X86_64="$(build_engine x86_64 "$KV_X86_PYTHON")"

# --- 3. Release arşivi. Xcode'un kendi "Embed bundled analysis engine" ---
# --- betiği archive sırasında da çalışıp tek mimarili (arm64) bir       ---
# --- "Engine" klasörü bırakır; adım 5 bunu siler ve yerine arch-özel    ---
# --- klasörleri koyar.                                                  ---

xcodebuild archive \
  -project "$PROJECT_FILE" \
  -scheme KlariVision \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  -derivedDataPath "$DERIVED_DATA" \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  DEVELOPMENT_TEAM="$KV_TEAM_ID" \
  CODE_SIGN_IDENTITY="$KV_APP_IDENTITY" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGNING_ALLOWED=NO

[ -d "$ARCHIVE_APP" ] || fail "Arşiv üretilemedi: $ARCHIVE_APP bulunamadı."

# --- 4. Simge + Info.plist ikon anahtarı ---

mkdir -p "$ARCHIVE_APP/Contents/Resources"
cp "$ICON_FILE" "$ARCHIVE_APP/Contents/Resources/KlariVision.icns"
/usr/libexec/PlistBuddy -c "Set :CFBundleIconFile KlariVision" "$ARCHIVE_APP/Contents/Info.plist"

# --- 5. Motorları arşivdeki app'e koy: Xcode'un tek-mimarili "Engine"     ---
# --- klasörünü kaldır, yerine "Engine-arm64" ve "Engine-x86_64" koy.      ---

rm -rf "$ARCHIVE_APP/Contents/Resources/Engine"
ditto "$ENGINE_ARM64" "$ARCHIVE_APP/Contents/Resources/Engine-arm64"
ditto "$ENGINE_X86_64" "$ARCHIVE_APP/Contents/Resources/Engine-x86_64"

# --- 6. Her iki motor klasöründeki her Mach-O'yu içten dışa imzala      ---
# --- (dylib, .so, ikililer). Sıralama önemli: bir ikiliye bağımlı        ---
# --- dylib'ler ondan önce imzalanmalı, bu yüzden en derinden en sığa     ---
# --- doğru gidiyoruz (find -depth).                                     ---

is_macho() {
  file -b "$1" 2>/dev/null | grep -q "Mach-O"
}

for engine_dir in "$ARCHIVE_APP/Contents/Resources/Engine-arm64" "$ARCHIVE_APP/Contents/Resources/Engine-x86_64"; do
  find "$engine_dir" -depth -type f \( -name "*.dylib" -o -name "*.so" -o -perm -u+x \) -print0 |
    while IFS= read -r -d '' candidate; do
      if is_macho "$candidate"; then
        codesign --force --options runtime --timestamp \
          --entitlements "$ENTITLEMENTS_ENGINE" \
          --sign "$KV_APP_IDENTITY" \
          "$candidate"
      fi
    done
done

# --- 7. Ana app'i imzala (--deep KULLANMA: her Mach-O zaten içten dışa ---
# --- ayrı ayrı imzalandı; --deep bunların üstüne yanlış/gereksiz bir    ---
# --- ikinci imza daha atardı).                                          ---

cp "$KV_PROVISIONING_PROFILE" "$ARCHIVE_APP/Contents/embedded.provisionprofile"

codesign --force --options runtime --timestamp \
  --entitlements "$SIGNING_ENTITLEMENTS" \
  --sign "$KV_APP_IDENTITY" \
  "$ARCHIVE_APP"

codesign --verify --deep --strict --verbose=2 "$ARCHIVE_APP" || fail "codesign doğrulaması başarısız."

# --- 8. ExportOptions.plist + -exportArchive (method: app-store-connect) ---

cat > "$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>app-store-connect</string>
    <key>teamID</key>
    <string>${KV_TEAM_ID}</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>${KV_APP_IDENTITY}</string>
    <key>installerSigningCertificate</key>
    <string>${KV_INSTALLER_IDENTITY}</string>
    <key>provisioningProfiles</key>
    <dict>
        <key>${BUNDLE_ID}</key>
        <string>${PROFILE_UUID}</string>
    </dict>
    <key>uploadSymbols</key>
    <false/>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_PATH" \
  -exportOptionsPlist "$EXPORT_OPTIONS"

echo "App Store arşivi hazır: $ARCHIVE_PATH"
echo "Yüklenebilir paket: $EXPORT_PATH"
