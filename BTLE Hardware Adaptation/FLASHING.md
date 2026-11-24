# Build and flash btle_mvp on the pico2-ice

Design: the iCE40 drives the AT86RF215 in **I/Q radio mode** through the SN65LVDS049. The FPGA configures the radio itself over SPI: it sets `RF_IQIFC1.CHPM = 1` (I/Q mode) and `RF_IQIFC0 = 0x36` (1.2 V LVDS common mode, 4 mA drive), then runs the BLE TX/RX loop. Pins: [btle_mvp_pico2ice.pcf](btle_mvp_pico2ice.pcf), which matches `hw/radio_if.pcf`.

Tools on this machine:
- OSS CAD Suite (FPGA build): `D:\Forge_Silicon\tools\oss-cad-suite`
- Pico SDK 2.1.1 `C:\Users\marsi\pico\pico-sdk`, pico-ice-sdk `C:\Users\marsi\pico\pico-ice-sdk`, Arm GCC 14.2 and Ninja from the MCUXpresso tools, MSYS2 UCRT64 (loader firmware build)

## 1. Build

```powershell
cd "D:\Forge_Silicon\Forge-Silicon-Digital-FL26\BTLE Hardware Adaptation"; .\build.ps1
```

Output: `build\btle_mvp_pico2ice.bin`. The script prints Fmax for each clock. All three must say PASS: `rxclk_in` at 64 MHz, `clk_local` at 12 MHz, `bb_clk` at 16 MHz.

## 2. Flash it with the loader firmware (verified on the board, 2026-11-24)

`D:\Forge_Silicon\firmware\btle_fpga_loader` is RP2350 firmware with the bitstream built in. On every boot it:
1. Starts the FPGA's 12 MHz clock (GPIO21 → ICE_35_G0) and holds the FPGA in reset.
2. Wakes the FPGA's config flash (W25Q32JV) and rewrites it **only if** it differs from the embedded bitstream, then verifies it.
3. Lets the FPGA boot from that flash. This persists, but the RP2350 must still provide the clock.

If the flash doesn't answer, it loads the FPGA directly over SPI instead (volatile; repeated on every boot). The RGB LED shows the result: green = FPGA configured, blue = writing, red = failed. It prints a status line every 2 s on its USB serial port.

1. Rebuild the loader after every new bitstream (it embeds `build\btle_mvp_pico2ice.bin`):
   ```powershell
   cd D:\Forge_Silicon\firmware\btle_fpga_loader; $env:PATH = "C:\msys64\ucrt64\bin;$env:PATH"; cmake --build build
   ```
   First time only, configure before that build: `cmake -S . -B build -G Ninja -DPICO_SDK_PATH=C:/Users/marsi/pico/pico-sdk -DPICO_TOOLCHAIN_PATH=C:/Users/marsi/.mcuxpressotools/arm-gnu-toolchain-14.2.rel1-mingw-w64-x86_64-arm-none-eabi -DCMAKE_MAKE_PROGRAM=C:/Users/marsi/.mcuxpressotools/ninja-1.12.1/ninja.exe`
2. Hold **BOOT** while plugging in USB (or, if the loader is already running, open its COM port at 1200 baud). A drive named `RP2350` appears.
3. Copy `build\btle_fpga_loader.uf2` onto it. The board reboots, writes the flash if needed (a few seconds, blue LED), and boots the FPGA (green LED).
4. Optional: read the status on the loader's USB serial port at any baud. Expect `flash JEDEC EF4016, flash written+verified` the first time, `flash up to date` afterwards, and `FPGA CONFIGURED`.

Flash wiring (pico2-ice Rev1/Rev2 netlist): the RP2350 writes the flash with MOSI on GPIO7 (flash DI, iCE40 SPI_SO), MISO on GPIO4 (flash DO, iCE40 SPI_SI), SCK on GPIO6 and CS on GPIO5. That's the opposite of what the "SO"/"SI" labels suggest from the RP2350's side.

The flash can be left in continuous-read mode, and then it ignores normal commands (JEDEC ID reads `000000`). The loader sends the mode-reset sequence (16 clocks with DI high), a software reset and a power-down release before anything else.

While this design runs, `radio_cli` isn't needed and its radio commands wouldn't reach the radio: the FPGA owns the radio SPI. Load `radio_spi_bridge` plus `radio_cli` again to get CLI control back.

## 3. Bring-up checks (J2 debug pins, all 3.3 V, active high)

| Pin | J2 | Signal | Expected |
|---|---|---|---|
| 38 | 14 | `led_ready` | High a few ms after boot: the radio answered (PN 0x34/0x35) and reached RX in I/Q mode |
| 43 | 16 | `led_fault` | Low. Pulsing every ~100 ms means a check failed and the sequencer is retrying |
| 4 | 34 | `dbg_rx_lock` | High most of the time: the LVDS RX word framing on RXD24 is locked |
| 3 | 33 | `led_tx` | Pulses: an advertising packet goes out every 100 ms |
| 2 | 32 | `led_rx_ok` | Pulses when a BLE packet with a good CRC is received on channel 37 |
| 45 | 30 | `uart_txd` | 115200 8N1 dump of received packets. Connect to a 3.3 V USB-serial adapter's RX, plus GND |

### SPI terminal (loader firmware, USB serial)

Open the loader's COM port (PuTTY, Serial, any baud) and press Enter. It talks to the FPGA's debug SPI slave (`spi_dbg_slave.v`, RP2350 GPIO26/20/24/22 ↔ ICE21/27/26/20):
- `stat`: FPGA status (ready/fault/counters, part number seen at bring-up) plus key radio registers read **through the FPGA's radio SPI**.
- `rd <addr>`: read any radio register through the FPGA (hex, e.g. `rd 0x0202`).
- `fpga <reg> [n]`: raw debug registers (map in `btle_mvp_top.v`).
- `probe`, `scope`, `cap <addr>`: watch the radio SPI wires from the RP2350, which shares those nets (edge counts, raw waveform, decoded transfer).

A phone scanner (for example nRF Connect) should show a non-connectable advertiser named **BTLE** at `C0:FF:EE:00:00:01` on channel 37.

Troubleshooting (all values are in `btle_mvp_config.vh`):
- **`led_fault` pulsing, `led_ready` never high.** SPI or radio power. Radio SPI is on the RP-ICE PMOD pins: SCK ICE18 → J100-18, MOSI ICE23 → J100-16, MISO ICE19 ← J100-17, SELN ICE25 → J100-15. Also check 3.3 V on J100-20, ground, and the RSTN wire (J2-12 → J100-7). Use the loader terminal (below) to see what the FPGA reads back.
- **Radio reads intermittently wrong or `0x00` (seen on the bench, 2026-11-24).** The radio answers but decodes the wrong register; most likely SCK ringing on long jumper wires. Add 33–100 Ω in series with SCK (and MOSI/SELN) at the pico2-ice pin, run a ground wire alongside, keep the wires short. A slower SPI clock does not fix it.
- **`led_ready` high but `dbg_rx_lock` never high.** RX LVDS: try `CFG_LVDS_RX_INVERT 1`, then `CFG_SKEWDRV` 3 or 1, then `CFG_LVDS_RX_SWAP_PAIR 1`. Pin-level DDR timing is not checked by nextpnr, so SKEWDRV is the bench knob.
- **TX not seen by the phone.** Set `CFG_EN_SYNC_POLL 1`, so a missing TX I/Q sync turns into `led_fault`. Then try `CFG_LVDS_TX_INVERT 1` or `CFG_MSK_FREQ_SIGN 1`.
