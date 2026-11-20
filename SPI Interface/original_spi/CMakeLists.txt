cmake_minimum_required(VERSION 3.13)

set(PICO_BOARD pico2_ice)
include($ENV{PICO_ICE_SDK_PATH}/cmake/preinit_pico_ice_sdk.cmake)
include($ENV{PICO_SDK_PATH}/external/pico_sdk_import.cmake)

project(at86rf215_iq C CXX ASM)
set(CMAKE_C_STANDARD 11)

pico_sdk_init()

add_executable(at86rf215_iq main.c)
target_link_libraries(at86rf215_iq pico_stdlib hardware_spi)

pico_enable_stdio_usb(at86rf215_iq 1)
pico_enable_stdio_uart(at86rf215_iq 0)
pico_add_extra_outputs(at86rf215_iq)