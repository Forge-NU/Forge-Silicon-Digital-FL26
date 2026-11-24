cmake_minimum_required(VERSION 3.13)

# btle_fpga_loader: RP2350 firmware for the pico2-ice that writes the btle_mvp bitstream into the
# FPGA's configuration flash (only when it differs), then clocks and boots the FPGA.

set(PICO_ICE_SDK_PATH "C:/Users/marsi/pico/pico-ice-sdk" CACHE PATH "Path to pico-ice-sdk")

# Bitstream to embed (icepack output of BTLE Hardware Adaptation/build.ps1)
set(BITSTREAM_BIN
    "${CMAKE_CURRENT_LIST_DIR}/../../build/btle_mvp_pico2ice.bin"
    CACHE FILEPATH "FPGA bitstream (.bin) to embed")

set(PICO_BOARD pico2_ice)
include(${PICO_ICE_SDK_PATH}/cmake/preinit_pico_ice_sdk.cmake)
include(${CMAKE_CURRENT_LIST_DIR}/pico_sdk_import.cmake)

project(btle_fpga_loader C CXX ASM)
pico_sdk_init()

add_subdirectory(${PICO_ICE_SDK_PATH} pico-ice-sdk)

if(NOT EXISTS "${BITSTREAM_BIN}")
    message(FATAL_ERROR "Bitstream not found: ${BITSTREAM_BIN} (run build.ps1 first)")
endif()

add_executable(btle_fpga_loader main.c bitstream.S)
target_compile_definitions(btle_fpga_loader PRIVATE BITSTREAM_PATH="${BITSTREAM_BIN}")
# rebuild bitstream.S whenever the .bin changes
set_source_files_properties(bitstream.S PROPERTIES OBJECT_DEPENDS "${BITSTREAM_BIN}")
target_link_libraries(btle_fpga_loader pico_ice_sdk pico_stdlib hardware_adc hardware_spi)

pico_enable_stdio_usb(btle_fpga_loader 1)
pico_enable_stdio_uart(btle_fpga_loader 0)
pico_add_extra_outputs(btle_fpga_loader)
