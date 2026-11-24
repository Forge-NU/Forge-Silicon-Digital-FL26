// The FPGA bitstream, embedded at build time (path from CMake: BITSTREAM_PATH).
    .section .rodata.bitstream, "a"
    .balign 4
    .global bitstream_start
    .global bitstream_end
bitstream_start:
    .incbin BITSTREAM_PATH
bitstream_end:
    .balign 4
