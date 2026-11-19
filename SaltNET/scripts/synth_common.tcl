# Shared flow of the synth_*.tcl scripts of the SaltNET project (scripts/net): synthesis + implementation
# (opt, place, route) of one top, out-of-context, to measure timing and resources. Non-project mode: it does not
# touch SaltNET.xpr, so it can run while a simulation runs.
# The flow and every option are explained in docs/SNN/Concept/Layer-RTL/SaltConvSynthFlow.md.
# Sourced by each synth_*.tcl; not meant to be run on its own. A synth_*.tcl calls, in this order:
#   synth_arguments $argv                       -> version, period, synth_only, stale_clear
#   synth_enter_run_dir <directory name>        (under the directory Vivado was started in; synth_run_name builds it)
#   synth_top <top> <generics> [extra files]    -> util_synth.rpt, bram_regs.txt
#   synth_implement <period>                    (skipped with synth_only)
#   synth_report <header> <path groups>         -> info.txt and the other reports
# This file is ASCII only: Vivado reads Tcl sources in the system code page, not UTF-8.

set ::synth_part xck26-sfvc784-2LV-c
set ::synth_scripts_dir [file dirname [file normalize [info script]]]
set ::synth_srcs_dir [file normalize [file join $::synth_scripts_dir .. SaltNET.srcs]]

# quant_version / quant_mem_dir: exported .mem directory of the trained model, chosen in quant_versions.txt
source [file join $::synth_scripts_dir quant_versions.tcl]

# Folders under sources_1/new read for every top (the same folders sim_common.tcl registers in the project);
# modules the top does not use are read but not synthesized
set ::synth_rtl_folders {lib conv fc net}

# Command-line arguments of every synth_*.tcl:
#   version     : wrap or saturate
#   period      : clock period in ns, default 4.8 (the 5 ns target with 0.2 ns kept back)
#   then, in any order, optional words:
#     synth_only  : stop after synthesis (util_synth.rpt, bram_regs.txt), no place and route
#     stale_clear : STALE_CLEAR = 1 (every SaltConv scans its neuron memory); without it STALE_CLEAR = 0
# Returns a dict with the keys version, period, synth_only, stale_clear (0 or 1).
proc synth_arguments {argv} {
    set version [lindex $argv 0]
    if {[lsearch -exact {wrap saturate} $version] < 0} {
        error "unknown version '$version': expected wrap or saturate"
    }
    set period [expr {[llength $argv] > 1 ? [lindex $argv 1] : 4.8}]
    set options [lrange $argv 2 end]
    foreach option $options {
        if {[lsearch -exact {synth_only stale_clear} $option] < 0} {
            error "unexpected argument '$option': expected synth_only or stale_clear"
        }
        if {[llength [lsearch -all -exact $options $option]] > 1} {
            error "argument '$option' given more than once"
        }
    }
    set synth_only [expr {[lsearch -exact $options synth_only] >= 0}]
    set stale_clear [expr {[lsearch -exact $options stale_clear] >= 0}]
    return [dict create version $version period $period synth_only $synth_only stale_clear $stale_clear]
}

# Run directory name: <base>_<version>_<period>, with _stale_clear when STALE_CLEAR = 1
proc synth_run_name {base arguments} {
    set name "${base}_[dict get $arguments version]_[dict get $arguments period]"
    if {[dict get $arguments stale_clear]} {
        append name _stale_clear
    }
    return $name
}

# First line of info.txt: the settings given on the command line
proc synth_header {arguments} {
    return "version [dict get $arguments version] period [dict get $arguments period] stale_clear [dict get $arguments stale_clear]"
}

# NAME="path" generic of a data file read with $readmemh; errors if the file does not exist
proc synth_data_file_generic {name path} {
    if {![file exists $path]} {
        error "data file not found: $path"
    }
    return "$name=\"$path\""
}

# Create <directory Vivado was started in>/<name> and work there; every report and the checkpoint go there
proc synth_enter_run_dir {name} {
    set run_dir [file join [pwd] $name]
    file mkdir $run_dir
    cd $run_dir
}

# Read the RTL under sources_1/new/{lib,conv,fc,net} (and extra_files, e.g. a measurement-only top) and synthesize top
# out-of-context (ports are not tied to package pins). generics: list of NAME=value. Afterwards, before placement:
#   util_synth.rpt : utilization after synthesis (place_design can push BRAM output registers out to slice FFs,
#                    so post-route FF counts are not comparable between runs)
#   bram_regs.txt  : DOA_REG DOB_REG REF_NAME cell of every block RAM; with READ_LATENCY = 2 the second read stage
#                    should be merged (1) on the read port
proc synth_top {top generics {extra_files {}}} {
    set rtl_files {}
    foreach rtl_folder $::synth_rtl_folders {
        set rtl_files [concat $rtl_files [glob [file join $::synth_srcs_dir sources_1 new $rtl_folder *.sv]]]
    }
    read_verilog -sv [concat $rtl_files $extra_files]
    set generic_args {}
    foreach generic $generics {
        lappend generic_args -generic $generic
    }
    synth_design -top $top -part $::synth_part -mode out_of_context {*}$generic_args

    report_utilization -file util_synth.rpt
    set fp [open bram_regs.txt w]
    foreach bram [lsort [get_cells -quiet -hier -filter {REF_NAME =~ RAMB*}]] {
        puts $fp "[get_property DOA_REG $bram] [get_property DOB_REG $bram] [get_property REF_NAME $bram] $bram"
    }
    close $fp
}

# Constraints, then implementation with every command's default directive; no phys_opt_design, no bitstream.
# Measurement clock on the clk port; the other ports are treated as registers right at the boundary (delay 0), so only
# paths inside the design count. salt_conv_impl.xdc (read after synthesis, so synthesis is not affected) puts
# DONT_TOUCH on the multiply DSPs.
proc synth_implement {period} {
    create_clock -period $period -name clk [get_ports clk]
    set_input_delay 0 -clock clk [get_ports -filter {DIRECTION == IN && NAME != clk}]
    set_output_delay 0 -clock clk [all_outputs]
    read_xdc [file join $::synth_srcs_dir constrs_1 new salt_conv_impl.xdc]
    # A pattern that matches nothing only gives a critical warning; stop instead of measuring without the constraint.
    # Only the NeuronUpdate multiply DSPs need it: a DSP elsewhere (e.g. a WeightMemory address y*n_in + src when n_in
    # is not a power of 2) has no cut register to move.
    set multiply_dsps [get_cells -quiet -hier -filter {REF_NAME == DSP48E2 && NAME =~ *neuron_update/*}]
    set protected_dsps [get_cells -quiet -hier -filter {REF_NAME == DSP48E2 && NAME =~ *neuron_update/* && DONT_TOUCH}]
    if {[llength $multiply_dsps] == 0 || [llength $protected_dsps] != [llength $multiply_dsps]} {
        error "salt_conv_impl.xdc: DONT_TOUCH on [llength $protected_dsps] of [llength $multiply_dsps] NeuronUpdate DSP48E2 cells"
    }

    opt_design
    place_design
    route_design
}

# Sequential cells (registers, block RAMs, DSPs) under one instance of the top, e.g. conv1; used as path group ends
proc synth_instance_cells {instance} {
    return [get_cells -quiet -hier -filter "NAME =~ $instance/* && IS_SEQUENTIAL"]
}

# Pins whose name matches pin_pattern (e.g. ADDR*, EN*) of the block RAMs under one memory instance, e.g.
# fc/weight_memory, or conv1/*neuron_memory for every bank of conv1; used as a path group end
proc synth_bram_pins {memory_instance pin_pattern} {
    set brams [get_cells -quiet -hier -filter "NAME =~ $memory_instance/* && REF_NAME =~ RAMB*"]
    if {[llength $brams] == 0} {
        return {}
    }
    return [get_pins -of_objects $brams -filter "REF_PIN_NAME =~ $pin_pattern"]
}

# Address pins of the block RAMs under one memory instance; used as a path group end
proc synth_bram_address_pins {memory_instance} {
    return [synth_bram_pins $memory_instance ADDR*]
}

# Reports after routing, written to the run directory:
#   info.txt           : header line, routed WNS, DSPs under DONT_TOUCH of all DSPs, then one line per path group with
#                        its worst path (slack, data path delay, logic levels, start pin -> end pin)
#   <group name>.rpt   : the 3 worst paths of each path group
#   timing_summary.rpt, worst.rpt (10 worst paths), util.rpt, util_hier.rpt (per instance), post_route.dcp
# path_groups: list of {name from to}; from and to are cells or pins (get_timing_paths -from / -to).
# A group whose ends are empty, or that has no path, is listed as "none".
proc synth_report {header path_groups} {
    set fp [open info.txt w]
    puts $fp $header
    puts $fp "route wns [get_property SLACK [get_timing_paths -max_paths 1 -setup]]"
    puts $fp "dsp dont_touch [llength [get_cells -hier -filter {REF_NAME == DSP48E2 && DONT_TOUCH}]] of [llength [get_cells -hier -filter {REF_NAME == DSP48E2}]]"
    foreach group $path_groups {
        lassign $group name from to
        set path {}
        if {[llength $from] > 0 && [llength $to] > 0} {
            set path [get_timing_paths -from $from -to $to -max_paths 1 -setup]
        }
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
    foreach group $path_groups {
        lassign $group name from to
        if {[llength $from] > 0 && [llength $to] > 0} {
            report_timing -from $from -to $to -max_paths 3 -file $name.rpt
        }
    }
    report_utilization -file util.rpt
    report_utilization -hierarchical -hierarchical_depth 2 -file util_hier.rpt
    write_checkpoint -force post_route.dcp
}
