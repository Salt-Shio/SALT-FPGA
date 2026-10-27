# Run tb_fc_neuron_memory once per parameter set, using simulation set sim_fc_neuron_memory of the SaltNET project.
# The testbench makes its own write values, so there are no reference files.
# The first run creates the simulation set (sim_common.tcl registers all RTL in sources_1); later runs skip that.
# Compile runs once; each parameter set changes the simset generic, then elaborates and simulates.
# Usage:
#   PowerShell (batch mode, close the GUI first):
#       cd D:\Project\SALT-FPGA\SaltNET\SaltNET.sim
#       vivado -mode batch -source D:/Project/SALT-FPGA/SaltNET/scripts/fc/run_tb_fc_neuron_memory.tcl
#   Do not source this from the GUI Tcl console: there the repeated elaborate steps intermittently fail with
#   'Spawn failed' (cause unknown, see the vivado-usage skill, section 8.7). Use the GUI only for a single
#   Run Simulation with the testbench defaults.
#   (Vivado writes vivado.log/.jou and crash dumps to the launch directory; start it inside SaltNET.sim.)
# Outputs go to SaltNET.sim/sim_fc_neuron_memory/behav/xsim; each set is judged from simulate.log right after it runs.
# This file is ASCII only: Vivado reads Tcl sources in the system code page, not UTF-8.

set scripts_dir [file dirname [file normalize [info script]]]
source [file join $scripts_dir .. sim_common.tcl]

set simset_name sim_fc_neuron_memory

# OUT_NEURONS NEURONS_PER_ROW MEMBRANE_WIDTH READ_LATENCY
set param_sets {
    {10 4 14 1}
    {10 4 11 2}
    {10 3 9 2}
    {5 1 7 1}
    {3 4 6 1}
    {1 1 4 2}
}
# 10 4 14 / 10 4 11 : trained out layer, wrap / saturate membrane width (n_col = 4 for now)
# 10 3 9            : n_col not a power of 2, last row has 1 neuron, 4 rows
# 5 1 7             : one neuron per row
# 3 4 6             : n_col > n_out, only one row (depth 1)
# 1 1 4             : depth 1, minimum widths

proc fc_neuron_memory_params {param_set} {
    lassign $param_set out_neurons neurons_per_row membrane_width read_latency
    return "OUT_NEURONS=$out_neurons NEURONS_PER_ROW=$neurons_per_row MEMBRANE_WIDTH=$membrane_width READ_LATENCY=$read_latency"
}

# tb_fc_neuron_memory prints the parameters as NAME=value, followed by a colon
proc fc_neuron_memory_prefix {param_set} {
    return "[fc_neuron_memory_params $param_set]:"
}

open_saltnet_project
create_simset_if_missing $simset_name tb_fc_neuron_memory {fc/tb_fc_neuron_memory.sv}

run_param_sets $simset_name tb_fc_neuron_memory "" $param_sets fc_neuron_memory_params fc_neuron_memory_prefix
