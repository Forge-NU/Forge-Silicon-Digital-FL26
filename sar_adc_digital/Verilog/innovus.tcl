# innovus.tcl: place and route the Silicluster version of sar_adc_digital
# in the 180 x 115 um Silicluster v3 slot

source $env(HOME)/forge-projects/sky130-9t/.forge-sky130/pdk.tcl
set DIR $env(HOME)/Forge-Silicon-Digital-FL26/sar_adc_digital/Verilog
set TOP sar_adc_digital
file mkdir $DIR/pnr/reports
file mkdir $DIR/pnr/outputs

# ---- 1. Read the design ---------------------------------------------
set_db init_power_nets  $power_net
set_db init_ground_nets $ground_net
read_mmmc     $DIR/mmmc.tcl
read_physical -lef [concat $tech_lef $cell_lefs]
read_netlist  $DIR/synth/outputs/${TOP}_netlist.v -top $TOP
init_design

connect_global_net $power_net  -type pg_pin -pin_base_name $power_net  -inst_base_name *
connect_global_net $ground_net -type pg_pin -pin_base_name $ground_net -inst_base_name *

# ---- 2. Floorplan: fixed 180 x 115 um die, 5 um margin on each side --
create_floorplan -site $placement_site -die_size {180 115 5 5 5 5}

# ---- 3. Power rails along each row ----------------------------------
route_special -connect core_pin -nets [list $power_net $ground_net]

# ---- 4. Place cells and pins ----------------------------------------
set_db place_global_place_io_pins true
place_design

# ---- 5. Clock tree --------------------------------------------------
ccopt_design

# ---- 6. Route -------------------------------------------------------
route_design

# ---- 7. Checks and reports ------------------------------------------
check_drc          > $DIR/pnr/reports/${TOP}_drc.rpt
check_connectivity > $DIR/pnr/reports/${TOP}_connectivity.rpt
report_timing      > $DIR/pnr/reports/${TOP}_timing.rpt
report_area        > $DIR/pnr/reports/${TOP}_area.rpt

# ---- 8. Save --------------------------------------------------------
write_netlist $DIR/pnr/outputs/${TOP}_pnr.v
write_def     $DIR/pnr/outputs/${TOP}.def
write_db      $DIR/pnr/outputs/${TOP}.db

puts "Done: reports in $DIR/pnr/reports"
