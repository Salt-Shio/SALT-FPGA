# Run the four tb_salt_fc_ready_* testbenches (SaltFC with SPIKE_OUTPUT = 1) once per parameter set, each in its own
# simulation set (sim_salt_fc_ready_high, ..._random, ..._burst, ..._alternate) of the SaltNET project.
# Each testbench covers one downstream/upstream driving pattern; the shared checks are in tb_salt_fc_common.svh.
# The layer without spikes (SPIKE_OUTPUT = 0) is run by run_tb_salt_fc_no_spike.tcl.
# Generate the reference files first (WSL): gen_salt_fc_ref.py (also writes the weight, threshold and decay files).
# The parameter list below must match the SPIKE_OUTPUT = 1 entries of SYNTHETIC_SETS in that script.
# The first run creates the simulation sets (sim_common.tcl registers all RTL in sources_1); later runs skip that.
# Per testbench, compile runs once; each parameter set changes the simset generic, then elaborates and simulates.
# One Vivado session runs one simulation set only (see run_tb_salt_conv.tcl and the vivado-usage skill). So:
#   one testbench name in -tclargs : run that testbench in this session
#   no -tclargs, or several names  : start one child Vivado (batch) per testbench, one after another;
#                                    each child writes SaltNET.sim/<testbench>.log
# Usage:
#   PowerShell (batch mode, close the GUI first):
#       cd D:\Project\SALT-FPGA\SaltNET\SaltNET.sim
#       vivado -mode batch -source D:/Project/SALT-FPGA/SaltNET/scripts/fc/run_tb_salt_fc.tcl
#   Run only some testbenches: add -tclargs followed by their names, e.g. -tclargs tb_salt_fc_ready_high
#   Run only some parameter sets: add NAME:value conditions to -tclargs (NAME is a testbench parameter as printed
#   in the summary line); a set runs only if it meets every condition, e.g. -tclargs SHARED_THRESHOLD:1 READ_LATENCY:2
#   Conditions and testbench names can be mixed. ':' instead of '=': the arguments pass through vivado.bat to the
#   child Vivado, and .bat files split arguments at '='.
#   Do not source this from the GUI Tcl console: there the repeated elaborate steps intermittently fail with
#   'Spawn failed' (cause unknown, see the vivado-usage skill, section 8.7). Use the GUI only for a single
#   Run Simulation with the testbench defaults.
#   (Vivado writes vivado.log/.jou and crash dumps to the launch directory; start it inside SaltNET.sim.)
# Outputs go to SaltNET.sim/<simset>/behav/xsim; each set is judged from simulate.log right after it runs.
# All testbenches run even if one fails; the script raises an error at the end if any failed.
# This file is ASCII only: Vivado reads Tcl sources in the system code page, not UTF-8.

set scripts_dir [file dirname [file normalize [info script]]]
source [file join $scripts_dir .. sim_common.tcl]

set testbenches [list tb_salt_fc_ready_high tb_salt_fc_ready_random tb_salt_fc_ready_burst \
    tb_salt_fc_ready_alternate]
# -tclargs: testbench names (tb_*) and NAME:value parameter set conditions
set requested_testbenches {}
set set_conditions {}
foreach arg $argv {
    if {[string match tb_* $arg]} {
        lappend requested_testbenches $arg
    } elseif {[regexp {^[A-Z_]+:[^:=\s]+$} $arg]} {
        lappend set_conditions $arg
    } else {
        error "unknown argument '$arg': expected a testbench name (tb_*) or a NAME:value condition"
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

set ref_dir sim_1/new/fc/ref

# IN_NEURONS OUT_NEURONS NEURONS_PER_ROW TIME_WIDTH WEIGHT_WIDTH MEMBRANE_INT_WIDTH MEMBRANE_FRAC_WIDTH
# DECAY_FRAC_WIDTH DECAY_TABLE_DEPTH ROUND SATURATE SHARED_THRESHOLD FIFO_DEPTH.
# READ_LATENCY, COMPUTE_LATENCY, OVERLAP are added below.
set base_param_sets {
    {7 10 3 11 5 6 0 4 10 1 0 0 4}
    {7 10 4 12 6 7 2 5 20 0 1 1 16}
    {5 3 4 10 4 5 0 3 4 1 1 0 2}
    {5 3 4 10 4 5 0 3 4 1 1 1 16}
    {7 5 1 12 7 8 0 6 12 0 0 1 16}
    {9 16 8 12 6 8 0 5 16 1 0 0 8}
    {1 1 1 9 4 4 0 3 3 1 1 0 4}
}

# Each set above runs once per {READ_LATENCY COMPUTE_LATENCY OVERLAP} below. They only change the cycle count;
# the reference files list the cycle count for every entry of CYCLE_CONFIGS in gen_salt_conv_ref.py (R, C in 1..2).
# OVERLAP only matters when R + C > 2, so {1 1 1} is not listed.
set pipeline_configs {{1 1 0} {2 1 0} {2 1 1} {1 2 0} {1 2 1} {2 2 0} {2 2 1}}
set param_sets {}
foreach base_set $base_param_sets {
    foreach pipeline_config $pipeline_configs {
        lappend param_sets [concat $base_set $pipeline_config]
    }
}

# NAME=value list of the integer parameters, shared by the generic and the summary line prefix
proc salt_fc_integer_params {param_set} {
    lassign $param_set in_neurons out_neurons neurons_per_row time_width weight_width membrane_int_width \
        membrane_frac_width decay_frac_width decay_table_depth round saturate shared_threshold fifo_depth \
        read_latency compute_latency overlap
    return "IN_NEURONS=$in_neurons OUT_NEURONS=$out_neurons NEURONS_PER_ROW=$neurons_per_row TIME_WIDTH=$time_width WEIGHT_WIDTH=$weight_width MEMBRANE_INT_WIDTH=$membrane_int_width MEMBRANE_FRAC_WIDTH=$membrane_frac_width DECAY_FRAC_WIDTH=$decay_frac_width DECAY_TABLE_DEPTH=$decay_table_depth ROUND=$round SATURATE=$saturate SHARED_THRESHOLD=$shared_threshold FIFO_DEPTH=$fifo_depth READ_LATENCY=$read_latency COMPUTE_LATENCY=$compute_latency OVERLAP=$overlap"
}

# Data file name rule: same as ParamSet.stem in gen_salt_fc_ref.py (SPIKE_OUTPUT = 1)
proc salt_fc_generic {param_set} {
    lassign $param_set in_neurons out_neurons neurons_per_row time_width weight_width membrane_int_width \
        membrane_frac_width decay_frac_width decay_table_depth round saturate shared_threshold
    set stem salt_fc_IN${in_neurons}_OUT${out_neurons}_COL${neurons_per_row}_IV${membrane_int_width}_FV${membrane_frac_width}_RD${round}_SAT${saturate}_SPK1_SH${shared_threshold}
    set generic [salt_fc_integer_params $param_set]
    foreach {name suffix} {WEIGHT_FILE _weight.mem THRESHOLD_FILE _threshold.mem DECAY_FILE _decay.mem} {
        set path [file join [project_srcs_dir] $::ref_dir $stem$suffix]
        if {![file exists $path]} {
            error "data file not found: $path"
        }
        append generic " $name=\"$path\""
    }
    return $generic
}

# tb_salt_fc_ready_* print the integer parameters as NAME=value, followed by a colon
proc salt_fc_prefix {param_set} {
    return "[salt_fc_integer_params $param_set]:"
}

# Keep only the sets that meet every NAME:value condition from -tclargs
if {[llength $set_conditions] > 0} {
    set selected_sets {}
    foreach param_set $param_sets {
        set integer_params [salt_fc_integer_params $param_set]
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

# One testbench in this session
set tb_name [lindex $testbenches 0]
set simset_name [string map {tb_ sim_} $tb_name]
create_simset_if_missing $simset_name $tb_name [list fc/$tb_name.sv fc/tb_salt_fc_common.svh]
run_param_sets $simset_name $tb_name $ref_dir $param_sets salt_fc_generic salt_fc_prefix
