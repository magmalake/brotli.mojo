cmake_minimum_required(VERSION 3.16)
project(brotlimojo C)

# conda-forge ships no CMake package-config for Brotli — unlike zstd, and like
# lz4-c — so find it by name the way lz4.mojo's shim does. It is also split
# five ways: the shared objects are in libbrotlidec / libbrotlienc /
# libbrotlicommon, while include/brotli/*.h is in the `brotli` package. All
# four are host-dependencies of this shim; see shim/pixi.toml.
find_path(BROTLI_INCLUDE_DIR NAMES brotli/decode.h brotli/encode.h)
find_library(BROTLI_DEC_LIBRARY NAMES brotlidec)
find_library(BROTLI_ENC_LIBRARY NAMES brotlienc)
find_library(BROTLI_COMMON_LIBRARY NAMES brotlicommon)

# Named individually: a build that fails because one of four search results is
# empty should say which one, and the found paths in the log are what catches a
# header picked up from outside the prefix (a Homebrew /opt/homebrew/include,
# say, which builds on a laptop and fails on Linux CI).
foreach(var BROTLI_INCLUDE_DIR BROTLI_DEC_LIBRARY BROTLI_ENC_LIBRARY
            BROTLI_COMMON_LIBRARY)
    if(NOT ${var})
        message(FATAL_ERROR
            "${var} not found — expected the conda-forge brotli, "
            "libbrotlidec, libbrotlienc and libbrotlicommon packages")
    endif()
    message(STATUS "${var}: ${${var}}")
endforeach()

add_library(brotlimojo SHARED brotli_wrapper.c)
target_include_directories(brotlimojo PRIVATE ${BROTLI_INCLUDE_DIR})
# brotlicommon is listed last: both dec and enc pull symbols out of it.
target_link_libraries(brotlimojo PRIVATE
    ${BROTLI_DEC_LIBRARY} ${BROTLI_ENC_LIBRARY} ${BROTLI_COMMON_LIBRARY})
# Natural per-platform extension: libbrotlimojo.dylib on macOS, .so on Linux.
# _open_lib() in the Mojo package tries both, in that order, at runtime.
set_target_properties(brotlimojo PROPERTIES PREFIX "lib")

install(TARGETS brotlimojo LIBRARY DESTINATION lib)
