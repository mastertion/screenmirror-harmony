cmake_minimum_required(VERSION 3.5.0)
project(spacedesk_h264 CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_library(spacedesk SHARED h264_decoder.cpp)

target_compile_options(spacedesk PRIVATE -Wall -Wno-unused-parameter)

target_link_libraries(spacedesk PRIVATE
    libace_napi.z.so
    libhilog_ndk.z.so
    libnative_media_core.so
    libnative_media_codecbase.so
    libnative_media_vdec.so
)
