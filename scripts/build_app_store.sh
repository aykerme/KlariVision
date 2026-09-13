#!/bin/zsh
#
# Mac App Store arşivi: motoru derler, Release archive alır, motordaki her
# Mach-O'yu içten dışa imzalar, ana app'i imzalar ve App Store Connect'e
# yüklenebilir bir .pkg üretmek üzere -exportArchive çalıştırır.
#
# Gerçek imzalama kimlik ister; bu betik ortam değişkenleri eksikse
# anlaşılır bir hatayla çıkar, sahte kimlikle imzalamayı denemez.
#
# Zorunlu ortam değişkenleri:
#   KV_TEAM_ID            Apple Developer Team ID (ör. ABCDE12345)
#   KV_APP_IDENTITY       "Apple Distribution: ..." imza kimliği (app + Engine)
#   KV_INSTALLER_IDENTITY "3rd Party Mac Developer Installer: ..." kimliği
#                         (yalnız -exportArchive'ın installer paketi ürettiği
#                         akışlarda kullanılır; App Store Connect app'leri için
#                         xcodebuild -exportArchive bunu kendi profil/kimlik
#                         seçimiyle yönetir, burada yalnız doğrulanır)

set -euo pipefail

fail() {
  echo "HATA: $1" >&2
  exit 1
}

: "${KV_TEAM_ID:?KV_TEAM_ID ortam değişkeni gerekli (Apple Developer Team ID).}"
: "${KV_APP_IDENTITY:?KV_APP_IDENTITY ortam değişkeni gerekli (\"Apple Distribution: ...\" imza kimliği).}"
: "${KV_INSTALLER_IDENTITY:?KV_INSTALLER_IDENTITY ortam değişkeni gerekli (\"3rd Party Mac Developer Installer: ...\" kimliği).}"

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
ENGINE_DIST="$PROJECT_ROOT/build/KlariVisionEngineDist"
ENGINE_WORK="$PROJECT_ROOT/build/KlariVisionEngineWork"
ENGINE_SPEC="$PROJECT_ROOT/build/KlariVisionEngineSpec"
PITCH_TRACK_CLI="$PROJECT_ROOT/build/klarivision-pitch-track-cli"

rm -rf "$ARCHIVE_PATH" "$EXPORT_PATH"
rm -rf "$ENGINE_DIST" "$ENGINE_WORK" "$ENGINE_SPEC"

# --- 1. Motor: build_beta_app.sh ile aynı adımlar (C++ CLI + PyInstaller) ---

clang++ -std=c++20 -O3 -I "$PROJECT_ROOT/core/include" \
  "$PROJECT_ROOT/core/src/analysis_engine.cpp" \
  "$PROJECT_ROOT/core/src/analysis_engine_c.cpp" \
  "$PROJECT_ROOT/core/src/harmonic_arbitration.cpp" \
  "$PROJECT_ROOT/core/src/harmonic_probe.cpp" \
  "$PROJECT_ROOT/core/src/mpm.cpp" \
  "$PROJECT_ROOT/core/src/fixed_lag_tracker.cpp" \
  "$PROJECT_ROOT/core/src/swipe_prime.cpp" \
  "$PROJECT_ROOT/core/src/pyin_ladder.cpp" \
  "$PROJECT_ROOT/core/src/frame_spectrum.cpp" \
  "$PROJECT_ROOT/core/src/harmonic_evidence.cpp" \
  "$PROJECT_ROOT/core/src/unified_track_decoder.cpp" \
  "$PROJECT_ROOT/core/src/unified_pitch_session.cpp" \
  "$PROJECT_ROOT/core/tools/pitch_track_cli.cpp" \
  -framework Accelerate \
  -o "$PITCH_TRACK_CLI"

"$PROJECT_ROOT/.venv/bin/python" -m PyInstaller \
  --noconfirm \
  --clean \
  --onedir \
  --name KlariVisionEngine \
  --distpath "$ENGINE_DIST" \
  --workpath "$ENGINE_WORK" \
  --specpath "$ENGINE_SPEC" \
  --paths "$PROJECT_ROOT/src" \
  --collect-all numpy \
  --collect-all imageio_ffmpeg \
  --collect-all openpyxl \
  --exclude-module yt_dlp \
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

# --- 2. Release arşivi (Xcode'un kendi "Embed bundled analysis engine" ---
# --- betiği de motoru yeniden kurar; burada üretilen ENGINE_DIST'i        ---
# --- kullanır, gereksiz yere ikinci kez derlemez).                        ---

xcodebuild archive \
  -project "$PROJECT_FILE" \
  -scheme KlariVision \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  -derivedDataPath "$DERIVED_DATA" \
  DEVELOPMENT_TEAM="$KV_TEAM_ID" \
  CODE_SIGN_IDENTITY="$KV_APP_IDENTITY" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGNING_ALLOWED=NO

[ -d "$ARCHIVE_APP" ] || fail "Arşiv üretilemedi: $ARCHIVE_APP bulunamadı."

# --- 3. Motoru arşivdeki app'in Contents/Resources/Engine altına koy ---

ENGINE_DEST="$ARCHIVE_APP/Contents/Resources/Engine"
rm -rf "$ENGINE_DEST"
mkdir -p "$ARCHIVE_APP/Contents/Resources"
cp "$ICON_FILE" "$ARCHIVE_APP/Contents/Resources/KlariVision.icns"
ditto "$ENGINE_DIST/KlariVisionEngine" "$ENGINE_DEST"
/usr/libexec/PlistBuddy -c "Set :CFBundleIconFile KlariVision" "$ARCHIVE_APP/Contents/Info.plist"

# --- 4. Motordaki her Mach-O'yu içten dışa imzala (dylib, .so, ikililer) ---
# --- Sıralama önemli: bir ikiliye bağımlı dylib'ler ondan önce imzalanmalı, ---
# --- bu yüzden en derinden en sığa doğru gidiyoruz (find -depth).          ---

is_macho() {
  file -b "$1" 2>/dev/null | grep -q "Mach-O"
}

find "$ENGINE_DEST" -depth -type f \( -name "*.dylib" -o -name "*.so" -o -perm -u+x \) -print0 |
  while IFS= read -r -d '' candidate; do
    if is_macho "$candidate"; then
      codesign --force --options runtime --timestamp \
        --entitlements "$ENTITLEMENTS_ENGINE" \
        --sign "$KV_APP_IDENTITY" \
        "$candidate"
    fi
  done

# --- 5. Ana app'i imzala (--deep KULLANMA: her Mach-O zaten içten dışa ---
# --- ayrı ayrı imzalandı; --deep bunların üstüne yanlış/gereksiz bir    ---
# --- ikinci imza daha atardı).                                          ---

codesign --force --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS_APP" \
  --sign "$KV_APP_IDENTITY" \
  "$ARCHIVE_APP"

codesign --verify --deep --strict --verbose=2 "$ARCHIVE_APP" || fail "codesign doğrulaması başarısız."

# --- 6. ExportOptions.plist + -exportArchive (method: app-store-connect) ---

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
