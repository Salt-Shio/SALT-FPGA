# Run tb_salt_conv once per parameter set, using simulation set sim_salt_conv of the SaltConv project.
# Generate the reference files first (WSL): gen_salt_conv_ref.py.
# The parameter list below must match TRAINED_SETS and SYNTHETIC_SETS in that script.
# The first run also adds SaltConv.sv to sources_1 and creates the simulation set; later runs skip that.
# Compile runs once; each parameter set changes the simset generic, then elaborates and simulates.
# Usage:
#   PowerShell (batch mode, close the GUI first):
#       cd D:\Project\SALT-FPGA\SaltConv\SaltConv.sim
#       vivado -mode batch -source D:/Project/SALT-FPGA/SaltConv/scripts/run_tb_salt_conv.tcl
#   Do not source this from the GUI Tcl console: there the repeated elaborate steps intermittently fail with
#   'Spawn failed' (cause unknown, see the vivado-usage skill, section 8.7). Use the GUI only for a single
#   Run Simulation with the testbench defaults.
#   (Vivado writes vivado.log/.jou and crash dumps to the launch directory; start it inside SaltConv.sim.)
# Outputs go to SaltConv.sim/sim_salt_conv/behav/xsim; each set is judged from simulate.log right after it runs.
# This file is ASCII only: Vivado reads Tcl sources in the system code page, not UTF-8.

set scripts_dir [file dirname [file normalize [info script]]]
source [file join $scripts_dir sim_common.tcl]

set simset_name sim_salt_conv

set wrap_dir sources_1/mem/best_val50_b7_fa6_fv0_round_pc_clip100_wrap_g1
set saturate_dir sources_1/mem/best_val50_b7_fa6_fv0_round_pc_clip100_saturate_iv9-11-11
set ref_dir sim_1/new/ref

# X_WIDTH Y_WIDTH IN_CHANNEL_WIDTH IN_CHANNELS OUT_CHANNELS OUT_ROWS OUT_COLS KERNEL_SIZE STRIDE PADDING
# TIME_WIDTH WEIGHT_WIDTH MEMBRANE_INT_WIDTH MEMBRANE_FRAC_WIDTH DECAY_FRAC_WIDTH DECAY_TABLE_DEPTH ROUND SATURATE
# FIFO_DEPTH, then the data file prefix (relative to SaltConv.srcs; _weight.mem, _threshold.mem, _decay.mem follow)
set param_sets [list \
    [list 6 6 1 2 8 17 17 3 2 1 16 7 12 0 6 75 1 0 16 $wrap_dir/conv1] \
    [list 6 6 1 2 8 17 17 3 2 1 16 7 9 0 6 75 1 1 16 $saturate_dir/conv1] \
    [list 5 5 3 8 16 9 9 3 2 1 16 7 14 0 6 75 1 0 16 $wrap_dir/conv2] \
    [list 5 5 3 8 16 9 9 3 2 1 16 7 11 0 6 75 1 1 16 $saturate_dir/conv2] \
    [list 3 3 1 2 3 4 3 1 2 0 9 4 5 0 3 4 0 1 16 $ref_dir/salt_conv_K1_S2_P0_R4_C3_IC2_OC3_IV5_FV0_RD0_SAT1] \
    [list 4 4 2 3 5 13 11 3 1 1 11 5 7 0 4 10 1 0 4 $ref_dir/salt_conv_K3_S1_P1_R13_C11_IC3_OC5_IV7_FV0_RD1_SAT0] \
    [list 4 5 1 2 3 10 7 5 2 2 12 6 6 2 5 20 0 0 16 $ref_dir/salt_conv_K5_S2_P2_R10_C7_IC2_OC3_IV6_FV2_RD0_SAT0] \
    [list 3 4 1 1 4 7 5 4 1 0 10 4 6 0 4 8 1 1 2 $ref_dir/salt_conv_K4_S1_P0_R7_C5_IC1_OC4_IV6_FV0_RD1_SAT1] \
    [list 1 1 1 2 1 1 1 3 1 1 8 4 5 0 3 3 1 1 16 $ref_dir/salt_conv_K3_S1_P1_R1_C1_IC2_OC1_IV5_FV0_RD1_SAT1] \
]

# NAME=value list of the integer parameters, shared by the generic and the summary line prefix
proc salt_conv_integer_params {param_set} {
    lassign $param_set x_width y_width in_channel_width in_channels out_channels out_rows out_cols \
        kernel_size stride padding time_width weight_width membrane_int_width membrane_frac_width \
        decay_frac_width decay_table_depth round saturate fifo_depth
    return "X_WIDTH=$x_width Y_WIDTH=$y_width IN_CHANNEL_WIDTH=$in_channel_width IN_CHANNELS=$in_channels OUT_CHANNELS=$out_channels OUT_ROWS=$out_rows OUT_COLS=$out_cols KERNEL_SIZE=$kernel_size STRIDE=$stride PADDING=$padding TIME_WIDTH=$time_width WEIGHT_WIDTH=$weight_width MEMBRANE_INT_WIDTH=$membrane_int_width MEMBRANE_FRAC_WIDTH=$membrane_frac_width DECAY_FRAC_WIDTH=$decay_frac_width DECAY_TABLE_DEPTH=$decay_table_depth ROUND=$round SATURATE=$saturate FIFO_DEPTH=$fifo_depth"
}

proc salt_conv_generic {param_set} {
    set file_prefix [lindex $param_set end]
    set srcs_dir [file join [get_property DIRECTORY [current_project]] [get_property NAME [current_project]].srcs]
    set generic [salt_conv_integer_params $param_set]
    foreach {name suffix} {WEIGHT_FILE _weight.mem THRESHOLD_FILE _threshold.mem DECAY_FILE _decay.mem} {
        set path [file join $srcs_dir $file_prefix$suffix]
        if {![file exists $path]} {
            error "data file not found: $path"
        }
        append generic " $name=\"$path\""
    }
    return $generic
}

# tb_salt_conv prints the integer parameters as NAME=value, followed by a colon
proc salt_conv_prefix {param_set} {
    return "[salt_conv_integer_params $param_set]:"
}

open_saltconv_project $scripts_dir

# First run only: register the design source and create the simulation set.
# Files are referenced in place (no copy into the project), same as the other testbenches.
set srcs_dir [file join [get_property DIRECTORY [current_project]] [get_property NAME [current_project]].srcs]
if {[llength [get_files -quiet -of_objects [get_filesets sources_1] */SaltConv.sv]] == 0} {
    add_files -fileset sources_1 -norecurse [file join $srcs_dir sources_1 new SaltConv.sv]
}
update_compile_order -fileset sources_1
if {[llength [get_filesets -quiet $simset_name]] == 0} {
    create_fileset -simset $simset_name
    set_property SOURCE_SET sources_1 [get_filesets $simset_name]
    add_files -fileset $simset_name -norecurse [file join $srcs_dir sim_1 new tb_salt_conv.sv]
    set_property top tb_salt_conv [get_filesets $simset_name]
    set_property top_lib xil_defaultlib [get_filesets $simset_name]
    update_compile_order -fileset $simset_name
}

run_param_sets $simset_name tb_salt_conv $param_sets salt_conv_generic salt_conv_prefix
