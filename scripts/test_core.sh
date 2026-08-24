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
