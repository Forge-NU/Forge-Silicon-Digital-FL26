# Locates the pico-sdk from PICO_SDK_PATH (CMake variable or environment variable).
if (DEFINED ENV{PICO_SDK_PATH} AND (NOT PICO_SDK_PATH))
    set(PICO_SDK_PATH $ENV{PICO_SDK_PATH})
endif ()
set(PICO_SDK_PATH "${PICO_SDK_PATH}" CACHE PATH "Path to the Raspberry Pi Pico SDK")

if (NOT PICO_SDK_PATH)
    message(FATAL_ERROR "Set PICO_SDK_PATH to a pico-sdk 2.x checkout (git clone --recurse-submodules https://github.com/raspberrypi/pico-sdk)")
endif ()

get_filename_component(PICO_SDK_PATH "${PICO_SDK_PATH}" REALPATH BASE_DIR "${CMAKE_BINARY_DIR}")
if (NOT EXISTS ${PICO_SDK_PATH}/pico_sdk_init.cmake)
    message(FATAL_ERROR "'${PICO_SDK_PATH}' does not look like a pico-sdk checkout")
endif ()

include(${PICO_SDK_PATH}/pico_sdk_init.cmake)
