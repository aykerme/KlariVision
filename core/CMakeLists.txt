cmake_minimum_required(VERSION 3.24)
project(KlariVisionCore LANGUAGES CXX)

add_library(klarivision_core STATIC
    src/analysis_engine.cpp
    src/analysis_engine_c.cpp
    src/fixed_lag_tracker.cpp
    src/mpm.cpp
    src/pitch_display.cpp
    src/pitch_engine_v2.cpp
    src/pitch_engine_v2_session.cpp
    src/swipe_prime.cpp
    src/vpm_like.cpp
)
target_include_directories(klarivision_core PUBLIC include)
target_compile_features(klarivision_core PUBLIC cxx_std_20)
if(APPLE)
    find_library(ACCELERATE_FRAMEWORK Accelerate REQUIRED)
    target_link_libraries(klarivision_core PUBLIC ${ACCELERATE_FRAMEWORK})
endif()

add_executable(klarivision_vpm_like_trace tools/vpm_like_trace.cpp)
target_link_libraries(klarivision_vpm_like_trace PRIVATE klarivision_core)

add_executable(klarivision_pitch_track_cli tools/pitch_track_cli.cpp)
target_link_libraries(klarivision_pitch_track_cli PRIVATE klarivision_core)

add_executable(klarivision_pitch_engine_v2_trace tools/pitch_engine_v2_trace.cpp)
target_link_libraries(klarivision_pitch_engine_v2_trace PRIVATE klarivision_core)

option(KLARIVISION_CORE_BUILD_TESTS "Build core validation tests" ON)
if(KLARIVISION_CORE_BUILD_TESTS)
    enable_testing()
    add_executable(klarivision_core_tests tests/pitch_display_tests.cpp)
    target_link_libraries(klarivision_core_tests PRIVATE klarivision_core)
    add_test(NAME klarivision_core_tests COMMAND klarivision_core_tests)

    add_executable(klarivision_pitch_engine_v2_tests tests/pitch_engine_v2_tests.cpp)
    target_link_libraries(klarivision_pitch_engine_v2_tests PRIVATE klarivision_core)
    add_test(NAME klarivision_pitch_engine_v2_tests COMMAND klarivision_pitch_engine_v2_tests)

    add_executable(klarivision_mpm_tests tests/mpm_tests.cpp)
    target_link_libraries(klarivision_mpm_tests PRIVATE klarivision_core)
    add_test(NAME klarivision_mpm_tests COMMAND klarivision_mpm_tests)

    add_executable(klarivision_swipe_prime_tests tests/swipe_prime_tests.cpp)
    target_link_libraries(klarivision_swipe_prime_tests PRIVATE klarivision_core)
    add_test(NAME klarivision_swipe_prime_tests COMMAND klarivision_swipe_prime_tests)

    add_executable(klarivision_fixed_lag_tracker_tests tests/fixed_lag_tracker_tests.cpp)
    target_link_libraries(klarivision_fixed_lag_tracker_tests PRIVATE klarivision_core)
    add_test(NAME klarivision_fixed_lag_tracker_tests COMMAND klarivision_fixed_lag_tracker_tests)

    add_executable(klarivision_vpm_like_tests tests/vpm_like_tests.cpp)
    target_link_libraries(klarivision_vpm_like_tests PRIVATE klarivision_core)
    add_test(NAME klarivision_vpm_like_tests COMMAND klarivision_vpm_like_tests)

    add_executable(klarivision_analysis_engine_tests tests/analysis_engine_tests.cpp)
    target_link_libraries(klarivision_analysis_engine_tests PRIVATE klarivision_core)
    add_test(NAME klarivision_analysis_engine_tests COMMAND klarivision_analysis_engine_tests)

    add_executable(klarivision_analysis_engine_c_tests tests/analysis_engine_c_tests.cpp)
    target_link_libraries(klarivision_analysis_engine_c_tests PRIVATE klarivision_core)
    add_test(NAME klarivision_analysis_engine_c_tests COMMAND klarivision_analysis_engine_c_tests)
endif()
