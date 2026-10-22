# ####################################################################

#  Created by Genus(TM) Synthesis Solution 26.10-p002_1 on Thu Oct 22 14:57:39 EDT 2026

# ####################################################################

set sdc_version 2.0

set_units -capacitance 1000fF
set_units -time 1000ps

# Set the current design
current_design bit_timer

create_clock -name "clk" -period 83.333 -waveform {0.0 41.6665} [get_ports clk]
set_load -pin_load 0.01 [get_ports step]
set_load -pin_load 0.01 [get_ports comp_strobe]
set_clock_gating_check -setup 0.0 
set_input_delay -clock [get_clocks clk] -add_delay 5.0 [get_ports rst_n]
set_input_delay -clock [get_clocks clk] -add_delay 5.0 [get_ports enable]
set_input_delay -clock [get_clocks clk] -add_delay 5.0 [get_ports {div[7]}]
set_input_delay -clock [get_clocks clk] -add_delay 5.0 [get_ports {div[6]}]
set_input_delay -clock [get_clocks clk] -add_delay 5.0 [get_ports {div[5]}]
set_input_delay -clock [get_clocks clk] -add_delay 5.0 [get_ports {div[4]}]
set_input_delay -clock [get_clocks clk] -add_delay 5.0 [get_ports {div[3]}]
set_input_delay -clock [get_clocks clk] -add_delay 5.0 [get_ports {div[2]}]
set_input_delay -clock [get_clocks clk] -add_delay 5.0 [get_ports {div[1]}]
set_input_delay -clock [get_clocks clk] -add_delay 5.0 [get_ports {div[0]}]
set_input_delay -clock [get_clocks clk] -add_delay 5.0 [get_ports {strobe_at[7]}]
set_input_delay -clock [get_clocks clk] -add_delay 5.0 [get_ports {strobe_at[6]}]
set_input_delay -clock [get_clocks clk] -add_delay 5.0 [get_ports {strobe_at[5]}]
set_input_delay -clock [get_clocks clk] -add_delay 5.0 [get_ports {strobe_at[4]}]
set_input_delay -clock [get_clocks clk] -add_delay 5.0 [get_ports {strobe_at[3]}]
set_input_delay -clock [get_clocks clk] -add_delay 5.0 [get_ports {strobe_at[2]}]
set_input_delay -clock [get_clocks clk] -add_delay 5.0 [get_ports {strobe_at[1]}]
set_input_delay -clock [get_clocks clk] -add_delay 5.0 [get_ports {strobe_at[0]}]
set_output_delay -clock [get_clocks clk] -add_delay 5.0 [get_ports step]
set_output_delay -clock [get_clocks clk] -add_delay 5.0 [get_ports comp_strobe]
set_wire_load_mode "enclosed"
