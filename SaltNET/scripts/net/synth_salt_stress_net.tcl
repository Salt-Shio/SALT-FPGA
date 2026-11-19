# Synthesis + implementation (opt, place, route) of the stress-test network SaltStressNet (SaltFC Part 12): how much
# timing margin is left at 4.8 ns when about 84 block RAMs are used (60 of the 144 in xck26 assumed taken by other
# logic). Measurement only: random weights, no trained model, no simulation. Non-project mode: it does not touch
# SaltNET.xpr.
#   conv1 -> conv2 -> conv3 -> ConvToFCAdapter -> FC1 (fires) -> FC2 (fires) -> FC3 (output layer) -> FCMembraneRegister
# Generate the data first (WSL, conda environment jax, in scripts/net):
#   python gen_salt_stress_net_mem.py --training-repo /mnt/d/Project/Spiking-Affine-Lazy-Training \
#       --out-dir /mnt/d/Project/SALT-FPGA/SaltNET/SaltNET.runs/stress_net_mem
# It writes the weight and threshold files and generics.txt (network shape and widths, the only place they are set)
# to SaltNET.runs/stress_net_mem/<version>/. The decay tables are the trained model's (quant_versions.txt):
# conv1 and conv2 their own, conv3 borrows conv2's, FC1 to FC3 borrow the out layer's.
# The shared flow is in scripts/synth_common.tcl; the flow and every option are explained in
# docs/SNN/Concept/Layer-RTL/SaltConvSynthFlow.md.
# Usage (PowerShell; the run directory is under SaltNET.runs, which is not version controlled):
#   cd D:\Project\SALT-FPGA\SaltNET\SaltNET.runs
#   vivado -mode batch -source D:/Project/SALT-FPGA/SaltNET/scripts/net/synth_salt_stress_net.tcl -tclargs saturate 4.8
#   arguments: version (wrap | saturate), clock period in ns (default 4.8: the 5 ns target with 0.2 ns kept back),
#              then optional words: synth_only (stop after synthesis: check the block RAM count in util_synth.rpt
#              first), stale_clear (STALE_CLEAR = 1: every conv scans its neuron memory; without it STALE_CLEAR = 0)
# Outputs go to SaltNET.runs/stress_net_<version>_<period>[_stale_clear]/: info.txt (WNS, worst path of every path group below),
# one .rpt per path group, timing_summary.rpt, worst.rpt, util_synth.rpt, bram_regs.txt, util.rpt, util_hier.rpt,
# post_route.dcp.
# Path groups, for every pair of neighbouring instances a -> b (the adapter is conv_to_fc):
#   <a>_output_to_<b> : an event (or the membrane output) going down into b's FIFO or register
#   <b>_ready_to_<a>  : b's back-pressure into a
#   plus fc1_ready_to_conv3 (FC1 in_ready -> the adapter's in_ready, 1 LUT -> conv3), <instance>_inside for every
#   instance, and fc<n>_weight_read_address (anything in that FC -> the address pins of its weight BRAMs)
# This file is ASCII only: Vivado reads Tcl sources in the system code page, not UTF-8.

source [file join [file dirname [file normalize [info script]]] .. synth_common.tcl]

set arguments [synth_arguments $argv]
set version [dict get $arguments version]
set period [dict get $arguments period]

# NAME=value lines of generics.txt ('#' starts a comment); errors if the file is missing or a line is malformed
proc read_generics_file {path} {
    if {![file exists $path]} {
        error "$path not found: run scripts/net/gen_salt_stress_net_mem.py first"
    }
    set fd [open $path r]
    set text [read $fd]
    close $fd
    set generics {}
    set line_number 0
    foreach line [split $text "\n"] {
        incr line_number
        set line [string trim [lindex [split $line "#"] 0]]
        if {$line eq ""} {
            continue
        }
        if {![regexp {^[A-Z0-9_]+=[0-9]+$} $line]} {
            error "$path line $line_number is malformed: $line"
        }
        lappend generics $line
    }
    return $generics
}

set stress_dir [file normalize [file join $::synth_scripts_dir .. SaltNET.runs stress_net_mem $version]]
set trained_dir [file join $::synth_srcs_dir [quant_mem_dir $version]]
set generics [read_generics_file [file join $stress_dir generics.txt]]
lappend generics STALE_CLEAR=[dict get $arguments stale_clear]
foreach layer {conv1 conv2 conv3 fc1 fc2 fc3} {
    lappend generics [synth_data_file_generic [string toupper $layer]_WEIGHT_FILE \
        [file join $stress_dir ${layer}_weight.mem]]
}
foreach layer {conv1 conv2 conv3 fc1 fc2} {
    lappend generics [synth_data_file_generic [string toupper $layer]_THRESHOLD_FILE \
        [file join $stress_dir ${layer}_threshold.mem]]
}
foreach {layer trained_layer} {conv1 conv1 conv2 conv2 conv3 conv2 fc1 out fc2 out fc3 out} {
    lappend generics [synth_data_file_generic [string toupper $layer]_DECAY_FILE \
        [file join $trained_dir ${trained_layer}_decay.mem]]
}

synth_enter_run_dir [synth_run_name stress_net $arguments]
synth_top SaltStressNet $generics [list [file join $::synth_scripts_dir net SaltStressNet.sv]]
if {[dict get $arguments synth_only]} {
    return
}
synth_implement $period

# {label instance} in event order; the label names the path groups
set chain {{conv1 conv1} {conv2 conv2} {conv3 conv3} {adapter conv_to_fc} {fc1 fc1} {fc2 fc2} {fc3 fc3}
           {membrane_register membrane_register}}
foreach entry $chain {
    lassign $entry label instance
    set cells($label) [synth_instance_cells $instance]
}
set path_groups {}
for {set index 0} {$index < [llength $chain] - 1} {incr index} {
    set upper [lindex $chain $index 0]
    set lower [lindex $chain [expr {$index + 1}] 0]
    lappend path_groups [list ${upper}_output_to_$lower $cells($upper) $cells($lower)]
    lappend path_groups [list ${lower}_ready_to_$upper $cells($lower) $cells($upper)]
}
lappend path_groups [list fc1_ready_to_conv3 $cells(fc1) $cells(conv3)]
foreach entry $chain {
    set label [lindex $entry 0]
    lappend path_groups [list ${label}_inside $cells($label) $cells($label)]
}
foreach layer {fc1 fc2 fc3} {
    lappend path_groups [list ${layer}_weight_read_address $cells($layer) \
        [synth_bram_address_pins $layer/weight_memory]]
}
synth_report [synth_header $arguments] $path_groups
