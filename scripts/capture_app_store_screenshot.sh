#!/bin/zsh
# App Store ekran görüntüsü: KlariVision'ın ön penceresini 1440×900 noktaya
# getirir ve gölgesiz yakalar. Retina ekranda 2880×1800, 1x ekranda 1440×900
# piksel çıkar; ikisi de App Store'un kabul ettiği 16:10 boyutlarıdır.
#
# Kullanım:  zsh scripts/capture_app_store_screenshot.sh <ad> [tr|en]
# Örnek:     zsh scripts/capture_app_store_screenshot.sh 01-calma-modu en
#
# Uygulamayı istenen dilde önce kendin aç:
#   open -a KlariVision --args -AppleLanguages "(en)"
#
# İlk çalıştırmada macOS, Terminal için "Ekran Kaydı" ve "Erişilebilirlik"
# izni ister (Sistem Ayarları → Gizlilik ve Güvenlik). İzin verip betiği
# yeniden çalıştır.

set -euo pipefail

NAME="${1:?Görüntü adı gerekli (ör. 01-calma-modu)}"
LANG_CODE="${2:-tr}"
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$PROJECT_ROOT/dist/app-store-screenshots/$LANG_CODE"
OUT="$OUT_DIR/$NAME.png"
WIDTH=1440
HEIGHT=900
HELPER="${TMPDIR:-/tmp}/klarivision-window-id"

mkdir -p "$OUT_DIR"

if [[ ! -x "$HELPER" ]]; then
  cat > "$HELPER.swift" <<'SWIFT'
import CoreGraphics
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
if let window = windows.first(where: {
    ($0[kCGWindowOwnerName as String] as? String) == "KlariVision" && ($0[kCGWindowLayer as String] as? Int) == 0
}), let number = window[kCGWindowNumber as String] {
    print(number)
}
SWIFT
  swiftc -O "$HELPER.swift" -o "$HELPER"
fi

osascript <<APPLESCRIPT
tell application "KlariVision" to activate
tell application "System Events" to tell process "KlariVision"
  set position of front window to {40, 60}
  set size of front window to {$WIDTH, $HEIGHT}
end tell
APPLESCRIPT
sleep 1

WINDOW_ID="$("$HELPER")"
if [[ -z "$WINDOW_ID" ]]; then
  echo "KlariVision penceresi bulunamadı. Uygulama açık ve ekranda mı?" >&2
  exit 1
fi

screencapture -o -x -l "$WINDOW_ID" "$OUT"

PIXEL_WIDTH="$(sips -g pixelWidth "$OUT" | awk '/pixelWidth/ {print $2}')"
PIXEL_HEIGHT="$(sips -g pixelHeight "$OUT" | awk '/pixelHeight/ {print $2}')"
case "${PIXEL_WIDTH}x${PIXEL_HEIGHT}" in
  2880x1800|1440x900)
    echo "Kaydedildi: $OUT (${PIXEL_WIDTH}×${PIXEL_HEIGHT})"
    ;;
  *)
    echo "UYARI: $OUT ${PIXEL_WIDTH}×${PIXEL_HEIGHT} çıktı; App Store 2880×1800 veya 1440×900 ister." >&2
    echo "Pencere ekrana sığmıyor olabilir; daha büyük bir ekranda yeniden dene." >&2
    exit 2
    ;;
esac
