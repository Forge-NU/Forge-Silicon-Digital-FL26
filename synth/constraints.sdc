# constraints.sdc: timing constraints for bit_timer

# 12 MHz clock (period in ns)
create_clock -name clk -period 83.333 [get_ports clk]

# Inputs arrive 5 ns after the clock edge
set_input_delay 5 -clock clk [get_ports {rst_n enable div* strobe_at*}]

# Outputs (step, comp_strobe) are needed 5 ns before the next edge
set_output_delay 5 -clock clk [get_ports {step comp_strobe}]

# Small load on each output (pF)
set_load 0.01 [get_ports {step comp_strobe}]
