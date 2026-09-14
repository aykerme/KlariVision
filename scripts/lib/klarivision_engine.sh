# KlariVision dağıtım betiklerinin ortak motor derlemesi. `source` ile yüklenir;
# PROJECT_ROOT tanımlı olmalı. App Store (build_app_store.sh) ve GitHub DMG
# (build_github_dmg.sh) aynı motoru buradan üretir.
#
# Motor iki mimari için ayrı PyInstaller paketidir: universal2 PyInstaller numpy
# gibi derlenmiş bağımlılıklarla güvenilir değil. Uygulama çalışma zamanında
# `Contents/Resources/Engine-arm64` ya da `Engine-x86_64`'ü seçer
# (MediaToWAVConverter.swift → BundledEngine). Doğrulama (2026-09-13): iki
# mimarinin motoru aynı kayıt için bayt bayt aynı perde JSON'u üretti.
#
# Paketten dışlananlar: imageio_ffmpeg (ses/video çözme AVFoundation'da),
# yt_dlp (linkten açma dağıtımda yok), charset_normalizer/_cffi_backend
# (geliştirme ortamından sızıyor, motor kullanmıyor) ve yalnız
# geliştirme karşılaştırmalarında kullanılan bilimsel paketler.

KV_CORE_SOURCES=(
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

# x86_64 motoru için Python ortamı. Kurulum (sürümler .venv ile aynı):
#   uv python install cpython-3.12.13-macos-x86_64-none --install-dir .python
#   uv venv --python .python/cpython-3.12.13-macos-x86_64-none/bin/python3.12 .venv-x86_64
#   uv pip install --python .venv-x86_64/bin/python \
#     numpy==2.4.6 openpyxl==3.1.5 pyinstaller==6.21.0 pyinstaller-hooks-contrib==2026.6 setuptools==83.0.0
: "${KV_X86_PYTHON:=$PROJECT_ROOT/.venv-x86_64/bin/python}"

kv_fail() {
  echo "HATA: $1" >&2
  exit 1
}

kv_require_python() {
  local python_bin="$1" arch_name="$2"
  [ -x "$python_bin" ] || kv_fail "$arch_name Python ortamı yok: $python_bin (kurulum için scripts/lib/klarivision_engine.sh başına bak)."
  "$python_bin" -c "import platform, sys; sys.exit(0 if platform.machine() == '$arch_name' else 1)" ||
    kv_fail "$python_bin $arch_name mimarisinde çalışmıyor."
  "$python_bin" -c "import numpy, openpyxl, PyInstaller" ||
    kv_fail "$python_bin ortamında numpy/openpyxl/PyInstaller eksik."
}

# Tek universal C++ CLI; iki motor klasörüne de aynı dosya girer.
kv_build_pitch_track_cli() {
  local output="$1"
  [ "${output:t}" = "klarivision-pitch-track-cli" ] || kv_fail "C++ CLI dosya adı klarivision-pitch-track-cli olmalı: $output"
  mkdir -p "$(dirname "$output")"
  clang++ -std=c++20 -O3 -arch arm64 -arch x86_64 -I "$PROJECT_ROOT/core/include" \
    "${KV_CORE_SOURCES[@]}" \
    -framework Accelerate \
    -o "$output"
}

# kv_build_engine <arm64|x86_64> <python> <pitch-track-cli> → motor klasörünün yolunu yazar.
kv_build_engine() {
  local arch_name="$1" python_bin="$2" pitch_track_cli="$3"
  local dist_dir="$PROJECT_ROOT/build/KlariVisionEngineDist-${arch_name}"
  local work_dir="$PROJECT_ROOT/build/KlariVisionEngineWork-${arch_name}"
  local spec_dir="$PROJECT_ROOT/build/KlariVisionEngineSpec-${arch_name}"

  rm -rf "$dist_dir" "$work_dir" "$spec_dir"
  "$python_bin" -m PyInstaller \
    --noconfirm \
    --clean \
    --onedir \
    --log-level WARN \
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
    --exclude-module charset_normalizer \
    --exclude-module _cffi_backend \
    --add-data "$PROJECT_ROOT/data/reference/perde-esleme.xlsx:data/reference" \
    --add-data "$PROJECT_ROOT/data/reference/Turk_Muzigi_Perdeleri_ve_Mikrotonal_Notasyon.xlsx:data/reference" \
    --add-binary="${pitch_track_cli}:tools" \
    "$PROJECT_ROOT/src/klarivision/engine_cli.py" >&2

  local engine="$dist_dir/KlariVisionEngine"
  [ -x "$engine/KlariVisionEngine" ] || kv_fail "$arch_name motoru üretilemedi."
  # pitch/cpp_engine.py aracı bu adla arar; farklı adla eklenirse analiz çalışma anında düşer.
  [ -x "$engine/_internal/tools/klarivision-pitch-track-cli" ] ||
    kv_fail "$arch_name motorunda tools/klarivision-pitch-track-cli yok (eklenen: $(ls "$engine/_internal/tools" 2>/dev/null | tr '\n' ' '))."
  if [ -d "$engine/_internal/imageio_ffmpeg" ]; then
    kv_fail "$arch_name motorunda imageio_ffmpeg var; dışlama çalışmadı."
  fi
  echo "$engine"
}

# Xcode'un "Embed bundled analysis engine" adımının bıraktığı tek mimarili
# (ve ffmpeg taşıyan) Engine klasörünü kaldırıp mimariye özel motorları koyar.
kv_install_engines() {
  local app="$1" engine_arm64="$2" engine_x86_64="$3"
  rm -rf "$app/Contents/Resources/Engine" "$app/Contents/Resources/Engine-arm64" "$app/Contents/Resources/Engine-x86_64"
  ditto "$engine_arm64" "$app/Contents/Resources/Engine-arm64"
  ditto "$engine_x86_64" "$app/Contents/Resources/Engine-x86_64"
}

kv_is_macho() {
  file -b "$1" 2>/dev/null | grep -q "Mach-O"
}
