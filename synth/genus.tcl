# genus.tcl: synthesize bit_timer to sky130 standard cells

# ---- Load the PDK paths (library, LEFs, cell models) -----------------
source $env(HOME)/forge-projects/sky130-9t/.forge-sky130/pdk.tcl
set LIB_FILE $liberty_typical   ;# sky130_tt_1.8_25 (typical corner)

# ---- Paths ----------------------------------------------------------
set REPO    $env(HOME)/Forge-Silicon-Digital-FL26
set SYN_DIR $REPO/synth
file mkdir $SYN_DIR/reports
file mkdir $SYN_DIR/outputs

# ---- 1. Read the standard-cell library ------------------------------
read_libs $LIB_FILE

# ---- 2. Read bit_timer and build it ---------------------------------
read_hdl -sv $REPO/sar_adc_digital/rtl/bit_timer.sv
elaborate bit_timer
check_design -unresolved

# ---- 3. Apply timing constraints ------------------------------------
read_sdc $SYN_DIR/constraints.sdc

# ---- 4. Synthesize --------------------------------------------------
syn_generic   ;# RTL -> generic logic
syn_map       ;# generic logic -> sky130 cells
syn_opt       ;# clean up and optimize

# ---- 5. Reports -----------------------------------------------------
report_qor    > $SYN_DIR/reports/bit_timer_qor.rpt
report_timing > $SYN_DIR/reports/bit_timer_timing.rpt
report_area   > $SYN_DIR/reports/bit_timer_area.rpt
report_gates  > $SYN_DIR/reports/bit_timer_gates.rpt
report_power  > $SYN_DIR/reports/bit_timer_power.rpt

# ---- 6. Outputs for gate-level sim and Innovus ----------------------
write_hdl > $SYN_DIR/outputs/bit_timer_netlist.v
write_sdc > $SYN_DIR/outputs/bit_timer_out.sdc

puts "Done: reports in $SYN_DIR/reports, netlist in $SYN_DIR/outputs"
exit
