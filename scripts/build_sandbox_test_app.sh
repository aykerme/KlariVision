#!/bin/zsh
# Yerel sandbox testi: Release derlemesini App Store izinleriyle (sandbox,
# mikrofon, kullanıcının seçtiği dosyalar) geçici imzayla imzalar. Apple
# Distribution sertifikası gerekmez; amaç TestFlight'tan önce sandbox
# ihlallerini bu Mac'te görmek.
#
# Kullanım:  zsh scripts/build_sandbox_test_app.sh
# Çıktı:     dist/KlariVision Sandbox Test.app
#
# Uygulama sandbox konteynerinde çalışır: veriler
# ~/Library/Containers/com.aykerme.KlariVisionNative altında tutulur ve
# korumasız sürümün ~/Library/Application Support/KlariVision kütüphanesi
# burada görünmez. İhlalleri izlemek için:
#   log stream --style compact --predicate 'sender == "Sandbox"'

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_FILE="$PROJECT_ROOT/macos/KlariVision/KlariVision.xcodeproj"
DERIVED_DATA="$PROJECT_ROOT/build/KlariVisionSandboxTestDD"
SOURCE_APP="$DERIVED_DATA/Build/Products/Release/KlariVision.app"
TEST_APP="$PROJECT_ROOT/dist/KlariVision Sandbox Test.app"
ENTITLEMENTS_APP="$PROJECT_ROOT/macos/KlariVision/KlariVision.entitlements"
ENTITLEMENTS_ENGINE="$PROJECT_ROOT/macos/KlariVision/Engine.entitlements"

# Xcode'un "Embed bundled analysis engine" adımı motoru Resources/Engine'e koyar.
xcodebuild \
  -project "$PROJECT_FILE" \
  -scheme KlariVision \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  build

[ -x "$SOURCE_APP/Contents/Resources/Engine/KlariVisionEngine" ] || {
  echo "HATA: Release derlemesinde motor yok ($SOURCE_APP/Contents/Resources/Engine)." >&2
  exit 1
}

rm -rf "$TEST_APP"
mkdir -p "$(dirname "$TEST_APP")"
ditto "$SOURCE_APP" "$TEST_APP"

# Motordaki her Mach-O, en derinden başlayarak inherit izniyle imzalanır;
# ana uygulama en son, kendi izinleriyle. Hardened runtime kapalı: geçici
# imzada takım kimliği olmadığından kütüphane doğrulaması Python
# eklentilerini reddederdi. App Store derlemesi (build_app_store.sh) açık tutar.
find "$TEST_APP/Contents/Resources/Engine" -depth -type f -print0 |
  while IFS= read -r -d '' candidate; do
    if file -b "$candidate" | grep -q "Mach-O"; then
      codesign --force --sign - --entitlements "$ENTITLEMENTS_ENGINE" "$candidate"
    fi
  done
codesign --force --sign - --entitlements "$ENTITLEMENTS_APP" "$TEST_APP"
codesign --verify --deep --strict "$TEST_APP"

echo "Hazır: $TEST_APP"
codesign -d --entitlements - --xml "$TEST_APP" 2>/dev/null | plutil -p - 2>/dev/null || true
