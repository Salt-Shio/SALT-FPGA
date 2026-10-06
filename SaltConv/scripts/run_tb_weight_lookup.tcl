# Run tb_weight_lookup once per parameter set, using simulation set sim_weight_lookup of the SaltConv project.
# Generate the reference files first (WSL): gen_weight_lookup_ref.py.
# The parameter list below must match TRAINED_LAYERS and SYNTHETIC_SETS in that script.
# Trained layers use the weight files exported by the training repo (sources_1/mem/<quant folder>/),
# each quant version once; synthetic sets use the weight files written by gen_weight_lookup_ref.py (sim_1/new/ref/).
# The first run also adds WeightMemory.sv and WeightTapSelect.sv to sources_1 and creates the simulation set;
# later runs skip that.
# Compile runs once; each parameter set changes the simset generic, then elaborates and simulates.
# Usage:
#   PowerShell (batch mode, close the GUI first):
#       cd D:\Project\SALT-FPGA\SaltConv\SaltConv.sim
#       vivado -mode batch -source D:/Project/SALT-FPGA/SaltConv/scripts/run_tb_weight_lookup.tcl
#   Do not source this from the GUI Tcl console: there the repeated elaborate steps intermittently fail with
#   'Spawn failed' (cause unknown, see the vivado-usage skill, section 8.7). Use the GUI only for a single
#   Run Simulation with the testbench defaults.
#   (Vivado writes vivado.log/.jou and crash dumps to the launch directory; start it inside SaltConv.sim.)
# Outputs go to SaltConv.sim/sim_weight_lookup/behav/xsim; each set is judged from simulate.log right after it runs.
# This file is ASCII only: Vivado reads Tcl sources in the system code page, not UTF-8.

set scripts_dir [file dirname [file normalize [info script]]]
source [file join $scripts_dir sim_common.tcl]

set simset_name sim_weight_lookup

set wrap_dir sources_1/mem/best_val50_b7_fa6_fv0_round_pc_clip100_wrap_g1
set saturate_dir sources_1/mem/best_val50_b7_fa6_fv0_round_pc_clip100_saturate_iv9-11-11

# IN_CHANNEL_WIDTH IN_CHANNELS OUT_CHANNELS KERNEL_SIZE STRIDE PADDING OUT_ROWS OUT_COLS Y_WIDTH X_WIDTH WEIGHT_WIDTH
# weight file (relative to SaltConv.srcs)
set param_sets [list \
    [list 1 2 8 3 2 1 17 17 6 6 7 $wrap_dir/conv1_weight.mem] \
    [list 1 2 8 3 2 1 17 17 6 6 7 $saturate_dir/conv1_weight.mem] \
    [list 3 8 16 3 2 1 9 9 5 5 7 $wrap_dir/conv2_weight.mem] \
    [list 3 8 16 3 2 1 9 9 5 5 7 $saturate_dir/conv2_weight.mem] \
    [list 4 3 5 3 1 1 7 5 3 3 7 sim_1/new/ref/weight_lookup_K3_S1_P1_R7_C5_IC3_OC5_Y3_X3_B7_weight.mem] \
    [list 3 5 3 5 2 2 5 4 4 3 6 sim_1/new/ref/weight_lookup_K5_S2_P2_R5_C4_IC5_OC3_Y4_X3_B6_weight.mem] \
    [list 2 3 2 4 3 0 3 3 4 4 5 sim_1/new/ref/weight_lookup_K4_S3_P0_R3_C3_IC3_OC2_Y4_X4_B5_weight.mem] \
    [list 1 2 3 7 3 3 4 3 4 4 9 sim_1/new/ref/weight_lookup_K7_S3_P3_R4_C3_IC2_OC3_Y4_X4_B9_weight.mem] \
    [list 1 1 1 1 2 0 2 2 2 2 4 sim_1/new/ref/weight_lookup_K1_S2_P0_R2_C2_IC1_OC1_Y2_X2_B4_weight.mem] \
]

# NAME=value list of the integer parameters, shared by the generic and the summary line prefix
proc weight_lookup_integer_params {param_set} {
    lassign $param_set in_channel_width in_channels out_channels kernel_size stride padding out_rows out_cols \
        y_width x_width weight_width
    return "IN_CHANNEL_WIDTH=$in_channel_width IN_CHANNELS=$in_channels OUT_CHANNELS=$out_channels KERNEL_SIZE=$kernel_size STRIDE=$stride PADDING=$padding OUT_ROWS=$out_rows OUT_COLS=$out_cols Y_WIDTH=$y_width X_WIDTH=$x_width WEIGHT_WIDTH=$weight_width"
}

proc weight_lookup_generic {param_set} {
    set weight_file [lindex $param_set end]
    set srcs_dir [file join [get_property DIRECTORY [current_project]] [get_property NAME [current_project]].srcs]
    set weight_path [file join $srcs_dir $weight_file]
    if {![file exists $weight_path]} {
        error "weight file not found: $weight_path"
    }
    return "[weight_lookup_integer_params $param_set] WEIGHT_FILE=\"$weight_path\""
}

# tb_weight_lookup prints the integer parameters as NAME=value, followed by a colon
proc weight_lookup_prefix {param_set} {
    return "[weight_lookup_integer_params $param_set]:"
}

open_saltconv_project $scripts_dir

# First run only: register the design sources and create the simulation set.
# Files are referenced in place (no copy into the project), same as the other testbenches.
set srcs_dir [file join [get_property DIRECTORY [current_project]] [get_property NAME [current_project]].srcs]
foreach source_name {WeightMemory.sv WeightTapSelect.sv} {
    if {[llength [get_files -quiet -of_objects [get_filesets sources_1] *$source_name]] == 0} {
        add_files -fileset sources_1 -norecurse [file join $srcs_dir sources_1 new $source_name]
    }
}
update_compile_order -fileset sources_1
if {[llength [get_filesets -quiet $simset_name]] == 0} {
    create_fileset -simset $simset_name
    set_property SOURCE_SET sources_1 [get_filesets $simset_name]
    add_files -fileset $simset_name -norecurse [file join $srcs_dir sim_1 new tb_weight_lookup.sv]
    set_property top tb_weight_lookup [get_filesets $simset_name]
    set_property top_lib xil_defaultlib [get_filesets $simset_name]
    update_compile_order -fileset $simset_name
}

run_param_sets $simset_name tb_weight_lookup $param_sets weight_lookup_generic weight_lookup_prefix
