#!/bin/zsh

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_FILE="$PROJECT_ROOT/macos/KlariVision/KlariVision.xcodeproj"
DERIVED_DATA="$PROJECT_ROOT/build/KlariVisionBeta"
SOURCE_APP="$DERIVED_DATA/Build/Products/Release/KlariVision.app"
BETA_APP="$PROJECT_ROOT/dist/KlariVision Beta.app"
ICON_FILE="$PROJECT_ROOT/macos/KlariVision/Resources/KlariVision.icns"
ENGINE_DIST="$PROJECT_ROOT/build/KlariVisionEngineDist"
ENGINE_WORK="$PROJECT_ROOT/build/KlariVisionEngineWork"
ENGINE_SPEC="$PROJECT_ROOT/build/KlariVisionEngineSpec"
PITCH_TRACK_CLI="$PROJECT_ROOT/build/klarivision-pitch-track-cli"

rm -rf "$BETA_APP"
rm -rf "$ENGINE_DIST" "$ENGINE_WORK" "$ENGINE_SPEC"

clang++ -std=c++20 -O3 -I "$PROJECT_ROOT/core/include" \
  "$PROJECT_ROOT/core/src/analysis_engine.cpp" \
  "$PROJECT_ROOT/core/src/analysis_engine_c.cpp" \
  "$PROJECT_ROOT/core/src/harmonic_arbitration.cpp" \
  "$PROJECT_ROOT/core/src/hapt.cpp" \
  "$PROJECT_ROOT/core/src/harmonic_probe.cpp" \
  "$PROJECT_ROOT/core/src/mpm.cpp" \
  "$PROJECT_ROOT/core/src/pitch_engine_v2.cpp" \
  "$PROJECT_ROOT/core/src/fixed_lag_tracker.cpp" \
  "$PROJECT_ROOT/core/src/pitch_engine_v2_session.cpp" \
  "$PROJECT_ROOT/core/src/swipe_prime.cpp" \
  "$PROJECT_ROOT/core/src/vpm_like.cpp" \
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

xcodebuild \
  -project "$PROJECT_FILE" \
  -scheme KlariVision \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  build

ditto "$SOURCE_APP" "$BETA_APP"
mkdir -p "$BETA_APP/Contents/Resources"
cp "$ICON_FILE" "$BETA_APP/Contents/Resources/KlariVision.icns"
ditto "$ENGINE_DIST/KlariVisionEngine" "$BETA_APP/Contents/Resources/Engine"
/usr/libexec/PlistBuddy -c "Set :CFBundleIconFile KlariVision" "$BETA_APP/Contents/Info.plist"
codesign --force --deep --sign - "$BETA_APP"

echo "Beta uygulaması hazır: $BETA_APP"
