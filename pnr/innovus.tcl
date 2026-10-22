# ---- Paths ----------------------------------------------------------
source $env(HOME)/forge-projects/sky130-9t/.forge-sky130/pdk.tcl
set REPO    $env(HOME)/Forge-Silicon-Digital-FL26
set PNR_DIR $REPO/pnr
file mkdir $PNR_DIR/reports
file mkdir $PNR_DIR/outputs

# ---- 1. Read the design ---------------------------------------------
set_db init_power_nets  $power_net
set_db init_ground_nets $ground_net
read_mmmc     $PNR_DIR/mmmc.tcl
read_physical -lef [concat $tech_lef $cell_lefs]
read_netlist  $REPO/synth/outputs/bit_timer_netlist.v -top bit_timer
init_design

# Hook every cell's power pins to VDD / VSS
connect_global_net $power_net  -type pg_pin -pin_base_name $power_net  -inst_base_name *
connect_global_net $ground_net -type pg_pin -pin_base_name $ground_net -inst_base_name *

# ---- 2. Floorplan: square, 50% full, 5 um margin on each side -------
create_floorplan -site $placement_site -core_density_size 1.0 0.5 5 5 5 5

# ---- 3. Power rails along each row of cells -------------------------
route_special -connect core_pin -nets [list $power_net $ground_net]

# ---- 4. Place cells (and the input/output pins) ---------------------
set_db place_global_place_io_pins true
place_design

# ---- 5. Build the clock tree ----------------------------------------
ccopt_design

# ---- 6. Route the wires ---------------------------------------------
route_design

# ---- 7. Checks and reports ------------------------------------------
check_drc          > $PNR_DIR/reports/bit_timer_drc.rpt
check_connectivity > $PNR_DIR/reports/bit_timer_connectivity.rpt
report_timing      > $PNR_DIR/reports/bit_timer_timing.rpt
report_area        > $PNR_DIR/reports/bit_timer_area.rpt

# ---- 8. Save --------------------------------------------------------
write_netlist $PNR_DIR/outputs/bit_timer_pnr.v
write_def     $PNR_DIR/outputs/bit_timer.def
write_db      $PNR_DIR/outputs/bit_timer.db

puts "Done: layout is in the window, reports in $PNR_DIR/reports"
