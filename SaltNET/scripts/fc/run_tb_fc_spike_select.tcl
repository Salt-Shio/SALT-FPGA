# Run tb_fc_spike_select once per parameter set, using simulation set sim_fc_spike_select of the SaltNET project.
# Generate the reference files first (WSL): gen_fc_spike_select_ref.py.
# The parameter list below must match PARAM_SETS in that script.
# The first run creates the simulation set (sim_common.tcl registers all RTL in sources_1); later runs skip that.
# Compile runs once; each parameter set changes the simset generic, then elaborates and simulates.
# Usage:
#   PowerShell (batch mode, close the GUI first):
#       cd D:\Project\SALT-FPGA\SaltNET\SaltNET.sim
#       vivado -mode batch -source D:/Project/SALT-FPGA/SaltNET/scripts/fc/run_tb_fc_spike_select.tcl
#   Do not source this from the GUI Tcl console: there the repeated elaborate steps intermittently fail with
#   'Spawn failed' (cause unknown, see the vivado-usage skill, section 8.7). Use the GUI only for a single
#   Run Simulation with the testbench defaults.
#   (Vivado writes vivado.log/.jou and crash dumps to the launch directory; start it inside SaltNET.sim.)
# Outputs go to SaltNET.sim/sim_fc_spike_select/behav/xsim; each set is judged from simulate.log right after it runs.
# This file is ASCII only: Vivado reads Tcl sources in the system code page, not UTF-8.

set scripts_dir [file dirname [file normalize [info script]]]
source [file join $scripts_dir .. sim_common.tcl]

set simset_name sim_fc_spike_select

# OUT_NEURONS NEURONS_PER_ROW
set param_sets {
    {10 4}
    {10 3}
    {13 5}
    {20 8}
    {5 1}
    {3 4}
    {2 8}
    {1 1}
}

proc fc_spike_select_generic {param_set} {
    lassign $param_set out_neurons neurons_per_row
    return "OUT_NEURONS=$out_neurons NEURONS_PER_ROW=$neurons_per_row"
}

# tb_fc_spike_select prints the same NAME=value list as the generic, followed by a colon
proc fc_spike_select_prefix {param_set} {
    return "[fc_spike_select_generic $param_set]:"
}

open_saltnet_project
create_simset_if_missing $simset_name tb_fc_spike_select {fc/tb_fc_spike_select.sv}

run_param_sets $simset_name tb_fc_spike_select sim_1/new/fc/ref $param_sets fc_spike_select_generic fc_spike_select_prefix
