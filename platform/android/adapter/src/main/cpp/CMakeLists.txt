cmake_minimum_required(VERSION 3.22)
project(dansheng_android LANGUAGES C)
if(NOT DANSHENG_RUST_JNI_DIR)
  message(FATAL_ERROR "Pass -PrustJniDir=<absolute ABI directory containing libdansheng_ffi.so>")
endif()
add_library(dansheng_ffi SHARED IMPORTED)
set_target_properties(dansheng_ffi PROPERTIES
  IMPORTED_LOCATION "${DANSHENG_RUST_JNI_DIR}/${ANDROID_ABI}/libdansheng_ffi.so"
  IMPORTED_NO_SONAME TRUE)
add_library(dansheng_android SHARED dansheng_jni.c)
target_include_directories(dansheng_android PRIVATE "${CMAKE_CURRENT_LIST_DIR}/../../../../../../include")
target_compile_options(dansheng_android PRIVATE -Wall -Wextra -Werror)
target_link_libraries(dansheng_android dansheng_ffi)
