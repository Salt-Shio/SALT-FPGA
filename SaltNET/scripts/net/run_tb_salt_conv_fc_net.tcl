# Run the tb_salt_conv_fc_net_* testbenches (the whole network SaltConvFCNet: conv1 -> conv2 -> ConvToFCAdapter ->
# SaltFC -> FCMembraneRegister) once per parameter set, each in its own simulation set
# (sim_salt_conv_fc_net_input_high, sim_salt_conv_fc_net_input_random, sim_salt_conv_fc_net_stale_clear) of the
# SaltNET project. Each testbench covers one situation; the shared checks are in tb_salt_conv_fc_net_common.svh.
# Generate the reference files first (WSL), then run; reference files are not version controlled:
#   input_high, input_random : scripts/net/gen_salt_conv_fc_net_ref.py writes salt_conv_fc_net_SAT0.txt and _SAT1.txt
#                              (about 35 MB each) and the FC data files
#   stale_clear              : scripts/net/gen_salt_conv_fc_net_stale_clear_ref.py writes
#                              salt_conv_fc_net_stale_clear_SAT0.txt and _SAT1.txt (about 60 MB each); it uses the
#                              FC n_col = 4 data files written by gen_salt_conv_fc_net_ref.py
# Parameter sets: the trained conv1 + conv2 + out layer, wrap and saturate versions, pipeline R2C2 with overlap.
#   input_high, input_random : FC n_col = 4 and FIFO depth 16 (the target configuration), and FC n_col = 1 and FIFO
#                              depth 2 (the FC needs 10 cycles per event, so its FIFO fills up and back-pressure
#                              reaches the adapter, conv2 and conv1); no scan (STALE_CLEAR = 0), 16-bit time
#   stale_clear              : FC n_col = 4, FIFO depth 16, scan on (STALE_CLEAR = 1, one cell per tick) and 11-bit
#                              time, so the time stamps wrap every 2048 ms within one long input stream
# The first run creates the simulation sets (sim_common.tcl registers all RTL in sources_1); later runs skip that.
# One Vivado session runs one simulation set only (see run_tb_salt_conv.tcl), so:
#   one testbench name in -tclargs : run that testbench in this session
#   no testbench name, or several  : start one child Vivado (batch) per testbench, one after another;
#                                    each child writes SaltNET.sim/<testbench>.log
#   NAME:value in -tclargs         : run only the parameter sets with that parameter value (e.g. FC_NEURONS_PER_ROW:1)
# Usage:
#   PowerShell (batch mode, close the GUI first):
#       cd D:\Project\SALT-FPGA\SaltNET\SaltNET.sim
#       vivado -mode batch -source D:/Project/SALT-FPGA/SaltNET/scripts/net/run_tb_salt_conv_fc_net.tcl
#   Run only some testbenches: add -tclargs followed by their names, e.g. -tclargs tb_salt_conv_fc_net_input_high
# Outputs go to SaltNET.sim/<simset>/behav/xsim; each set is judged from simulate.log right after it runs.
# This file is ASCII only: Vivado reads Tcl sources in the system code page, not UTF-8.

set scripts_dir [file dirname [file normalize [info script]]]
source [file join $scripts_dir .. sim_common.tcl]

set testbenches [list tb_salt_conv_fc_net_input_high tb_salt_conv_fc_net_input_random tb_salt_conv_fc_net_stale_clear]
set requested_testbenches {}
set set_conditions {}
foreach arg $argv {
    if {[string match tb_salt_conv_fc_net_* $arg]} {
        lappend requested_testbenches $arg
    } elseif {[regexp {^[A-Z0-9_]+:[^:=\s]+$} $arg]} {
        lappend set_conditions $arg
    } else {
        error "unknown argument '$arg': expected a testbench name (tb_salt_conv_fc_net_*) or a NAME:value condition"
    }
}
if {[llength $requested_testbenches] > 0} {
    set testbenches $requested_testbenches
}

# Several testbenches: one child Vivado per testbench, then report from their logs
if {[llength $testbenches] > 1} {
    run_testbenches_in_children [info script] $testbenches $set_conditions
    return
}

set ref_dir sim_1/new/net/ref
set wrap_dir [quant_mem_dir wrap]
set saturate_dir [quant_mem_dir saturate]

# IN_CHANNELS IN_ROWS IN_COLS
# CONV1_OUT_CHANNELS CONV1_KERNEL_SIZE CONV1_STRIDE CONV1_PADDING CONV1_MEMBRANE_INT_WIDTH CONV1_DECAY_TABLE_DEPTH
# CONV1_FIFO_DEPTH, the same seven for CONV2_,
# FC_OUT_NEURONS FC_NEURONS_PER_ROW FC_MEMBRANE_INT_WIDTH FC_DECAY_TABLE_DEPTH FC_FIFO_DEPTH,
# TIME_WIDTH WEIGHT_WIDTH MEMBRANE_FRAC_WIDTH DECAY_FRAC_WIDTH ROUND SATURATE READ_LATENCY COMPUTE_LATENCY OVERLAP,
# STALE_CLEAR SCAN_CELLS_PER_TICK,
# then the conv data file directory (relative to SaltNET.srcs; conv1_weight.mem ... conv2_decay.mem inside).
# Each testbench runs its own sets and reads its own reference files (testbench_sets: reference file stem, sets).
set reset_per_sample_sets [list \
    [list 2 34 34  8 3 2 1 12 75 16  16 3 2 1 14 75 16  10 4 14 75 16  16 7 0 6 1 0 2 2 1  0 1 $wrap_dir] \
    [list 2 34 34  8 3 2 1  9 75 16  16 3 2 1 11 75 16  10 4 11 75 16  16 7 0 6 1 1 2 2 1  0 1 $saturate_dir] \
    [list 2 34 34  8 3 2 1 12 75 16  16 3 2 1 14 75 16  10 1 14 75  2  16 7 0 6 1 0 2 2 1  0 1 $wrap_dir] \
    [list 2 34 34  8 3 2 1  9 75 16  16 3 2 1 11 75 16  10 1 11 75  2  16 7 0 6 1 1 2 2 1  0 1 $saturate_dir] \
]
set stale_clear_sets [list \
    [list 2 34 34  8 3 2 1 12 75 16  16 3 2 1 14 75 16  10 4 14 75 16  11 7 0 6 1 0 2 2 1  1 1 $wrap_dir] \
    [list 2 34 34  8 3 2 1  9 75 16  16 3 2 1 11 75 16  10 4 11 75 16  11 7 0 6 1 1 2 2 1  1 1 $saturate_dir] \
]
set testbench_sets [dict create \
    tb_salt_conv_fc_net_input_high   [list salt_conv_fc_net $reset_per_sample_sets] \
    tb_salt_conv_fc_net_input_random [list salt_conv_fc_net $reset_per_sample_sets] \
    tb_salt_conv_fc_net_stale_clear  [list salt_conv_fc_net_stale_clear $stale_clear_sets] \
]

set integer_param_names {IN_CHANNELS IN_ROWS IN_COLS
    CONV1_OUT_CHANNELS CONV1_KERNEL_SIZE CONV1_STRIDE CONV1_PADDING CONV1_MEMBRANE_INT_WIDTH
    CONV1_DECAY_TABLE_DEPTH CONV1_FIFO_DEPTH
    CONV2_OUT_CHANNELS CONV2_KERNEL_SIZE CONV2_STRIDE CONV2_PADDING CONV2_MEMBRANE_INT_WIDTH
    CONV2_DECAY_TABLE_DEPTH CONV2_FIFO_DEPTH
    FC_OUT_NEURONS FC_NEURONS_PER_ROW FC_MEMBRANE_INT_WIDTH FC_DECAY_TABLE_DEPTH FC_FIFO_DEPTH
    TIME_WIDTH WEIGHT_WIDTH MEMBRANE_FRAC_WIDTH DECAY_FRAC_WIDTH ROUND SATURATE
    READ_LATENCY COMPUTE_LATENCY OVERLAP STALE_CLEAR SCAN_CELLS_PER_TICK}

# NAME value dict of the integer parameters of one set
proc salt_conv_fc_net_values {param_set} {
    set values [lrange $param_set 0 end-1]
    if {[llength $::integer_param_names] != [llength $values]} {
        error "parameter set has [llength $values] integers, expected [llength $::integer_param_names]: $param_set"
    }
    set value_dict [dict create]
    foreach name $::integer_param_names value $values {
        dict set value_dict $name $value
    }
    return $value_dict
}

# NAME=value list of the integer parameters, shared by the generic and the summary line prefix
proc salt_conv_fc_net_integer_params {param_set} {
    set pairs {}
    dict for {name value} [salt_conv_fc_net_values $param_set] {
        lappend pairs "$name=$value"
    }
    return [join $pairs " "]
}

# Output size of a conv layer: (H_in + 2P - K) / S + 1, same as SaltConvFCNet
proc conv_out_size {in_size kernel_size stride padding} {
    return [expr {($in_size + 2 * $padding - $kernel_size) / $stride + 1}]
}

proc salt_conv_fc_net_generic {param_set} {
    set v [salt_conv_fc_net_values $param_set]
    set srcs_dir [project_srcs_dir]
    set generic [salt_conv_fc_net_integer_params $param_set]

    # The reference file is not version controlled: stop with a hint instead of letting xsim fail to open it
    set ref_path [file join $srcs_dir $::ref_dir ${::reference_name}_SAT[dict get $v SATURATE].txt]
    if {![file exists $ref_path]} {
        error "reference file not found: $ref_path (generate it with scripts/net/gen_${::reference_name}_ref.py)"
    }

    set conv_dir [lindex $param_set end]
    foreach layer {CONV1 CONV2} {
        set file_prefix [string tolower $layer]
        foreach {name suffix} {WEIGHT_FILE _weight.mem THRESHOLD_FILE _threshold.mem DECAY_FILE _decay.mem} {
            set path [file join $srcs_dir $conv_dir $file_prefix$suffix]
            if {![file exists $path]} {
                error "data file not found: $path"
            }
            append generic " ${layer}_$name=\"$path\""
        }
    }

    # FC data files: same name rule as ParamSet.stem in gen_salt_fc_ref.py (the output layer does not fire, SPK0)
    set conv1_rows [conv_out_size [dict get $v IN_ROWS] [dict get $v CONV1_KERNEL_SIZE] [dict get $v CONV1_STRIDE] [dict get $v CONV1_PADDING]]
    set conv1_cols [conv_out_size [dict get $v IN_COLS] [dict get $v CONV1_KERNEL_SIZE] [dict get $v CONV1_STRIDE] [dict get $v CONV1_PADDING]]
    set conv2_rows [conv_out_size $conv1_rows [dict get $v CONV2_KERNEL_SIZE] [dict get $v CONV2_STRIDE] [dict get $v CONV2_PADDING]]
    set conv2_cols [conv_out_size $conv1_cols [dict get $v CONV2_KERNEL_SIZE] [dict get $v CONV2_STRIDE] [dict get $v CONV2_PADDING]]
    set fc_in_neurons [expr {[dict get $v CONV2_OUT_CHANNELS] * $conv2_rows * $conv2_cols}]
    set stem salt_fc_IN${fc_in_neurons}_OUT[dict get $v FC_OUT_NEURONS]_COL[dict get $v FC_NEURONS_PER_ROW]_IV[dict get $v FC_MEMBRANE_INT_WIDTH]_FV[dict get $v MEMBRANE_FRAC_WIDTH]_RD[dict get $v ROUND]_SAT[dict get $v SATURATE]_SPK0
    foreach {name suffix} {FC_WEIGHT_FILE _weight.mem FC_DECAY_FILE _decay.mem} {
        set path [file join $srcs_dir $::ref_dir $stem$suffix]
        if {![file exists $path]} {
            error "data file not found: $path"
        }
        append generic " $name=\"$path\""
    }
    return $generic
}

# tb_salt_conv_fc_net_* print the integer parameters as NAME=value, followed by a colon
proc salt_conv_fc_net_prefix {param_set} {
    return "[salt_conv_fc_net_integer_params $param_set]:"
}

# One testbench in this session: its reference file stem and parameter sets
set tb_name [lindex $testbenches 0]
if {![dict exists $testbench_sets $tb_name]} {
    error "unknown testbench '$tb_name': expected one of [dict keys $testbench_sets]"
}
lassign [dict get $testbench_sets $tb_name] reference_name param_sets

# Keep only the sets that meet every NAME:value condition from -tclargs
if {[llength $set_conditions] > 0} {
    set selected_sets {}
    foreach param_set $param_sets {
        set integer_params [salt_conv_fc_net_integer_params $param_set]
        set selected 1
        foreach condition $set_conditions {
            if {[lsearch -exact $integer_params [string map {: =} $condition]] < 0} {
                set selected 0
                break
            }
        }
        if {$selected} {
            lappend selected_sets $param_set
        }
    }
    if {[llength $selected_sets] == 0} {
        error "no parameter set meets the conditions: $set_conditions"
    }
    set param_sets $selected_sets
}

open_saltnet_project

set simset_name [string map {tb_ sim_} $tb_name]
create_simset_if_missing $simset_name $tb_name [list net/$tb_name.sv net/tb_salt_conv_fc_net_common.svh]
run_param_sets $simset_name $tb_name $ref_dir $param_sets salt_conv_fc_net_generic salt_conv_fc_net_prefix
