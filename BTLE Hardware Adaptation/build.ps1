# build.ps1  --  build btle_mvp_pico2ice.bin for the pico2-ice (iCE40UP5K-SG48)
#
#   .\build.ps1                          # uses D:\Forge_Silicon\tools\oss-cad-suite
#   .\build.ps1 -OssCad C:\path\to\oss-cad-suite -Seeds 10
#
# Output: build\btle_mvp_pico2ice.bin (write it to the FPGA flash, see FLASHING.md).
#
# Notes
#  * Synthesis replaces synth_ice40's abc9 LUT-mapping step with classic `abc -lut 4`: the
#    abc9 path in OSS CAD Suite 2026-09-28 for Windows asserts in the xaiger2 writer.
#  * nextpnr is run with several seeds; the first that meets all three clocks (12 MHz
#    clk_local, 64 MHz rxclk_in, 16 MHz bb_clk, see btle_mvp_clocks.py) is kept.  The 64 MHz
#    domain has ~10% margin, so most seeds pass.
param(
    [string]$OssCad = "D:\Forge_Silicon\tools\oss-cad-suite",
    [int]$Seeds = 8
)
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

if (-not (Test-Path "$OssCad\bin\nextpnr-ice40.exe")) {
    throw "nextpnr-ice40 not found under $OssCad\bin. Pass -OssCad <oss-cad-suite folder>."
}
$env:PATH = "$OssCad\bin;$OssCad\lib;$env:PATH"

$top  = "btle_mvp_pico2ice"
$repo = "..\BTLE\verilog"
$src  = @(
    "btle_mvp_pico2ice.v", "btle_mvp_top.v", "rf215_init.v", "spi_master.v", "bb_clkgen.v",
    "ddr_io.v", "lvds_rx.v", "lvds_tx.v", "btle_tx_min.v", "msk_modulator.v",
    "pdu_uart_dump.v", "sync_cells.v", "btle_rx_sps.v",
    "$repo\btle_rx_core.v", "$repo\gfsk_demodulation.v", "$repo\search_unique_bit_sequence.v",
    "$repo\scramble_core.v", "$repo\crc24_core.v", "$repo\serial_in_ram_out.v",
    "$repo\sdpram_two_clk.v"
) -join " "

New-Item -ItemType Directory -Force build | Out-Null

Write-Host "== yosys"
$ys = "read_verilog -DICE40 -I. $src; " +
      "synth_ice40 -top $top -dsp -run begin:map_luts; " +
      "techmap -map +/ice40/latches_map.v; abc -dress -lut 4; ice40_wrapcarry -unwrap; " +
      "techmap -map +/ice40/ff_map.v; clean; opt_lut -tech ice40; " +
      "synth_ice40 -top $top -dsp -run map_cells: -json build/$top.json"
& yosys -q -l build/yosys.log -p $ys
if ($LASTEXITCODE -ne 0) { throw "yosys failed, see build\yosys.log" }

Write-Host "== nextpnr-ice40"
$ok = $false
for ($s = 1; $s -le $Seeds; $s++) {
    & nextpnr-ice40 --up5k --package sg48 --json build/$top.json --pcf btle_mvp_pico2ice.pcf `
        --pre-pack btle_mvp_clocks.py --asc build/$top.asc --log build/nextpnr.log --seed $s 2>$null | Out-Null
    $fmax = (Select-String -Path build/nextpnr.log -Pattern "Max frequency for clock +'rxclk" |
             Select-Object -Last 1).Line -replace '.*: ', ''
    Write-Host ("   seed {0}: rxclk_in {1}" -f $s, $fmax)
    if ($LASTEXITCODE -eq 0) { $ok = $true; break }
}
if (-not $ok) { throw "no seed met timing in $Seeds tries, see build\nextpnr.log" }

Write-Host "== icepack"
& icepack build/$top.asc build/$top.bin
if ($LASTEXITCODE -ne 0) { throw "icepack failed" }

# resources (last utilisation report) and final post-route Fmax (last 3 lines; nextpnr also
# prints a pre-route estimate earlier in the log, which can read FAIL and is not the result)
Select-String -Path build/nextpnr.log -Pattern "ICESTORM_LC:|ICESTORM_RAM:|ICESTORM_DSP:|SB_IO:" |
    Select-Object -Last 4 | ForEach-Object { Write-Host ("   " + ($_.Line -replace '^Info: *', '').Trim()) }
Select-String -Path build/nextpnr.log -Pattern "Max frequency for clock" |
    Select-Object -Last 3 | ForEach-Object { Write-Host ("   " + ($_.Line -replace '^Info: *', '')) }
Write-Host ("== done: {0}" -f (Resolve-Path build/$top.bin))
