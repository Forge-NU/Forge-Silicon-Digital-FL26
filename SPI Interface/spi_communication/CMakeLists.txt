cmake_minimum_required(VERSION 3.13)

set(PICO_BOARD pico2_ice)

include($ENV{PICO_ICE_SDK_PATH}/cmake/preinit_pico_ice_sdk.cmake)
include($ENV{PICO_SDK_PATH}/external/pico_sdk_import.cmake)

project(at86rf215_iq C CXX ASM)
set(CMAKE_C_STANDARD 11)

pico_sdk_init()

add_executable(${CMAKE_PROJECT_NAME}
    main.c
)

target_link_libraries(${CMAKE_PROJECT_NAME}
    pico_stdlib
    hardware_spi
)

pico_enable_stdio_usb(${CMAKE_PROJECT_NAME} 1)
pico_enable_stdio_uart(${CMAKE_PROJECT_NAME} 0)
pico_add_extra_outputs(${CMAKE_PROJECT_NAME})