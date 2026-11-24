# main.py - runs automatically when the pico2-ice powers up (MicroPython)
# Loads the BTLE transmitter bitstream (top.bin) into the FPGA
# and runs the FPGA clock at 16 MHz, which btle_tx expects.

from machine import Pin
import ice

fpga = ice.fpga(cdone=Pin(40), clock=Pin(21), creset=Pin(31),
                cram_cs=Pin(5), cram_mosi=Pin(4), cram_sck=Pin(6),
                frequency=16)   # MHz

file = open("top.bin", "br")    # bitstream copied onto the board's USB drive
fpga.start()
fpga.cram(file)
file.close()

print("FPGA loaded: top.bin, clock 16 MHz")