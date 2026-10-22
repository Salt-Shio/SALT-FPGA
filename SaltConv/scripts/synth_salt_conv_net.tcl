# Synthesis + implementation (opt, place, route) of the two-layer SaltConvNet (trained conv1 -> conv2), to measure
# timing and resources. Non-project mode: it does not touch SaltConv.xpr, so it can run while a simulation runs.
# The flow and every option are explained in docs/SNN/Concept/Layer-RTL/SaltConvSynthFlow.md.
# Usage (PowerShell; the run directory is under SaltConv.runs, which is not version controlled):
#   cd D:\Project\SALT-FPGA\SaltConv\SaltConv.runs
#   vivado -mode batch -source D:/Project/SALT-FPGA/SaltConv/scripts/synth_salt_conv_net.tcl -tclargs saturate 4.8
#   arguments: version (wrap | saturate), clock period in ns (default 4.8: the 5 ns target with 0.2 ns kept back)
# Outputs go to SaltConv.runs/net_<version>_<period>/: info.txt (WNS, layer-crossing and in-layer worst paths),
# timing_summary.rpt, worst.rpt, conv1_to_conv2.rpt, conv2_to_conv1.rpt, util.rpt, util_hier.rpt, post_route.dcp.
# This file is ASCII only: Vivado reads Tcl sources in the system code page, not UTF-8.

set version [lindex $argv 0]
set period [expr {[llength $argv] > 1 ? [lindex $argv 1] : 4.8}]
set part xck26-sfvc784-2LV-c

set scripts_dir [file dirname [file normalize [info script]]]
set srcs_dir [file normalize [file join $scripts_dir .. SaltConv.srcs]]
set mem_root [file join $srcs_dir sources_1 mem]

# Per-version parameters (same values as run_tb_salt_conv_net.tcl); the rest are SaltConvNet defaults or below
switch -- $version {
    wrap {
        set data_dir [file join $mem_root best_val50_b7_fa6_fv0_round_pc_clip100_wrap_g1]
        set version_generics {CONV1_MEMBRANE_INT_WIDTH=12 CONV2_MEMBRANE_INT_WIDTH=14 SATURATE=0}
    }
    saturate {
        set data_dir [file join $mem_root best_val50_b7_fa6_fv0_round_pc_clip100_saturate_iv9-11-11]
        set version_generics {CONV1_MEMBRANE_INT_WIDTH=9 CONV2_MEMBRANE_INT_WIDTH=11 SATURATE=1}
    }
    default {
        error "unknown version '$version': expected wrap or saturate"
    }
}
set generics [concat {
    IN_CHANNELS=2 IN_ROWS=34 IN_COLS=34
    CONV1_OUT_CHANNELS=8 CONV1_KERNEL_SIZE=3 CONV1_STRIDE=2 CONV1_PADDING=1 CONV1_DECAY_TABLE_DEPTH=75 CONV1_FIFO_DEPTH=16
    CONV2_OUT_CHANNELS=16 CONV2_KERNEL_SIZE=3 CONV2_STRIDE=2 CONV2_PADDING=1 CONV2_DECAY_TABLE_DEPTH=75 CONV2_FIFO_DEPTH=16
    TIME_WIDTH=16 WEIGHT_WIDTH=7 MEMBRANE_FRAC_WIDTH=0 DECAY_FRAC_WIDTH=6 ROUND=1
    READ_LATENCY=2 COMPUTE_LATENCY=2 OVERLAP=1
} $version_generics]
foreach layer {CONV1 CONV2} {
    set file_prefix [string tolower $layer]
    foreach {name suffix} {WEIGHT_FILE _weight.mem THRESHOLD_FILE _threshold.mem DECAY_FILE _decay.mem} {
        set path [file join $data_dir $file_prefix$suffix]
        if {![file exists $path]} {
            error "data file not found: $path"
        }
        lappend generics "${layer}_$name=\"$path\""
    }
}
set generic_args {}
foreach generic $generics {
    lappend generic_args -generic $generic
}

set run_dir [file join [pwd] net_${version}_$period]
file mkdir $run_dir
cd $run_dir

# Synthesis: all RTL under sources_1/new, top SaltConvNet, out-of-context (ports are not tied to package pins)
read_verilog -sv [glob [file join $srcs_dir sources_1 new *.sv]]
synth_design -top SaltConvNet -part $part -mode out_of_context {*}$generic_args

# Constraints: measurement clock on the clk port; the other ports are treated as registers right at the boundary
# (delay 0), so only paths inside the design count. Then the implementation-only constraints of SaltConv.
create_clock -period $period -name clk [get_ports clk]
set_input_delay 0 -clock clk [get_ports -filter {DIRECTION == IN && NAME != clk}]
set_output_delay 0 -clock clk [all_outputs]
read_xdc [file join $srcs_dir constrs_1 new salt_conv_impl.xdc]
# A pattern that matches nothing only gives a critical warning; stop instead of measuring without the constraint
set multiply_dsps [get_cells -hier -filter {REF_NAME == DSP48E2}]
set protected_dsps [get_cells -quiet -hier -filter {REF_NAME == DSP48E2 && DONT_TOUCH}]
if {[llength $multiply_dsps] == 0 || [llength $protected_dsps] != [llength $multiply_dsps]} {
    error "salt_conv_impl.xdc: DONT_TOUCH on [llength $protected_dsps] of [llength $multiply_dsps] DSP48E2 cells"
}

# Implementation: every command with its default directive; no phys_opt_design, no bitstream (out-of-context)
opt_design
place_design
route_design

set conv1_cells [get_cells -hier -filter {NAME =~ conv1/* && IS_SEQUENTIAL}]
set conv2_cells [get_cells -hier -filter {NAME =~ conv2/* && IS_SEQUENTIAL}]
set fp [open info.txt w]
puts $fp "version $version period $period"
puts $fp "route wns [get_property SLACK [get_timing_paths -max_paths 1 -setup]]"
puts $fp "dsp dont_touch [llength [get_cells -hier -filter {REF_NAME == DSP48E2 && DONT_TOUCH}]] of [llength [get_cells -hier -filter {REF_NAME == DSP48E2}]]"
foreach {name from to} [list conv1_to_conv2 $conv1_cells $conv2_cells conv2_to_conv1 $conv2_cells $conv1_cells \
                             conv1_inside $conv1_cells $conv1_cells conv2_inside $conv2_cells $conv2_cells] {
    set path [get_timing_paths -from $from -to $to -max_paths 1 -setup]
    if {[llength $path] == 0} {
        puts $fp "$name none"
        continue
    }
    puts $fp [format "%s slack %.3f datapath %.3f levels %d  %s -> %s" $name [get_property SLACK $path] \
        [get_property DATAPATH_DELAY $path] [get_property LOGIC_LEVELS $path] \
        [get_property STARTPOINT_PIN $path] [get_property ENDPOINT_PIN $path]]
}
close $fp
report_timing_summary -file timing_summary.rpt
report_timing -max_paths 10 -nworst 1 -file worst.rpt
report_timing -from $conv1_cells -to $conv2_cells -max_paths 3 -file conv1_to_conv2.rpt
report_timing -from $conv2_cells -to $conv1_cells -max_paths 3 -file conv2_to_conv1.rpt
report_utilization -file util.rpt
report_utilization -hierarchical -hierarchical_depth 2 -file util_hier.rpt
write_checkpoint -force post_route.dcp
