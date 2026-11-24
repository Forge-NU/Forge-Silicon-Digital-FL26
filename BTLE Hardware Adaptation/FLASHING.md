# Build and flash btle_mvp on the pico2-ice

Design: the iCE40 drives the AT86RF215 in **I/Q radio mode** through the SN65LVDS049. The FPGA configures the radio itself over SPI: it sets `RF_IQIFC1.CHPM = 1` (I/Q mode) and `RF_IQIFC0 = 0x36` (1.2 V LVDS common mode, 4 mA drive), then runs the BLE TX/RX loop. Pins: [btle_mvp_pico2ice.pcf](btle_mvp_pico2ice.pcf), which matches `hw/radio_if.pcf`.

Tools (already unpacked on this machine):
- OSS CAD Suite: `D:\Forge_Silicon\tools\oss-cad-suite`
- dfu-util: `D:\Forge_Silicon\tools\dfu-util\dfu-util-0.11-binaries\win64\dfu-util.exe`

## 1. Build

```powershell
cd "D:\Forge_Silicon\Forge-Silicon-Digital-FL26\BTLE Hardware Adaptation"; .\build.ps1
```

Output: `build\btle_mvp_pico2ice.bin`. The script prints Fmax for each clock. All three must say PASS: `rxclk_in` at 64 MHz, `clk_local` at 12 MHz, `bb_clk` at 16 MHz.

## 2. Write the bitstream into the FPGA's flash

The FPGA loads itself from its own SPI flash when the RP2350 releases CRESET. To write that flash, load tinyVision's stock pico2-ice firmware on the RP2350; it exposes the FPGA flash over USB. This is the same method as for `radio_spi_bridge` (see `firmware/radio_cli/README.md`).

1. Hold **BOOT** while plugging in USB. Copy the tinyVision pico2-ice default firmware `.uf2` onto the `RP2350` drive. (Not verified here: the exact file name and download location. Get it from tinyVision's pico2-ice docs or releases.)
2. List the DFU interfaces and find the one for the **FPGA flash**. Use its `alt=` number, not the CRAM/SRAM one, so the bitstream survives power cycles:
   ```powershell
   & "D:\Forge_Silicon\tools\dfu-util\dfu-util-0.11-binaries\win64\dfu-util.exe" -l
   ```
3. Write the bitstream. Replace `<alt>` with the number from step 2:
   ```powershell
   & "D:\Forge_Silicon\tools\dfu-util\dfu-util-0.11-binaries\win64\dfu-util.exe" -a <alt> -D "D:\Forge_Silicon\Forge-Silicon-Digital-FL26\BTLE Hardware Adaptation\build\btle_mvp_pico2ice.bin"
   ```
   On Windows, if dfu-util lists the device but cannot open it, install the WinUSB driver on that DFU interface with Zadig, then retry.

## 3. Put radio_cli back on the RP2350

The design needs the 12 MHz clock on ICE_35_G0 and CRESET released. `radio_cli` does both at boot: `fpga_init()` and then `fpga_boot()`.

1. Hold **BOOT** while plugging in USB.
2. Copy `C:\Users\marsi\Forge_Silicon\firmware\radio_cli\radio_cli_uart.uf2` onto the `RP2350` drive.
3. The RP2350 RGB LED turns **green** when the FPGA has configured (CDONE high).

With this bitstream loaded, radio_cli's own radio commands (`id`, `rd`, `wr`, `iqinit`, `bb*`) no longer reach the radio, because the FPGA owns the SPI bus. Load `radio_spi_bridge` again to get CLI control back.

## 4. Bring-up checks (J2 debug pins, all 3.3 V, active high)

| Pin | J2 | Signal | Expected |
|---|---|---|---|
| 38 | 14 | `led_ready` | High a few ms after boot: the radio answered (PN 0x34/0x35) and reached RX in I/Q mode |
| 43 | 16 | `led_fault` | Low. Pulsing every ~100 ms means a check failed and the sequencer is retrying |
| 4 | 34 | `dbg_rx_lock` | High most of the time: the LVDS RX word framing on RXD24 is locked |
| 3 | 33 | `led_tx` | Pulses: an advertising packet goes out every 100 ms |
| 2 | 32 | `led_rx_ok` | Pulses when a BLE packet with a good CRC is received on channel 37 |
| 45 | 30 | `uart_txd` | 115200 8N1 dump of received packets. Connect to a 3.3 V USB-serial adapter's RX, plus GND |

A phone scanner (for example nRF Connect) should show a non-connectable advertiser named **BTLE** at `C0:FF:EE:00:00:01` on channel 37.

Troubleshooting (all values are in `btle_mvp_config.vh`):
- **`led_fault` pulsing, `led_ready` never high.** SPI or radio power: check MISO (J2-13), SELN, 3.3 V on J100-20, and the RSTN wire.
- **`led_ready` high but `dbg_rx_lock` never high.** RX LVDS: try `CFG_LVDS_RX_INVERT 1`, then `CFG_SKEWDRV` 3 or 1, then `CFG_LVDS_RX_SWAP_PAIR 1`. Pin-level DDR timing is not checked by nextpnr, so SKEWDRV is the bench knob.
- **TX not seen by the phone.** Set `CFG_EN_SYNC_POLL 1`, so a missing TX I/Q sync turns into `led_fault`. Then try `CFG_LVDS_TX_INVERT 1` or `CFG_MSK_FREQ_SIGN 1`.
