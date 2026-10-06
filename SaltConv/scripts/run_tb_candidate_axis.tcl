# Run tb_candidate_axis once per parameter set, using simulation set sim_candidate_axis of the SaltConv project.
# Generate the reference files first (WSL): gen_candidate_axis_ref.py.
# The parameter list below must match PARAM_SETS in that script.
# Compile runs once; each parameter set changes the simset generic, then elaborates and simulates.
# Usage:
#   PowerShell (batch mode, close the GUI first):
#       cd D:\Project\SALT-FPGA\SaltConv\SaltConv.sim
#       vivado -mode batch -source D:/Project/SALT-FPGA/SaltConv/scripts/run_tb_candidate_axis.tcl
#   Do not source this from the GUI Tcl console: there the repeated elaborate steps intermittently fail with
#   'Spawn failed' (cause unknown, see the vivado-usage skill, section 8.7). Use the GUI only for a single
#   Run Simulation with the testbench defaults.
#   (Vivado writes vivado.log/.jou and crash dumps to the launch directory; start it inside SaltConv.sim.)
# Outputs go to SaltConv.sim/sim_candidate_axis/behav/xsim; each set is judged from simulate.log right after it runs.
# This file is ASCII only: Vivado reads Tcl sources in the system code page, not UTF-8.

set scripts_dir [file dirname [file normalize [info script]]]
source [file join $scripts_dir sim_common.tcl]

# KERNEL_SIZE STRIDE PADDING OUT_SIZE IN_COORD_WIDTH
set param_sets {
    {3 1 1 64 9}
    {3 2 1 32 6}
    {5 2 2 20 6}
    {4 1 0 7 4}
    {7 3 3 15 5}
    {1 2 0 16 5}
    {2 3 0 10 5}
    {3 1 1 1 3}
}

proc candidate_axis_generic {param_set} {
    lassign $param_set kernel_size stride padding out_size in_coord_width
    return "KERNEL_SIZE=$kernel_size STRIDE=$stride PADDING=$padding OUT_SIZE=$out_size IN_COORD_WIDTH=$in_coord_width"
}

# Must match the summary line printed by tb_candidate_axis
proc candidate_axis_prefix {param_set} {
    lassign $param_set kernel_size stride padding out_size in_coord_width
    return "K=$kernel_size S=$stride P=$padding OUT_SIZE=$out_size IN_COORD_WIDTH=$in_coord_width:"
}

open_saltconv_project $scripts_dir
run_param_sets sim_candidate_axis tb_candidate_axis $param_sets candidate_axis_generic candidate_axis_prefix
