# Run tb_spike_select once per parameter set, using simulation set sim_spike_select of the SaltNET project.
# Generate the reference files first (WSL): gen_spike_select_ref.py.
# The parameter list below must match PARAM_SETS in that script.
# The first run creates the simulation set (sim_common.tcl registers all RTL in sources_1); later runs skip that.
# Compile runs once; each parameter set changes the simset generic, then elaborates and simulates.
# Usage:
#   PowerShell (batch mode, close the GUI first):
#       cd D:\Project\SALT-FPGA\SaltNET\SaltNET.sim
#       vivado -mode batch -source D:/Project/SALT-FPGA/SaltNET/scripts/conv/run_tb_spike_select.tcl
#   Do not source this from the GUI Tcl console: there the repeated elaborate steps intermittently fail with
#   'Spawn failed' (cause unknown, see the vivado-usage skill, section 8.7). Use the GUI only for a single
#   Run Simulation with the testbench defaults.
#   (Vivado writes vivado.log/.jou and crash dumps to the launch directory; start it inside SaltNET.sim.)
# Outputs go to SaltNET.sim/sim_spike_select/behav/xsim; each set is judged from simulate.log right after it runs.
# This file is ASCII only: Vivado reads Tcl sources in the system code page, not UTF-8.

set scripts_dir [file dirname [file normalize [info script]]]
source [file join $scripts_dir .. sim_common.tcl]

set simset_name sim_spike_select

# KERNEL_SIZE STRIDE PADDING OUT_ROWS OUT_COLS Y_WIDTH X_WIDTH
set param_sets {
    {3 2 1 17 17 6 6}
    {3 2 1 9 9 5 5}
    {3 1 1 13 11 4 4}
    {3 1 1 64 64 7 7}
    {4 1 0 7 5 4 3}
    {5 2 2 10 7 5 4}
    {1 2 0 4 3 3 3}
    {3 1 1 1 1 2 2}
}

proc spike_select_generic {param_set} {
    lassign $param_set kernel_size stride padding out_rows out_cols y_width x_width
    return "KERNEL_SIZE=$kernel_size STRIDE=$stride PADDING=$padding OUT_ROWS=$out_rows OUT_COLS=$out_cols Y_WIDTH=$y_width X_WIDTH=$x_width"
}

# tb_spike_select prints the same NAME=value list as the generic, followed by a colon
proc spike_select_prefix {param_set} {
    return "[spike_select_generic $param_set]:"
}

open_saltnet_project
create_simset_if_missing $simset_name tb_spike_select {conv/tb_spike_select.sv}

run_param_sets $simset_name tb_spike_select sim_1/new/conv/ref $param_sets spike_select_generic spike_select_prefix
