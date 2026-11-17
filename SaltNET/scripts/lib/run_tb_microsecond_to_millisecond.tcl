# Run tb_microsecond_to_millisecond once per parameter set, using simulation set sim_microsecond_to_millisecond
# of the SaltNET project. The testbench computes floor(t_us / 1000) itself; it reads no reference files.
# The first run creates the simulation set (sim_common.tcl registers all RTL in sources_1); later runs skip that.
# Compile runs once; each parameter set changes the simset generic, then elaborates and simulates.
# Usage:
#   PowerShell (batch mode, close the GUI first):
#       cd D:\Project\SALT-FPGA\SaltNET\SaltNET.sim
#       vivado -mode batch -source D:/Project/SALT-FPGA/SaltNET/scripts/lib/run_tb_microsecond_to_millisecond.tcl
#   Do not source this from the GUI Tcl console: there the repeated elaborate steps intermittently fail with
#   'Spawn failed' (cause unknown, see the vivado-usage skill, section 8.7). Use the GUI only for a single
#   Run Simulation with the testbench defaults.
#   (Vivado writes vivado.log/.jou and crash dumps to the launch directory; start it inside SaltNET.sim.)
# Outputs go to SaltNET.sim/sim_microsecond_to_millisecond/behav/xsim; each set is judged from simulate.log
# right after it runs.
# This file is ASCII only: Vivado reads Tcl sources in the system code page, not UTF-8.

set scripts_dir [file dirname [file normalize [info script]]]
source [file join $scripts_dir .. sim_common.tcl]

set simset_name sim_microsecond_to_millisecond

# TIME_WIDTH PAYLOAD_WIDTH PRODUCT_STAGES
#   16 23 3 : the planned setting (network time width; x 11 + y 11 + polarity 1; 3 stages after the multiply)
#   16 23 1 : one stage after the multiply
#   25  1 5 : full quotient (largest TIME_WIDTH), 1-bit payload, 5 stages
set param_sets {
    {16 23 3}
    {16 23 1}
    {25 1 5}
}

proc microsecond_to_millisecond_generic {param_set} {
    lassign $param_set time_width payload_width product_stages
    return "TIME_WIDTH=$time_width PAYLOAD_WIDTH=$payload_width PRODUCT_STAGES=$product_stages"
}

# tb_microsecond_to_millisecond prints the same NAME=value list as the generic, followed by a colon
proc microsecond_to_millisecond_prefix {param_set} {
    return "[microsecond_to_millisecond_generic $param_set]:"
}

open_saltnet_project
create_simset_if_missing $simset_name tb_microsecond_to_millisecond {lib/tb_microsecond_to_millisecond.sv}

run_param_sets $simset_name tb_microsecond_to_millisecond {} $param_sets \
    microsecond_to_millisecond_generic microsecond_to_millisecond_prefix
