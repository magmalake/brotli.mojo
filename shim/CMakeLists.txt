cmake_minimum_required(VERSION 3.16)
project(brotlimojo C)

# conda-forge splits Brotli into three packages (libbrotlicommon, libbrotlidec,
# libbrotlienc) and ships no CMake package-config for them — unlike zstd, and
# like lz4-c — so find them by name the way lz4.mojo's shim does. The headers
# all live under one <prefix>/include/brotli/ directory.
find_path(BROTLI_INCLUDE_DIR NAMES brotli/decode.h brotli/encode.h)
find_library(BROTLI_DEC_LIBRARY NAMES brotlidec)
find_library(BROTLI_ENC_LIBRARY NAMES brotlienc)
find_library(BROTLI_COMMON_LIBRARY NAMES brotlicommon)

if(NOT BROTLI_INCLUDE_DIR OR NOT BROTLI_DEC_LIBRARY OR NOT BROTLI_ENC_LIBRARY
   OR NOT BROTLI_COMMON_LIBRARY)
    message(FATAL_ERROR
        "libbrotli not found (expected the conda-forge libbrotlidec / "
        "libbrotlienc / libbrotlicommon packages)")
endif()

add_library(brotlimojo SHARED brotli_wrapper.c)
target_include_directories(brotlimojo PRIVATE ${BROTLI_INCLUDE_DIR})
# brotlicommon is listed last: both dec and enc pull symbols out of it.
target_link_libraries(brotlimojo PRIVATE
    ${BROTLI_DEC_LIBRARY} ${BROTLI_ENC_LIBRARY} ${BROTLI_COMMON_LIBRARY})
# Natural per-platform extension: libbrotlimojo.dylib on macOS, .so on Linux.
# _open_lib() in the Mojo package tries both, in that order, at runtime.
set_target_properties(brotlimojo PROPERTIES PREFIX "lib")

install(TARGETS brotlimojo LIBRARY DESTINATION lib)
