# Synthesis + implementation (opt, place, route) of the two-layer SaltConvNet (trained conv1 -> conv2), to measure
# timing and resources. Non-project mode: it does not touch SaltNET.xpr, so it can run while a simulation runs.
# The shared flow is in scripts/synth_common.tcl; the flow and every option are explained in
# docs/SNN/Concept/Layer-RTL/SaltConvSynthFlow.md.
# Usage (PowerShell; the run directory is under SaltNET.runs, which is not version controlled):
#   cd D:\Project\SALT-FPGA\SaltNET\SaltNET.runs
#   vivado -mode batch -source D:/Project/SALT-FPGA/SaltNET/scripts/net/synth_salt_conv_net.tcl -tclargs saturate 4.8
#   arguments: version (wrap | saturate), clock period in ns (default 4.8: the 5 ns target with 0.2 ns kept back),
#              then optional words: synth_only (stop after synthesis), stale_clear (STALE_CLEAR = 1: every conv
#              scans its neuron memory; without it STALE_CLEAR = 0)
# Outputs go to SaltNET.runs/net_<version>_<period>[_stale_clear]/: info.txt (WNS, layer-crossing and in-layer worst paths), one .rpt
# per path group, timing_summary.rpt, worst.rpt, util_synth.rpt, bram_regs.txt, util.rpt, util_hier.rpt, post_route.dcp.
# Cross-layer paths: conv1_output_to_conv2 = conv1 sending a spike event (out_valid, data) into the conv2 FIFO;
# conv2_ready_to_conv1 = conv2 back-pressure (in_ready -> conv1 out_ready -> conv1 stall, write-back), no data goes back.
# This file is ASCII only: Vivado reads Tcl sources in the system code page, not UTF-8.

source [file join [file dirname [file normalize [info script]]] .. synth_common.tcl]

set arguments [synth_arguments $argv]
set version [dict get $arguments version]
set period [dict get $arguments period]

# Per-version parameters (same values as run_tb_salt_conv_net.tcl); the rest are SaltConvNet defaults or below
if {$version eq "wrap"} {
    set version_generics {CONV1_MEMBRANE_INT_WIDTH=12 CONV2_MEMBRANE_INT_WIDTH=14 SATURATE=0}
} else {
    set version_generics {CONV1_MEMBRANE_INT_WIDTH=9 CONV2_MEMBRANE_INT_WIDTH=11 SATURATE=1}
}
set generics [concat {
    IN_CHANNELS=2 IN_ROWS=34 IN_COLS=34
    CONV1_OUT_CHANNELS=8 CONV1_KERNEL_SIZE=3 CONV1_STRIDE=2 CONV1_PADDING=1 CONV1_DECAY_TABLE_DEPTH=75 CONV1_FIFO_DEPTH=16
    CONV2_OUT_CHANNELS=16 CONV2_KERNEL_SIZE=3 CONV2_STRIDE=2 CONV2_PADDING=1 CONV2_DECAY_TABLE_DEPTH=75 CONV2_FIFO_DEPTH=16
    TIME_WIDTH=16 WEIGHT_WIDTH=7 MEMBRANE_FRAC_WIDTH=0 DECAY_FRAC_WIDTH=6 ROUND=1
    READ_LATENCY=2 COMPUTE_LATENCY=2 OVERLAP=1 SCAN_CELLS_PER_TICK=1
} $version_generics]
lappend generics STALE_CLEAR=[dict get $arguments stale_clear]
set data_dir [file join $::synth_srcs_dir [quant_mem_dir $version]]
foreach layer {CONV1 CONV2} {
    set file_prefix [string tolower $layer]
    foreach {name suffix} {WEIGHT_FILE _weight.mem THRESHOLD_FILE _threshold.mem DECAY_FILE _decay.mem} {
        lappend generics [synth_data_file_generic ${layer}_$name [file join $data_dir $file_prefix$suffix]]
    }
}

synth_enter_run_dir [synth_run_name net $arguments]
synth_top SaltConvNet $generics
if {[dict get $arguments synth_only]} {
    return
}
synth_implement $period

set conv1_cells [synth_instance_cells conv1]
set conv2_cells [synth_instance_cells conv2]
synth_report [synth_header $arguments] [list \
    [list conv1_output_to_conv2 $conv1_cells $conv2_cells] \
    [list conv2_ready_to_conv1  $conv2_cells $conv1_cells] \
    [list conv1_inside          $conv1_cells $conv1_cells] \
    [list conv2_inside          $conv2_cells $conv2_cells] \
]
