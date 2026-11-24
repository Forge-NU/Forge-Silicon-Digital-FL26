# genus.tcl: synthesize the Silicluster version of sar_adc_digital

source $env(HOME)/forge-projects/sky130-9t/.forge-sky130/pdk.tcl
set REPO $env(HOME)/Forge-Silicon-Digital-FL26
set DIR  $REPO/sar_adc_digital/Verilog
set TOP  sar_adc_digital
file mkdir $DIR/synth/reports
file mkdir $DIR/synth/outputs

# ---- 1. Read the standard-cell library ------------------------------
read_libs $liberty_typical

# ---- 2. Read the RTL -------------------------------------------------
# Only the .v top from this folder, never the .sv one: both define sar_adc_digital
read_hdl $DIR/bit_timer.v
read_hdl $DIR/sar_adc_digital.v
read_hdl $DIR/fsm_code.v
elaborate $TOP
check_design -unresolved

# ---- 3. Timing constraints ------------------------------------------
read_sdc $DIR/constraints.sdc

# ---- 4. Synthesize --------------------------------------------------
syn_generic
syn_map
syn_opt

# ---- 5. Reports -----------------------------------------------------
report_qor    > $DIR/synth/reports/${TOP}_qor.rpt
report_timing > $DIR/synth/reports/${TOP}_timing.rpt
report_area   > $DIR/synth/reports/${TOP}_area.rpt
report_gates  > $DIR/synth/reports/${TOP}_gates.rpt

# ---- 6. Outputs for gate-level sim and Innovus ----------------------
write_hdl > $DIR/synth/outputs/${TOP}_netlist.v
write_sdc > $DIR/synth/outputs/${TOP}_out.sdc

puts "Done: reports in $DIR/synth/reports"
exit
