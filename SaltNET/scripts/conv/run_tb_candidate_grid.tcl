# Run tb_candidate_grid once per parameter set, using simulation set sim_candidate_grid of the SaltNET project.
# Generate the reference files first (WSL): gen_candidate_grid_ref.py.
# The parameter list below must match PARAM_SETS in that script.
# The first run creates the simulation set (sim_common.tcl registers all RTL in sources_1); later runs skip that.
# Compile runs once; each parameter set changes the simset generic, then elaborates and simulates.
# Usage:
#   PowerShell (batch mode, close the GUI first):
#       cd D:\Project\SALT-FPGA\SaltNET\SaltNET.sim
#       vivado -mode batch -source D:/Project/SALT-FPGA/SaltNET/scripts/conv/run_tb_candidate_grid.tcl
#   Do not source this from the GUI Tcl console: there the repeated elaborate steps intermittently fail with
#   'Spawn failed' (cause unknown, see the vivado-usage skill, section 8.7). Use the GUI only for a single
#   Run Simulation with the testbench defaults.
#   (Vivado writes vivado.log/.jou and crash dumps to the launch directory; start it inside SaltNET.sim.)
# Outputs go to SaltNET.sim/sim_candidate_grid/behav/xsim; each set is judged from simulate.log right after it runs.
# This file is ASCII only: Vivado reads Tcl sources in the system code page, not UTF-8.

set scripts_dir [file dirname [file normalize [info script]]]
source [file join $scripts_dir .. sim_common.tcl]

set simset_name sim_candidate_grid

# KERNEL_SIZE STRIDE PADDING OUT_ROWS OUT_COLS OUT_CHANNELS Y_WIDTH X_WIDTH
set param_sets {
    {3 2 1 17 17 8 6 6}
    {3 2 1 9 9 16 5 5}
    {3 1 1 13 11 5 4 4}
    {4 1 0 7 5 3 4 3}
    {5 2 2 10 7 3 5 4}
    {1 2 0 4 3 2 3 3}
    {3 1 1 1 1 1 2 2}
}

proc candidate_grid_generic {param_set} {
    lassign $param_set kernel_size stride padding out_rows out_cols out_channels y_width x_width
    return "KERNEL_SIZE=$kernel_size STRIDE=$stride PADDING=$padding OUT_ROWS=$out_rows OUT_COLS=$out_cols OUT_CHANNELS=$out_channels Y_WIDTH=$y_width X_WIDTH=$x_width"
}

# tb_candidate_grid prints the same NAME=value list as the generic, followed by a colon
proc candidate_grid_prefix {param_set} {
    return "[candidate_grid_generic $param_set]:"
}

open_saltnet_project
create_simset_if_missing $simset_name tb_candidate_grid {conv/tb_candidate_grid.sv}

run_param_sets $simset_name tb_candidate_grid sim_1/new/conv/ref $param_sets candidate_grid_generic candidate_grid_prefix
