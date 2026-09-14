#!/bin/zsh
#
# GitHub Releases için universal (Apple Silicon + Intel) KlariVision DMG'si.
# Apple Developer Program üyeliği gerekmez: uygulama geçici imzalıdır ve
# notarize edilmez. Kullanıcı ilk açılışta Sistem Ayarları → Gizlilik ve
# Güvenlik → "Yine de Aç" demelidir (docs/install-macos.md).
#
# Sandbox KAPALI, bilerek: geçici imza her derlemede değişir. Sandbox'lı bir
# uygulamada konteynerin sahibi imzaya bağlı olduğundan güncellemeden sonra
# macOS kütüphaneye erişimi engelleyebilir. Veriler
# ~/Library/Application Support/KlariVision altındadır; ileride App Store
# sürümü bu klasörü konteynerine taşıyabilir.
#
# Kullanım:  zsh scripts/build_github_dmg.sh
# Çıktı:     dist/KlariVision-<sürüm>-macos-universal.dmg (+ .sha256)
#
# Ön koşullar: .venv (arm64) ve .venv-x86_64 (bkz. scripts/lib/klarivision_engine.sh).

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$PROJECT_ROOT/scripts/lib/klarivision_engine.sh"

PROJECT_FILE="$PROJECT_ROOT/macos/KlariVision/KlariVision.xcodeproj"
DERIVED_DATA="$PROJECT_ROOT/build/KlariVisionGitHubDD"
BUILT_APP="$DERIVED_DATA/Build/Products/Release/KlariVision.app"
# Dosya adı motorun aradığı adla aynı olmalı (pitch/cpp_engine.py: tools/klarivision-pitch-track-cli).
PITCH_TRACK_CLI="$PROJECT_ROOT/build/universal/klarivision-pitch-track-cli"
STAGING="$PROJECT_ROOT/build/KlariVisionDMGStaging"
ICON_FILE="$PROJECT_ROOT/macos/KlariVision/Resources/KlariVision.icns"
ARM64_PYTHON="$PROJECT_ROOT/.venv/bin/python"

kv_require_python "$ARM64_PYTHON" arm64
kv_require_python "$KV_X86_PYTHON" x86_64

# --- 1. Motorlar ---
echo "KlariVision: C++ CLI (universal)…"
kv_build_pitch_track_cli "$PITCH_TRACK_CLI"
echo "KlariVision: arm64 motoru…"
ENGINE_ARM64="$(kv_build_engine arm64 "$ARM64_PYTHON" "$PITCH_TRACK_CLI")"
echo "KlariVision: x86_64 motoru…"
ENGINE_X86_64="$(kv_build_engine x86_64 "$KV_X86_PYTHON" "$PITCH_TRACK_CLI")"

# --- 2. Universal Release derlemesi (imzasız; imza aşağıda) ---
echo "KlariVision: Release derlemesi…"
xcodebuild \
  -project "$PROJECT_FILE" \
  -scheme KlariVision \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  -destination "generic/platform=macOS" \
  ARCHS="arm64 x86_64" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  build >&2
[ -d "$BUILT_APP" ] || kv_fail "Release derlemesi bulunamadı: $BUILT_APP"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$BUILT_APP/Contents/Info.plist")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$BUILT_APP/Contents/Info.plist")"
DMG="$PROJECT_ROOT/dist/KlariVision-${VERSION}-macos-universal.dmg"

rm -rf "$STAGING"
mkdir -p "$STAGING"
APP="$STAGING/KlariVision.app"
ditto "$BUILT_APP" "$APP"

# --- 3. Motorlar, simge ---
kv_install_engines "$APP" "$ENGINE_ARM64" "$ENGINE_X86_64"
cp "$ICON_FILE" "$APP/Contents/Resources/KlariVision.icns"
/usr/libexec/PlistBuddy -c "Set :CFBundleIconFile KlariVision" "$APP/Contents/Info.plist"

# --- 4. Açık kaynak lisans bildirimleri (BSD/MIT/PSF bildirim şartı) ---
NOTICES="$APP/Contents/Resources/ThirdPartyNotices.txt"
SITE_PACKAGES="$("$ARM64_PYTHON" -c 'import site; print(site.getsitepackages()[0])')"
PYTHON_LICENSE="$("$ARM64_PYTHON" -c 'import sys, pathlib; print(pathlib.Path(sys.base_prefix) / "lib" / f"python{sys.version_info.major}.{sys.version_info.minor}" / "LICENSE.txt")')"
{
  echo "KlariVision ${VERSION} (${BUILD_NUMBER}) — third-party software notices"
  echo "KlariVision itself is licensed under the GNU AGPL-3.0-or-later (see LICENSE)."
  echo
  echo "===== CPython $("$ARM64_PYTHON" -c 'import platform; print(platform.python_version())') ====="
  cat "$PYTHON_LICENSE"
  for dist in numpy openpyxl et_xmlfile setuptools pyinstaller; do
    for info in "$SITE_PACKAGES"/${dist}-*.dist-info(N); do
      echo
      echo "===== ${info:t:r} ====="
      find "$info" -type f \( -iname 'LICEN*' -o -iname 'COPYING*' \) | sort | while read -r license_file; do
        echo "--- ${license_file#$info/} ---"
        cat "$license_file"
      done
    done
  done
} > "$NOTICES"
cp "$PROJECT_ROOT/LICENSE" "$APP/Contents/Resources/LICENSE.txt"

# --- 5. Geçici imza: içten dışa, sandbox izni yok ---
# Apple Silicon imzasız arm64 kodu çalıştırmaz; geçici imza zorunlu. Hardened
# runtime kapalı: takım kimliği olmadan kütüphane doğrulaması Python
# eklentilerini reddeder.
for engine_dir in "$APP/Contents/Resources/Engine-arm64" "$APP/Contents/Resources/Engine-x86_64"; do
  find "$engine_dir" -depth -type f -print0 |
    while IFS= read -r -d '' candidate; do
      if kv_is_macho "$candidate"; then
        codesign --force --sign - "$candidate"
      fi
    done
done
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP" || kv_fail "codesign doğrulaması başarısız."

for binary in "$APP/Contents/MacOS/KlariVision" "$PITCH_TRACK_CLI"; do
  [ "$(lipo -archs "$binary")" = "x86_64 arm64" ] || kv_fail "$binary universal değil: $(lipo -archs "$binary")"
done

# --- 6. DMG: uygulama + Applications kısayolu + kurulum notu ---
ln -s /Applications "$STAGING/Applications"
cp "$PROJECT_ROOT/docs/install-macos.md" "$STAGING/Kurulum - Install.md"
mkdir -p "$(dirname "$DMG")"
rm -f "$DMG" "$DMG.sha256"
hdiutil create \
  -volname "KlariVision ${VERSION}" \
  -srcfolder "$STAGING" \
  -fs HFS+ \
  -format UDZO \
  -imagekey zlib-level=9 \
  -ov \
  "$DMG" >&2

(cd "$(dirname "$DMG")" && shasum -a 256 "${DMG:t}" > "${DMG:t}.sha256")
echo "Hazır: $DMG ($(du -h "$DMG" | cut -f1))"
cat "$DMG.sha256"
