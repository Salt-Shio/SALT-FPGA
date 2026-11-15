# Synthesis + implementation (opt, place, route) of the whole trained network SaltConvFCNet
# (conv1 -> conv2 -> ConvToFCAdapter -> SaltFC (output layer) -> FCMembraneRegister), to measure timing and resources.
# Non-project mode: it does not touch SaltNET.xpr, so it can run while a simulation runs.
# The shared flow is in scripts/synth_common.tcl; the flow and every option are explained in
# docs/SNN/Concept/Layer-RTL/SaltConvSynthFlow.md.
# Usage (PowerShell; the run directory is under SaltNET.runs, which is not version controlled):
#   cd D:\Project\SALT-FPGA\SaltNET\SaltNET.runs
#   vivado -mode batch -source D:/Project/SALT-FPGA/SaltNET/scripts/net/synth_salt_conv_fc_net.tcl -tclargs saturate 4.8
#   arguments: version (wrap | saturate), clock period in ns (default 4.8: the 5 ns target with 0.2 ns kept back),
#              optional synth_only (stop after synthesis)
# Outputs go to SaltNET.runs/conv_fc_net_<version>_<period>/: info.txt (WNS, worst path of every path group below),
# one .rpt per path group, timing_summary.rpt, worst.rpt, util_synth.rpt, bram_regs.txt, util.rpt, util_hier.rpt,
# post_route.dcp.
# Path groups (from -> to; "inside" = both ends in the same instance):
#   conv1_output_to_conv2, conv2_output_to_adapter, adapter_output_to_fc, fc_output_to_membrane_register:
#       an event (or the membrane output) going down into the next instance's FIFO or register
#   conv2_ready_to_conv1   : conv2 in_ready (FIFO full) -> conv1 stall, write-back
#   adapter_ready_to_conv2 : the adapter's event register -> its in_ready -> conv2 stall, write-back
#   fc_ready_to_adapter    : SaltFC in_ready (FIFO full) -> the adapter's event register
#   fc_ready_to_conv2      : SaltFC in_ready -> the adapter's in_ready (1 LUT) -> conv2 stall, write-back
#   fc_weight_read_address : anything in SaltFC -> the address pins of its weight BRAMs (FIFO head -> y*n_in + src)
# This file is ASCII only: Vivado reads Tcl sources in the system code page, not UTF-8.

source [file join [file dirname [file normalize [info script]]] .. synth_common.tcl]

set arguments [synth_arguments $argv]
set version [dict get $arguments version]
set period [dict get $arguments period]

# Same values as the first two parameter sets of run_tb_salt_conv_fc_net.tcl (FC n_col = 4, every FIFO 16 deep)
if {$version eq "wrap"} {
    set version_generics {CONV1_MEMBRANE_INT_WIDTH=12 CONV2_MEMBRANE_INT_WIDTH=14 FC_MEMBRANE_INT_WIDTH=14 SATURATE=0}
} else {
    set version_generics {CONV1_MEMBRANE_INT_WIDTH=9 CONV2_MEMBRANE_INT_WIDTH=11 FC_MEMBRANE_INT_WIDTH=11 SATURATE=1}
}
set generics [concat {
    IN_CHANNELS=2 IN_ROWS=34 IN_COLS=34
    CONV1_OUT_CHANNELS=8 CONV1_KERNEL_SIZE=3 CONV1_STRIDE=2 CONV1_PADDING=1 CONV1_DECAY_TABLE_DEPTH=75 CONV1_FIFO_DEPTH=16
    CONV2_OUT_CHANNELS=16 CONV2_KERNEL_SIZE=3 CONV2_STRIDE=2 CONV2_PADDING=1 CONV2_DECAY_TABLE_DEPTH=75 CONV2_FIFO_DEPTH=16
    FC_OUT_NEURONS=10 FC_NEURONS_PER_ROW=4 FC_DECAY_TABLE_DEPTH=75 FC_FIFO_DEPTH=16
    TIME_WIDTH=16 WEIGHT_WIDTH=7 MEMBRANE_FRAC_WIDTH=0 DECAY_FRAC_WIDTH=6 ROUND=1
    READ_LATENCY=2 COMPUTE_LATENCY=2 OVERLAP=1
} $version_generics]
# Exported .mem files of the trained model; out_weight.mem is packed for n_col = 4 (tools/export_fpga.py --fc-cols 4)
set data_dir [file join $::synth_srcs_dir [quant_mem_dir $version]]
foreach layer {CONV1 CONV2} {
    set file_prefix [string tolower $layer]
    foreach {name suffix} {WEIGHT_FILE _weight.mem THRESHOLD_FILE _threshold.mem DECAY_FILE _decay.mem} {
        lappend generics [synth_data_file_generic ${layer}_$name [file join $data_dir $file_prefix$suffix]]
    }
}
lappend generics [synth_data_file_generic FC_WEIGHT_FILE [file join $data_dir out_weight.mem]]
lappend generics [synth_data_file_generic FC_DECAY_FILE [file join $data_dir out_decay.mem]]

synth_enter_run_dir conv_fc_net_${version}_$period
synth_top SaltConvFCNet $generics
if {[dict get $arguments synth_only]} {
    return
}
synth_implement $period

set conv1_cells    [synth_instance_cells conv1]
set conv2_cells    [synth_instance_cells conv2]
set adapter_cells  [synth_instance_cells conv_to_fc]
set fc_cells       [synth_instance_cells fc]
set register_cells [synth_instance_cells membrane_register]
synth_report "version $version period $period" [list \
    [list conv1_output_to_conv2           $conv1_cells   $conv2_cells] \
    [list conv2_ready_to_conv1            $conv2_cells   $conv1_cells] \
    [list conv2_output_to_adapter         $conv2_cells   $adapter_cells] \
    [list adapter_ready_to_conv2          $adapter_cells $conv2_cells] \
    [list adapter_output_to_fc            $adapter_cells $fc_cells] \
    [list fc_ready_to_adapter             $fc_cells      $adapter_cells] \
    [list fc_ready_to_conv2               $fc_cells      $conv2_cells] \
    [list fc_output_to_membrane_register  $fc_cells      $register_cells] \
    [list conv1_inside                    $conv1_cells   $conv1_cells] \
    [list conv2_inside                    $conv2_cells   $conv2_cells] \
    [list adapter_inside                  $adapter_cells $adapter_cells] \
    [list fc_inside                       $fc_cells      $fc_cells] \
    [list membrane_register_inside        $register_cells $register_cells] \
    [list fc_weight_read_address          $fc_cells      [synth_bram_address_pins fc/weight_memory]] \
]
