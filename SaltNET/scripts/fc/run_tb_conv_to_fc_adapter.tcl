# Run the two tb_conv_to_fc_adapter_* testbenches (ConvToFCAdapter alone; upstream and downstream are the testbench)
# once per parameter set, each in its own simulation set (sim_conv_to_fc_adapter_ready_high,
# sim_conv_to_fc_adapter_ready_random) of the SaltNET project. Each testbench covers one way of driving valid/ready;
# the shared checks are in tb_conv_to_fc_adapter_common.svh.
# Generate the reference files first (WSL) with gen_conv_to_fc_adapter_ref.py; the list below matches PARAM_SETS there.
# The first run creates the simulation sets (sim_common.tcl registers all RTL in sources_1); later runs skip that.
# Per testbench, compile runs once; each parameter set changes the simset generic, then elaborates and simulates.
# One Vivado session runs one simulation set only (see run_tb_salt_conv.tcl and the vivado-usage skill). So:
#   one testbench name in -tclargs : run that testbench in this session
#   no -tclargs, or several names  : start one child Vivado (batch) per testbench, one after another;
#                                    each child writes SaltNET.sim/<testbench>.log
# Usage:
#   PowerShell (batch mode, close the GUI first):
#       cd D:\Project\SALT-FPGA\SaltNET\SaltNET.sim
#       vivado -mode batch -source D:/Project/SALT-FPGA/SaltNET/scripts/fc/run_tb_conv_to_fc_adapter.tcl
#   Run only one testbench: add -tclargs followed by its name, e.g. -tclargs tb_conv_to_fc_adapter_ready_random
#   Do not source this from the GUI Tcl console: there the repeated elaborate steps intermittently fail with
#   'Spawn failed' (cause unknown, see the vivado-usage skill, section 8.7). Use the GUI only for a single
#   Run Simulation with the testbench defaults.
#   (Vivado writes vivado.log/.jou and crash dumps to the launch directory; start it inside SaltNET.sim.)
# Outputs go to SaltNET.sim/<simset>/behav/xsim; each set is judged from simulate.log right after it runs.
# All testbenches run even if one fails; the script raises an error at the end if any failed.
# This file is ASCII only: Vivado reads Tcl sources in the system code page, not UTF-8.

set scripts_dir [file dirname [file normalize [info script]]]
source [file join $scripts_dir .. sim_common.tcl]

set testbenches [list tb_conv_to_fc_adapter_ready_high tb_conv_to_fc_adapter_ready_random]
foreach arg $argv {
    if {![string match tb_* $arg]} {
        error "unknown argument '$arg': expected a testbench name (tb_*)"
    }
}
if {[llength $argv] > 0} {
    set testbenches $argv
}

# Several testbenches: one child Vivado per testbench, then report from their logs
if {[llength $testbenches] > 1} {
    run_testbenches_in_children [info script] $testbenches {}
    return
}

set ref_dir sim_1/new/fc/ref

# IN_CHANNELS, IN_ROWS, IN_COLS, TIME_WIDTH
set param_sets {
    {16 9 9 16}
    {3 5 7 16}
    {4 4 8 16}
    {1 9 9 16}
    {5 1 6 16}
    {6 5 1 16}
    {1 1 1 16}
}

# Reference file stem, same rule as ref_file_stem in gen_conv_to_fc_adapter_ref.py
proc adapter_stem {param_set} {
    lassign $param_set in_channels in_rows in_cols time_width
    return conv_to_fc_adapter_C${in_channels}_H${in_rows}_W${in_cols}_T${time_width}
}

# NAME=value list of the parameters, shared by the generic and the summary line prefix
proc adapter_params {param_set} {
    lassign $param_set in_channels in_rows in_cols time_width
    return "IN_CHANNELS=$in_channels IN_ROWS=$in_rows IN_COLS=$in_cols TIME_WIDTH=$time_width"
}

proc adapter_generic {param_set} {
    set stem [adapter_stem $param_set]
    set path [file join [project_srcs_dir] $::ref_dir $stem.txt]
    if {![file exists $path]} {
        error "reference file not found: $path"
    }
    return "[adapter_params $param_set] REF_STEM=\"$stem\""
}

# tb_conv_to_fc_adapter_* print the parameters as NAME=value and REF_STEM=<stem>, followed by a colon
proc adapter_prefix {param_set} {
    return "[adapter_params $param_set] REF_STEM=[adapter_stem $param_set]:"
}

open_saltnet_project

# One testbench in this session
set tb_name [lindex $testbenches 0]
set simset_name [string map {tb_ sim_} $tb_name]
create_simset_if_missing $simset_name $tb_name [list fc/$tb_name.sv fc/tb_conv_to_fc_adapter_common.svh]
run_param_sets $simset_name $tb_name $ref_dir $param_sets adapter_generic adapter_prefix
