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

rm -rf "$BETA_APP"
rm -rf "$ENGINE_DIST" "$ENGINE_WORK" "$ENGINE_SPEC"

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
  --add-data "$PROJECT_ROOT/data/reference/vamp-pyin-smoothedpitch.ttl:data/reference" \
  --add-data "$PROJECT_ROOT/tools/sonic-annotator/sonic-annotator:tools/sonic-annotator" \
  --add-binary "$HOME/Library/Audio/Plug-Ins/Vamp/pyin.dylib:Vamp" \
  --add-data "$HOME/Library/Audio/Plug-Ins/Vamp/pyin.n3:Vamp" \
  --add-data "$HOME/Library/Audio/Plug-Ins/Vamp/pyin.cat:Vamp" \
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
