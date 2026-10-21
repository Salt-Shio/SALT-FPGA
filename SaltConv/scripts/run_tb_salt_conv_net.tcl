# Run the tb_salt_conv_net_* testbenches (two-layer SaltConvNet, conv1 -> conv2) once per parameter set, each in its
# own simulation set (sim_salt_conv_net_ready_high, ..._random, ..._burst) of the SaltConv project.
# Each testbench covers one downstream/upstream driving pattern; the shared checks are in tb_salt_conv_net_common.svh.
# Generate the reference files first (WSL): gen_salt_conv_ref.py (writes salt_conv_net_SAT0.txt, ..._SAT1.txt).
# Parameter sets: the trained conv1 + conv2, wrap and saturate versions, pipeline R2C2 with overlap (the target
# configuration; the other pipeline configurations are covered by the single-layer run_tb_salt_conv.tcl).
# The first run also adds SaltConv.sv and SaltConvNet.sv to sources_1 and creates the simulation sets.
# One Vivado session runs one simulation set only (see run_tb_salt_conv.tcl), so:
#   one testbench name in -tclargs : run that testbench in this session
#   no -tclargs, or several names  : start one child Vivado (batch) per testbench, one after another;
#                                    each child writes SaltConv.sim/<testbench>.log
# Usage:
#   PowerShell (batch mode, close the GUI first):
#       cd D:\Project\SALT-FPGA\SaltConv\SaltConv.sim
#       vivado -mode batch -source D:/Project/SALT-FPGA/SaltConv/scripts/run_tb_salt_conv_net.tcl
#   Run only some testbenches: add -tclargs followed by their names, e.g. -tclargs tb_salt_conv_net_ready_high
# Outputs go to SaltConv.sim/<simset>/behav/xsim; each set is judged from simulate.log right after it runs.
# The testbench also writes the cycle counts of every sample to latency_SAT<0|1>.txt in that directory.
# This file is ASCII only: Vivado reads Tcl sources in the system code page, not UTF-8.

set scripts_dir [file dirname [file normalize [info script]]]
source [file join $scripts_dir sim_common.tcl]

set testbenches [list tb_salt_conv_net_ready_high tb_salt_conv_net_ready_random tb_salt_conv_net_ready_burst]
foreach arg $argv {
    if {![string match tb_salt_conv_net_* $arg]} {
        error "unknown argument '$arg': expected a testbench name (tb_salt_conv_net_*)"
    }
}
if {[llength $argv] > 0} {
    set testbenches $argv
}

if {[llength $testbenches] > 1} {
    run_testbenches_in_children [info script] $testbenches {}
    return
}

set wrap_dir sources_1/mem/best_val50_b7_fa6_fv0_round_pc_clip100_wrap_g1
set saturate_dir sources_1/mem/best_val50_b7_fa6_fv0_round_pc_clip100_saturate_iv9-11-11

# IN_CHANNELS IN_ROWS IN_COLS
# CONV1_OUT_CHANNELS CONV1_KERNEL_SIZE CONV1_STRIDE CONV1_PADDING CONV1_MEMBRANE_INT_WIDTH CONV1_DECAY_TABLE_DEPTH
# CONV1_FIFO_DEPTH, the same seven for CONV2_,
# TIME_WIDTH WEIGHT_WIDTH MEMBRANE_FRAC_WIDTH DECAY_FRAC_WIDTH ROUND SATURATE READ_LATENCY COMPUTE_LATENCY OVERLAP,
# then the data file directory (relative to SaltConv.srcs; conv1_weight.mem ... conv2_decay.mem inside).
set param_sets [list \
    [list 2 34 34  8 3 2 1 12 75 16  16 3 2 1 14 75 16  16 7 0 6 1 0 2 2 1 $wrap_dir] \
    [list 2 34 34  8 3 2 1  9 75 16  16 3 2 1 11 75 16  16 7 0 6 1 1 2 2 1 $saturate_dir] \
]

# NAME=value list of the integer parameters, shared by the generic and the summary line prefix
proc salt_conv_net_integer_params {param_set} {
    set names {IN_CHANNELS IN_ROWS IN_COLS
        CONV1_OUT_CHANNELS CONV1_KERNEL_SIZE CONV1_STRIDE CONV1_PADDING CONV1_MEMBRANE_INT_WIDTH
        CONV1_DECAY_TABLE_DEPTH CONV1_FIFO_DEPTH
        CONV2_OUT_CHANNELS CONV2_KERNEL_SIZE CONV2_STRIDE CONV2_PADDING CONV2_MEMBRANE_INT_WIDTH
        CONV2_DECAY_TABLE_DEPTH CONV2_FIFO_DEPTH
        TIME_WIDTH WEIGHT_WIDTH MEMBRANE_FRAC_WIDTH DECAY_FRAC_WIDTH ROUND SATURATE
        READ_LATENCY COMPUTE_LATENCY OVERLAP}
    set values [lrange $param_set 0 end-1]
    if {[llength $names] != [llength $values]} {
        error "parameter set has [llength $values] integers, expected [llength $names]: $param_set"
    }
    set pairs {}
    foreach name $names value $values {
        lappend pairs "$name=$value"
    }
    return [join $pairs " "]
}

proc salt_conv_net_generic {param_set} {
    set data_dir [lindex $param_set end]
    set srcs_dir [file join [get_property DIRECTORY [current_project]] [get_property NAME [current_project]].srcs]
    set generic [salt_conv_net_integer_params $param_set]
    foreach layer {CONV1 CONV2} {
        set file_prefix [string tolower $layer]
        foreach {name suffix} {WEIGHT_FILE _weight.mem THRESHOLD_FILE _threshold.mem DECAY_FILE _decay.mem} {
            set path [file join $srcs_dir $data_dir $file_prefix$suffix]
            if {![file exists $path]} {
                error "data file not found: $path"
            }
            append generic " ${layer}_$name=\"$path\""
        }
    }
    return $generic
}

# tb_salt_conv_net_* print the integer parameters as NAME=value, followed by a colon
proc salt_conv_net_prefix {param_set} {
    return "[salt_conv_net_integer_params $param_set]:"
}

open_saltconv_project $scripts_dir

# First run only: register the design sources and create the simulation set.
# Files are referenced in place (no copy into the project), same as the other testbenches.
set srcs_dir [file join [get_property DIRECTORY [current_project]] [get_property NAME [current_project]].srcs]
set tb_dir [file join $srcs_dir sim_1 new]
foreach design_file {SaltConv.sv SaltConvNet.sv} {
    if {[llength [get_files -quiet -of_objects [get_filesets sources_1] */$design_file]] == 0} {
        add_files -fileset sources_1 -norecurse [file join $srcs_dir sources_1 new $design_file]
    }
}
update_compile_order -fileset sources_1

# One testbench in this session
set tb_name [lindex $testbenches 0]
set simset_name [string map {tb_ sim_} $tb_name]
if {[llength [get_filesets -quiet $simset_name]] == 0} {
    create_fileset -simset $simset_name
    set simset [get_filesets $simset_name]
    set_property SOURCE_SET sources_1 $simset
    add_files -fileset $simset_name -norecurse [list [file join $tb_dir $tb_name.sv] \
        [file join $tb_dir tb_salt_conv_net_common.svh]]
    set_property top $tb_name $simset
    set_property top_lib xil_defaultlib $simset
    update_compile_order -fileset $simset_name
}
run_param_sets $simset_name $tb_name $param_sets salt_conv_net_generic salt_conv_net_prefix
