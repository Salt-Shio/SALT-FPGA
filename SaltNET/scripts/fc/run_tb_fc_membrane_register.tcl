# Run the two tb_fc_membrane_register_* testbenches (FCMembraneRegister alone, without SaltFC) once per parameter set,
# each in its own simulation set (sim_fc_membrane_register_back_to_back, sim_fc_membrane_register_gap) of the SaltNET
# project. Each testbench covers one way of sending the rows; the shared checks are in
# tb_fc_membrane_register_common.svh.
# The rows come from the update lines of the SaltFC reference files: generate them first (WSL) with
# gen_salt_fc_ref.py. The list below holds every SaltFC reference file (TRAINED_SETS and SYNTHETIC_SETS there).
# The first run creates the simulation sets (sim_common.tcl registers all RTL in sources_1); later runs skip that.
# Per testbench, compile runs once; each parameter set changes the simset generic, then elaborates and simulates.
# One Vivado session runs one simulation set only (see run_tb_salt_conv.tcl and the vivado-usage skill). So:
#   one testbench name in -tclargs : run that testbench in this session
#   no -tclargs, or several names  : start one child Vivado (batch) per testbench, one after another;
#                                    each child writes SaltNET.sim/<testbench>.log
# Usage:
#   PowerShell (batch mode, close the GUI first):
#       cd D:\Project\SALT-FPGA\SaltNET\SaltNET.sim
#       vivado -mode batch -source D:/Project/SALT-FPGA/SaltNET/scripts/fc/run_tb_fc_membrane_register.tcl
#   Run only one testbench: add -tclargs followed by its name, e.g. -tclargs tb_fc_membrane_register_gap
#   Do not source this from the GUI Tcl console: there the repeated elaborate steps intermittently fail with
#   'Spawn failed' (cause unknown, see the vivado-usage skill, section 8.7). Use the GUI only for a single
#   Run Simulation with the testbench defaults.
#   (Vivado writes vivado.log/.jou and crash dumps to the launch directory; start it inside SaltNET.sim.)
# Outputs go to SaltNET.sim/<simset>/behav/xsim; each set is judged from simulate.log right after it runs.
# All testbenches run even if one fails; the script raises an error at the end if any failed.
# This file is ASCII only: Vivado reads Tcl sources in the system code page, not UTF-8.

set scripts_dir [file dirname [file normalize [info script]]]
source [file join $scripts_dir .. sim_common.tcl]

set testbenches [list tb_fc_membrane_register_back_to_back tb_fc_membrane_register_gap]
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

# Reference file stem (ParamSet.stem in gen_salt_fc_ref.py), OUT_NEURONS, NEURONS_PER_ROW,
# MEMBRANE_WIDTH (= MEMBRANE_INT_WIDTH + MEMBRANE_FRAC_WIDTH), TIME_WIDTH
set param_sets {
    {salt_fc_IN1296_OUT10_COL4_IV14_FV0_RD1_SAT0_SPK0 10 4 14 16}
    {salt_fc_IN1296_OUT10_COL10_IV14_FV0_RD1_SAT0_SPK0 10 10 14 16}
    {salt_fc_IN1296_OUT10_COL4_IV11_FV0_RD1_SAT1_SPK0 10 4 11 16}
    {salt_fc_IN1296_OUT10_COL10_IV11_FV0_RD1_SAT1_SPK0 10 10 11 16}
    {salt_fc_IN7_OUT10_COL3_IV6_FV0_RD1_SAT0_SPK0 10 3 6 11}
    {salt_fc_IN7_OUT10_COL4_IV7_FV2_RD0_SAT1_SPK0 10 4 9 12}
    {salt_fc_IN5_OUT3_COL4_IV5_FV0_RD1_SAT1_SPK0 3 4 5 10}
    {salt_fc_IN7_OUT5_COL1_IV8_FV0_RD0_SAT0_SPK0 5 1 8 12}
    {salt_fc_IN1_OUT1_COL1_IV4_FV0_RD1_SAT1_SPK0 1 1 4 9}
    {salt_fc_IN7_OUT10_COL3_IV6_FV0_RD1_SAT0_SPK1_SH0 10 3 6 11}
    {salt_fc_IN7_OUT10_COL4_IV7_FV2_RD0_SAT1_SPK1_SH1 10 4 9 12}
    {salt_fc_IN5_OUT3_COL4_IV5_FV0_RD1_SAT1_SPK1_SH0 3 4 5 10}
    {salt_fc_IN5_OUT3_COL4_IV5_FV0_RD1_SAT1_SPK1_SH1 3 4 5 10}
    {salt_fc_IN7_OUT5_COL1_IV8_FV0_RD0_SAT0_SPK1_SH1 5 1 8 12}
    {salt_fc_IN9_OUT16_COL8_IV8_FV0_RD1_SAT0_SPK1_SH0 16 8 8 12}
    {salt_fc_IN1_OUT1_COL1_IV4_FV0_RD1_SAT1_SPK1_SH0 1 1 4 9}
}

# NAME=value list of the parameters, shared by the generic and the summary line prefix
proc membrane_register_params {param_set} {
    lassign $param_set stem out_neurons neurons_per_row membrane_width time_width
    return "OUT_NEURONS=$out_neurons NEURONS_PER_ROW=$neurons_per_row MEMBRANE_WIDTH=$membrane_width TIME_WIDTH=$time_width"
}

proc membrane_register_generic {param_set} {
    set stem [lindex $param_set 0]
    set path [file join [project_srcs_dir] $::ref_dir $stem.txt]
    if {![file exists $path]} {
        error "reference file not found: $path"
    }
    return "[membrane_register_params $param_set] REF_STEM=\"$stem\""
}

# tb_fc_membrane_register_* print the parameters as NAME=value and REF_STEM=<stem>, followed by a colon
proc membrane_register_prefix {param_set} {
    return "[membrane_register_params $param_set] REF_STEM=[lindex $param_set 0]:"
}

open_saltnet_project

# One testbench in this session
set tb_name [lindex $testbenches 0]
set simset_name [string map {tb_ sim_} $tb_name]
create_simset_if_missing $simset_name $tb_name [list fc/$tb_name.sv fc/tb_fc_membrane_register_common.svh \
    fc/tb_salt_fc_update_lines.svh]
run_param_sets $simset_name $tb_name $ref_dir $param_sets membrane_register_generic membrane_register_prefix
