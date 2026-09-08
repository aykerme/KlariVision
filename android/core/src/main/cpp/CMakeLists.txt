cmake_minimum_required(VERSION 3.24)
project(KlariVisionAndroidCore LANGUAGES CXX)

# Paylaşılan C++ çekirdeği olduğu gibi alınır. Kaynak ağacı Android'e özgü
# hiçbir şey bilmez; Accelerate bağlantısı zaten if(APPLE) ile sınırlıdır.
set(KLARIVISION_CORE_BUILD_TESTS OFF CACHE BOOL "" FORCE)
add_subdirectory(
    "${CMAKE_CURRENT_SOURCE_DIR}/../../../../../core"
    "${CMAKE_CURRENT_BINARY_DIR}/klarivision_core"
)

add_library(klarivision_jni SHARED klarivision_jni.cpp)
target_link_libraries(klarivision_jni PRIVATE klarivision_core log)
