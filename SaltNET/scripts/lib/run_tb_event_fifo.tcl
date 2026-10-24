# Run tb_event_fifo once per parameter set, using simulation set sim_event_fifo of the SaltNET project.
# The testbench checks EventFIFO against its own queue model; it reads no reference files.
# The first run creates the simulation set (sim_common.tcl registers all RTL in sources_1); later runs skip that.
# Compile runs once; each parameter set changes the simset generic, then elaborates and simulates.
# Usage:
#   PowerShell (batch mode, close the GUI first):
#       cd D:\Project\SALT-FPGA\SaltNET\SaltNET.sim
#       vivado -mode batch -source D:/Project/SALT-FPGA/SaltNET/scripts/lib/run_tb_event_fifo.tcl
#   Do not source this from the GUI Tcl console: there the repeated elaborate steps intermittently fail with
#   'Spawn failed' (cause unknown, see the vivado-usage skill, section 8.7). Use the GUI only for a single
#   Run Simulation with the testbench defaults.
#   (Vivado writes vivado.log/.jou and crash dumps to the launch directory; start it inside SaltNET.sim.)
# Outputs go to SaltNET.sim/sim_event_fifo/behav/xsim; each set is judged from simulate.log right after it runs.
# This file is ASCII only: Vivado reads Tcl sources in the system code page, not UTF-8.

set scripts_dir [file dirname [file normalize [info script]]]
source [file join $scripts_dir .. sim_common.tcl]

set simset_name sim_event_fifo

# DATA_WIDTH DEPTH
set param_sets {
    {8 16}
}

proc event_fifo_generic {param_set} {
    lassign $param_set data_width depth
    return "DATA_WIDTH=$data_width DEPTH=$depth"
}

# tb_event_fifo prints the same NAME=value list as the generic, followed by a colon
proc event_fifo_prefix {param_set} {
    return "[event_fifo_generic $param_set]:"
}

open_saltnet_project
create_simset_if_missing $simset_name tb_event_fifo {lib/tb_event_fifo.sv}

run_param_sets $simset_name tb_event_fifo {} $param_sets event_fifo_generic event_fifo_prefix
