# nascar - ReXGlue Recompiled Project
#
# SDK boilerplate lives in generated/rexglue.cmake.

cmake_minimum_required(VERSION 3.25)
project(nascar LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Build the ReXGlue SDK from the patched submodule (tools/rexglue-sdk) unless
# the caller points elsewhere, and enable FidelityFX for FSR/CAS output.
set(REXSDK_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../tools/rexglue-sdk" CACHE PATH
    "Path to rexglue-sdk source tree")
set(REXGLUE_ENABLE_FIDELITYFX ON CACHE BOOL "Enable AMD FidelityFX (FSR/CAS output)")

include(generated/rexglue.cmake)

# Sources
set(NASCAR_SOURCES
    src/main.cpp
)

if(WIN32)
    add_executable(nascar WIN32 ${NASCAR_SOURCES})
else()
    add_executable(nascar ${NASCAR_SOURCES})
endif()

# xenos = Xenia-derived Xenos GPU emulation (D3D12), loaded at runtime via --gpu_plugin=xenos
rexglue_setup_target(nascar GPU_PLUGINS xenos)

# rexglue_setup_target copies the GPU plugin only when nascar.exe relinks, so a
# change that rebuilds just the plugin left a stale DLL next to the exe. This
# target re-stages it on every build.
add_custom_target(nascar_stage_gpu_plugin ALL
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        $<TARGET_FILE:rexgpu-xenos> $<TARGET_FILE_DIR:nascar>
    DEPENDS rexgpu-xenos nascar
    VERBATIM)

# Runtime settings (nascar.toml) next to the exe. Copied only when missing so
# changes made from the in-game settings dialog are not overwritten by a rebuild.
add_custom_command(TARGET nascar POST_BUILD
    COMMAND ${CMAKE_COMMAND}
        -DSRC=${CMAKE_CURRENT_SOURCE_DIR}/nascar.toml
        -DDST=$<TARGET_FILE_DIR:nascar>/nascar.toml
        -P ${CMAKE_CURRENT_SOURCE_DIR}/cmake/copy_if_missing.cmake
    # SDL controller database (github.com/mdqinc/SDL_GameControllerDB): always refreshed
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
        ${CMAKE_CURRENT_SOURCE_DIR}/gamecontrollerdb.txt
        $<TARGET_FILE_DIR:nascar>/gamecontrollerdb.txt
    VERBATIM)
