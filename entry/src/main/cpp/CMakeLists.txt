cmake_minimum_required(VERSION 3.5.0)
project(spacedesk_h264)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

if(DEFINED PACKAGE_FIND_FILE)
    include(${PACKAGE_FIND_FILE})
endif()

add_library(h264dec SHARED h264_decoder.cpp)

target_link_libraries(h264dec PUBLIC
    libace_napi.z.so
    libhilog_ndk.z.so
    libnative_media_codecbase.so
    libnative_media_core.so
    libnative_media_vdec.so
)

# ---- TLS-PSK 传输模块（spacedesk 加密连接，键盘必需） ----
set(OPENSSL_DIR F:/AICODE/spacedesk/ohos-openssl/prelude/arm64-v8a)

add_library(sectls SHARED secure_socket.cpp)

target_include_directories(sectls PRIVATE ${OPENSSL_DIR}/include)

target_link_libraries(sectls PUBLIC
    libace_napi.z.so
    libhilog_ndk.z.so
    ${OPENSSL_DIR}/lib/libssl.a
    ${OPENSSL_DIR}/lib/libcrypto.a
)
