#!/usr/bin/env zsh
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
test_binary="${TMPDIR:-/tmp}/klarivision-core-tests"
v2_test_binary="${TMPDIR:-/tmp}/klarivision-pitch-engine-v2-tests"
mpm_test_binary="${TMPDIR:-/tmp}/klarivision-mpm-tests"
swipe_prime_test_binary="${TMPDIR:-/tmp}/klarivision-swipe-prime-tests"
vpm_like_test_binary="${TMPDIR:-/tmp}/klarivision-vpm-like-tests"
analysis_engine_test_binary="${TMPDIR:-/tmp}/klarivision-analysis-engine-tests"
v2_session_test_binary="${TMPDIR:-/tmp}/klarivision-pitch-engine-v2-session-tests"
c_api_test_binary="${TMPDIR:-/tmp}/klarivision-analysis-engine-c-tests"
harmonic_arbitration_test_binary="${TMPDIR:-/tmp}/klarivision-harmonic-arbitration-tests"
hapt_test_binary="${TMPDIR:-/tmp}/klarivision-hapt-tests"

clang++ -std=c++20 -Wall -Wextra -Werror \
  -I "$project_root/core/include" \
  "$project_root/core/src/pitch_display.cpp" \
  "$project_root/core/tests/pitch_display_tests.cpp" \
  -o "$test_binary"

"$test_binary"

clang++ -std=c++20 -Wall -Wextra -Werror \
  -I "$project_root/core/include" \
  "$project_root/core/src/pitch_engine_v2.cpp" \
  "$project_root/core/tests/pitch_engine_v2_tests.cpp" \
  -o "$v2_test_binary"

"$v2_test_binary"

clang++ -std=c++20 -Wall -Wextra -Werror \
  -I "$project_root/core/include" \
  "$project_root/core/src/pitch_engine_v2.cpp" \
  "$project_root/core/src/fixed_lag_tracker.cpp" \
  "$project_root/core/src/swipe_prime.cpp" \
  "$project_root/core/src/pitch_engine_v2_session.cpp" \
  "$project_root/core/tests/pitch_engine_v2_session_tests.cpp" \
  -framework Accelerate \
  -o "$v2_session_test_binary"

"$v2_session_test_binary"

clang++ -std=c++20 -Wall -Wextra -Werror \
  -I "$project_root/core/include" \
  "$project_root/core/src/mpm.cpp" \
  "$project_root/core/tests/mpm_tests.cpp" \
  -o "$mpm_test_binary"

"$mpm_test_binary"

clang++ -std=c++20 -Wall -Wextra -Werror \
  -I "$project_root/core/include" \
  "$project_root/core/src/pitch_engine_v2.cpp" \
  "$project_root/core/src/swipe_prime.cpp" \
  "$project_root/core/tests/swipe_prime_tests.cpp" \
  -o "$swipe_prime_test_binary"

"$swipe_prime_test_binary"

clang++ -std=c++20 -Wall -Wextra -Werror \
  -I "$project_root/core/include" \
  "$project_root/core/src/vpm_like.cpp" \
  "$project_root/core/tests/vpm_like_tests.cpp" \
  -o "$vpm_like_test_binary"

"$vpm_like_test_binary"

# analysis_engine.cpp / analysis_engine_c.cpp now dispatch to unified_v1
# unconditionally (PitchEngineId::unified_v1), so every binary that links
# either of them needs the full unified engine source set below or the link
# step fails with undefined UnifiedPitchSession/collect_unified_evidence/etc
# symbols -- this is not optional the way the new *_tests blocks below are.
clang++ -std=c++20 -Wall -Wextra -Werror \
  -I "$project_root/core/include" \
  "$project_root/core/src/analysis_engine.cpp" \
  "$project_root/core/src/harmonic_arbitration.cpp" \
  "$project_root/core/src/hapt.cpp" \
  "$project_root/core/src/harmonic_probe.cpp" \
  "$project_root/core/src/mpm.cpp" \
  "$project_root/core/src/pitch_engine_v2.cpp" \
  "$project_root/core/src/fixed_lag_tracker.cpp" \
  "$project_root/core/src/pitch_engine_v2_session.cpp" \
  "$project_root/core/src/swipe_prime.cpp" \
  "$project_root/core/src/vpm_like.cpp" \
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
  "$project_root/core/src/hapt.cpp" \
  "$project_root/core/src/harmonic_probe.cpp" \
  "$project_root/core/src/mpm.cpp" \
  "$project_root/core/src/pitch_engine_v2.cpp" \
  "$project_root/core/src/fixed_lag_tracker.cpp" \
  "$project_root/core/src/pitch_engine_v2_session.cpp" \
  "$project_root/core/src/swipe_prime.cpp" \
  "$project_root/core/src/vpm_like.cpp" \
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
  "$project_root/core/src/hapt.cpp" \
  "$project_root/core/src/harmonic_probe.cpp" \
  "$project_root/core/src/mpm.cpp" \
  "$project_root/core/src/pitch_engine_v2.cpp" \
  "$project_root/core/src/fixed_lag_tracker.cpp" \
  "$project_root/core/src/pitch_engine_v2_session.cpp" \
  "$project_root/core/src/swipe_prime.cpp" \
  "$project_root/core/src/vpm_like.cpp" \
  "$project_root/core/src/unified_pitch_session.cpp" \
  "$project_root/core/src/unified_track_decoder.cpp" \
  "$project_root/core/src/pyin_ladder.cpp" \
  "$project_root/core/src/frame_spectrum.cpp" \
  "$project_root/core/src/harmonic_evidence.cpp" \
  "$project_root/core/tests/harmonic_arbitration_tests.cpp" \
  -framework Accelerate \
  -o "$harmonic_arbitration_test_binary"

"$harmonic_arbitration_test_binary"

clang++ -std=c++20 -Wall -Wextra -Werror \
  -I "$project_root/core/include" \
  "$project_root/core/src/hapt.cpp" \
  "$project_root/core/src/harmonic_probe.cpp" \
  "$project_root/core/tests/hapt_tests.cpp" \
  -o "$hapt_test_binary"

"$hapt_test_binary"

# --- unified_v1 engine pieces: other agents are landing these concurrently,
# so a missing source file is a clear skip, not a hard failure. ---

pyin_ladder_test_binary="${TMPDIR:-/tmp}/klarivision-pyin-ladder-tests"
if [ -f "$project_root/core/src/pyin_ladder.cpp" ]; then
  clang++ -std=c++20 -Wall -Wextra -Werror \
    -I "$project_root/core/include" \
    "$project_root/core/src/pyin_ladder.cpp" \
    "$project_root/core/tests/pyin_ladder_tests.cpp" \
    -framework Accelerate \
    -o "$pyin_ladder_test_binary"

  "$pyin_ladder_test_binary"
else
  echo "SKIP pyin_ladder_tests (core/src/pyin_ladder.cpp not present yet)"
fi

frame_spectrum_test_binary="${TMPDIR:-/tmp}/klarivision-frame-spectrum-tests"
if [ -f "$project_root/core/src/frame_spectrum.cpp" ] && [ -f "$project_root/core/src/harmonic_probe.cpp" ]; then
  # frame_spectrum.cpp calls hann_main_lobe_half_width_hz(), which lives in
  # harmonic_probe.cpp -- both are required to link, not just the former.
  clang++ -std=c++20 -Wall -Wextra -Werror \
    -I "$project_root/core/include" \
    "$project_root/core/src/frame_spectrum.cpp" \
    "$project_root/core/src/harmonic_probe.cpp" \
    "$project_root/core/tests/frame_spectrum_tests.cpp" \
    -framework Accelerate \
    -o "$frame_spectrum_test_binary"

  "$frame_spectrum_test_binary"
else
  echo "SKIP frame_spectrum_tests (core/src/frame_spectrum.cpp or harmonic_probe.cpp not present yet)"
fi

harmonic_evidence_test_binary="${TMPDIR:-/tmp}/klarivision-harmonic-evidence-tests"
if [ -f "$project_root/core/src/frame_spectrum.cpp" ] && [ -f "$project_root/core/src/harmonic_evidence.cpp" ] \
  && [ -f "$project_root/core/src/swipe_prime.cpp" ] && [ -f "$project_root/core/src/harmonic_arbitration.cpp" ] \
  && [ -f "$project_root/core/src/harmonic_probe.cpp" ]; then
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
else
  echo "SKIP harmonic_evidence_tests (core/src/frame_spectrum.cpp, harmonic_evidence.cpp, swipe_prime.cpp, harmonic_arbitration.cpp or harmonic_probe.cpp not present yet)"
fi

unified_track_decoder_test_binary="${TMPDIR:-/tmp}/klarivision-unified-track-decoder-tests"
if [ -f "$project_root/core/src/unified_track_decoder.cpp" ] && [ -f "$project_root/core/src/harmonic_evidence.cpp" ] \
  && [ -f "$project_root/core/src/frame_spectrum.cpp" ] && [ -f "$project_root/core/src/swipe_prime.cpp" ] \
  && [ -f "$project_root/core/src/harmonic_arbitration.cpp" ] && [ -f "$project_root/core/src/harmonic_probe.cpp" ]; then
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
else
  echo "SKIP unified_track_decoder_tests (core/src/unified_track_decoder.cpp, harmonic_evidence.cpp, frame_spectrum.cpp, swipe_prime.cpp, harmonic_arbitration.cpp or harmonic_probe.cpp not present yet)"
fi

unified_pitch_session_test_binary="${TMPDIR:-/tmp}/klarivision-unified-pitch-session-tests"
if [ -f "$project_root/core/src/unified_pitch_session.cpp" ] && \
   [ -f "$project_root/core/src/pyin_ladder.cpp" ] && \
   [ -f "$project_root/core/src/harmonic_evidence.cpp" ]; then
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
else
  echo "SKIP unified_pitch_session_tests (unified engine sources not present yet)"
fi
