source $env(HOME)/forge-projects/sky130-9t/.forge-sky130/pdk.tcl

create_library_set      -name typ_libs   -timing $liberty_typical
create_rc_corner        -name typ_rc     -qrc_tech $qrc_typical
create_timing_condition -name typ_cond   -library_sets typ_libs
create_delay_corner     -name typ_corner -timing_condition typ_cond -rc_corner typ_rc
create_constraint_mode  -name func \
    -sdc_files $env(HOME)/Forge-Silicon-Digital-FL26/synth/outputs/bit_timer_out.sdc
create_analysis_view    -name typ_view   -constraint_mode func -delay_corner typ_corner

set_analysis_view -setup typ_view -hold typ_view
