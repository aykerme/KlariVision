#!/bin/sh
# Grafik şablonlarının iPad ve Android kopyaları birebir aynı mı?
#
# StudyViewer.html ve LiveViewer.html iki platformda ayrı dosya olarak
# duruyor ve elle senkron tutuluyor. Bu betik iki kopyayı karşılaştırır;
# fark varsa farkı basar ve sıfırdan farklı kodla çıkar. CI'da
# .github/workflows/viewer-parity.yml koşar; yerelde repo kökünden:
#   sh scripts/check_viewer_parity.sh
# Karar kaydı: docs/ANDROID_IOS_UI_PARITY_PLAN.md §1.11.

set -u

root="$(cd "$(dirname "$0")/.." && pwd)"
ipad_dir="$root/ipad/KlariVisioniPadCoreSmoke/KlariVisioniPad/Resources"
android_dir="$root/android/app/src/main/assets/viewer"

status=0
for name in StudyViewer.html LiveViewer.html; do
    ipad="$ipad_dir/$name"
    android="$android_dir/$name"
    if [ ! -f "$ipad" ] || [ ! -f "$android" ]; then
        echo "EKSİK: $name iki platformda da bulunmalı" >&2
        echo "  $ipad" >&2
        echo "  $android" >&2
        status=1
        continue
    fi
    if cmp -s "$ipad" "$android"; then
        echo "AYNI: $name"
    else
        echo "FARKLI: $name — iPad ve Android kopyaları ayrışmış" >&2
        diff -u "$ipad" "$android" >&2
        status=1
    fi
done

exit $status
