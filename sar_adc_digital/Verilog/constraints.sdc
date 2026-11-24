# constraints.sdc: Silicluster v3 timing (10 MHz max clock)

create_clock -name clk -period 100 [get_ports clk]

# Inputs arrive 5 ns after the clock edge, outputs are needed 5 ns before the next one
set_input_delay  5 -clock clk [get_ports {rst_n start comp_out div*}]
set_output_delay 5 -clock clk [all_outputs]

# Small load on each output (pF)
set_load 0.01 [all_outputs]
