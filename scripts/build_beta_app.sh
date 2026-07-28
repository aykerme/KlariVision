#!/bin/zsh

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_FILE="$PROJECT_ROOT/macos/KlariVision/KlariVision.xcodeproj"
DERIVED_DATA="$PROJECT_ROOT/build/KlariVisionBeta"
SOURCE_APP="$DERIVED_DATA/Build/Products/Release/KlariVision.app"
BETA_APP="$PROJECT_ROOT/dist/KlariVision Beta.app"
ICON_FILE="$PROJECT_ROOT/macos/KlariVision/Resources/KlariVision.icns"

rm -rf "$BETA_APP"

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
/usr/libexec/PlistBuddy -c "Set :CFBundleIconFile KlariVision" "$BETA_APP/Contents/Info.plist"
codesign --force --deep --sign - "$BETA_APP"

echo "Beta uygulaması hazır: $BETA_APP"
