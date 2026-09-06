#!/usr/bin/env zsh
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
test_binary="${TMPDIR:-/tmp}/klarivision-core-tests"
mpm_test_binary="${TMPDIR:-/tmp}/klarivision-mpm-tests"
swipe_prime_test_binary="${TMPDIR:-/tmp}/klarivision-swipe-prime-tests"
analysis_engine_test_binary="${TMPDIR:-/tmp}/klarivision-analysis-engine-tests"
c_api_test_binary="${TMPDIR:-/tmp}/klarivision-analysis-engine-c-tests"
harmonic_arbitration_test_binary="${TMPDIR:-/tmp}/klarivision-harmonic-arbitration-tests"

clang++ -std=c++20 -Wall -Wextra -Werror \
  -I "$project_root/core/include" \
  "$project_root/core/src/pitch_display.cpp" \
  "$project_root/core/tests/pitch_display_tests.cpp" \
  -o "$test_binary"

"$test_binary"

clang++ -std=c++20 -Wall -Wextra -Werror \
  -I "$project_root/core/include" \
  "$project_root/core/src/mpm.cpp" \
  "$project_root/core/tests/mpm_tests.cpp" \
  -o "$mpm_test_binary"

"$mpm_test_binary"

clang++ -std=c++20 -Wall -Wextra -Werror \
  -I "$project_root/core/include" \
  "$project_root/core/src/swipe_prime.cpp" \
  "$project_root/core/tests/swipe_prime_tests.cpp" \
  -o "$swipe_prime_test_binary"

"$swipe_prime_test_binary"

# analysis_engine.cpp / analysis_engine_c.cpp dispatch to unified_v1 and
# nothing else (D-039 removed the other four engines), so every binary that
# links either of them needs the full unified engine source set below or the
# link step fails with undefined UnifiedPitchSession/collect_unified_evidence/
# etc symbols -- this is not optional the way the *_tests blocks below are.
clang++ -std=c++20 -Wall -Wextra -Werror \
  -I "$project_root/core/include" \
  "$project_root/core/src/analysis_engine.cpp" \
  "$project_root/core/src/harmonic_arbitration.cpp" \
  "$project_root/core/src/harmonic_probe.cpp" \
  "$project_root/core/src/mpm.cpp" \
  "$project_root/core/src/fixed_lag_tracker.cpp" \
  "$project_root/core/src/swipe_prime.cpp" \
  "$project_root/core/src/unified_pitch_session.cpp" \
  "$project_root/core/src/unified_track_decoder.cpp" \
  "$project_root/core/src/pyin_ladder.cpp" \
  "$project_root/core/src/frame_spectrum.cpp" \
  "$project_root/core/src/harmonic_evidence.cpp" \
  "$project_root/core/tests/analysis_engine_tests.cpp" \
  -framework Accelerate \
  -o "$analysis_engine_test_binary"

"$analysis_engine_test_binary"

clang++ -std=c++20 -Wall -Wextra -Werror \
  -I "$project_root/core/include" \
  "$project_root/core/src/analysis_engine.cpp" \
  "$project_root/core/src/analysis_engine_c.cpp" \
  "$project_root/core/src/harmonic_arbitration.cpp" \
  "$project_root/core/src/harmonic_probe.cpp" \
  "$project_root/core/src/mpm.cpp" \
  "$project_root/core/src/fixed_lag_tracker.cpp" \
  "$project_root/core/src/swipe_prime.cpp" \
  "$project_root/core/src/unified_pitch_session.cpp" \
  "$project_root/core/src/unified_track_decoder.cpp" \
  "$project_root/core/src/pyin_ladder.cpp" \
  "$project_root/core/src/frame_spectrum.cpp" \
  "$project_root/core/src/harmonic_evidence.cpp" \
  "$project_root/core/tests/analysis_engine_c_tests.cpp" \
  -framework Accelerate \
  -o "$c_api_test_binary"

"$c_api_test_binary"

clang++ -std=c++20 -Wall -Wextra -Werror \
  -I "$project_root/core/include" \
  "$project_root/core/src/harmonic_arbitration.cpp" \
  "$project_root/core/src/analysis_engine.cpp" \
  "$project_root/core/src/harmonic_probe.cpp" \
  "$project_root/core/src/mpm.cpp" \
  "$project_root/core/src/fixed_lag_tracker.cpp" \
  "$project_root/core/src/swipe_prime.cpp" \
  "$project_root/core/src/unified_pitch_session.cpp" \
  "$project_root/core/src/unified_track_decoder.cpp" \
  "$project_root/core/src/pyin_ladder.cpp" \
  "$project_root/core/src/frame_spectrum.cpp" \
  "$project_root/core/src/harmonic_evidence.cpp" \
  "$project_root/core/tests/harmonic_arbitration_tests.cpp" \
  -framework Accelerate \
  -o "$harmonic_arbitration_test_binary"

"$harmonic_arbitration_test_binary"

# --- unified_v1 engine pieces ---
#
# These were guarded by "skip if the source is missing" while the unified
# engine was being landed piecemeal. It is now the only engine (D-039), so a
# missing source is a broken build, not a skip.

pyin_ladder_test_binary="${TMPDIR:-/tmp}/klarivision-pyin-ladder-tests"
clang++ -std=c++20 -Wall -Wextra -Werror \
  -I "$project_root/core/include" \
  "$project_root/core/src/pyin_ladder.cpp" \
  "$project_root/core/tests/pyin_ladder_tests.cpp" \
  -framework Accelerate \
  -o "$pyin_ladder_test_binary"

"$pyin_ladder_test_binary"

# frame_spectrum.cpp calls hann_main_lobe_half_width_hz(), which lives in
# harmonic_probe.cpp -- both are required to link, not just the former.
frame_spectrum_test_binary="${TMPDIR:-/tmp}/klarivision-frame-spectrum-tests"
clang++ -std=c++20 -Wall -Wextra -Werror \
  -I "$project_root/core/include" \
  "$project_root/core/src/frame_spectrum.cpp" \
  "$project_root/core/src/harmonic_probe.cpp" \
  "$project_root/core/tests/frame_spectrum_tests.cpp" \
  -framework Accelerate \
  -o "$frame_spectrum_test_binary"

"$frame_spectrum_test_binary"

harmonic_evidence_test_binary="${TMPDIR:-/tmp}/klarivision-harmonic-evidence-tests"
clang++ -std=c++20 -Wall -Wextra -Werror \
  -I "$project_root/core/include" \
  "$project_root/core/src/frame_spectrum.cpp" \
  "$project_root/core/src/harmonic_evidence.cpp" \
  "$project_root/core/src/swipe_prime.cpp" \
  "$project_root/core/src/harmonic_arbitration.cpp" \
  "$project_root/core/src/harmonic_probe.cpp" \
  "$project_root/core/tests/harmonic_evidence_tests.cpp" \
  -framework Accelerate \
  -o "$harmonic_evidence_test_binary"

"$harmonic_evidence_test_binary"

unified_track_decoder_test_binary="${TMPDIR:-/tmp}/klarivision-unified-track-decoder-tests"
clang++ -std=c++20 -Wall -Wextra -Werror \
  -I "$project_root/core/include" \
  "$project_root/core/src/unified_track_decoder.cpp" \
  "$project_root/core/src/harmonic_evidence.cpp" \
  "$project_root/core/src/frame_spectrum.cpp" \
  "$project_root/core/src/swipe_prime.cpp" \
  "$project_root/core/src/harmonic_arbitration.cpp" \
  "$project_root/core/src/harmonic_probe.cpp" \
  "$project_root/core/tests/unified_track_decoder_tests.cpp" \
  -framework Accelerate \
  -o "$unified_track_decoder_test_binary"

"$unified_track_decoder_test_binary"

unified_pitch_session_test_binary="${TMPDIR:-/tmp}/klarivision-unified-pitch-session-tests"
clang++ -std=c++20 -Wall -Wextra -Werror \
  -I "$project_root/core/include" \
  "$project_root/core/src/unified_pitch_session.cpp" \
  "$project_root/core/src/unified_track_decoder.cpp" \
  "$project_root/core/src/pyin_ladder.cpp" \
  "$project_root/core/src/frame_spectrum.cpp" \
  "$project_root/core/src/harmonic_evidence.cpp" \
  "$project_root/core/src/swipe_prime.cpp" \
  "$project_root/core/src/harmonic_arbitration.cpp" \
  "$project_root/core/src/harmonic_probe.cpp" \
  "$project_root/core/src/mpm.cpp" \
  "$project_root/core/tests/unified_pitch_session_tests.cpp" \
  -framework Accelerate \
  -o "$unified_pitch_session_test_binary"

"$unified_pitch_session_test_binary"
