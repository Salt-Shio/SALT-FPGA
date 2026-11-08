# Shared helpers for the run_tb_*.tcl scripts of the SaltNET project (scripts/lib, scripts/conv, scripts/net, ...).
# Sourced by each run_tb_*.tcl; not meant to be run on its own.
# This file is ASCII only: Vivado reads Tcl sources in the system code page, not UTF-8.

# SaltNET project directory: this file sits in SaltNET/scripts
set ::saltnet_project_dir [file normalize [file join [file dirname [info script]] ..]]

# quant_version / quant_mem_dir: which quantized model the tests use (quant_versions.txt)
source [file join [file dirname [info script]] quant_versions.tcl]

# Folders under sources_1/new and sim_1/new: lib (modules not tied to a layer type), one per layer type, net (multi-layer tops)
set ::saltnet_rtl_folders {lib conv fc net}

# <project>.srcs of the open project
proc project_srcs_dir {} {
    return [file join [get_property DIRECTORY [current_project]] [get_property NAME [current_project]].srcs]
}

# Use the project already open in the GUI; open it only in batch mode. Then register the design sources.
proc open_saltnet_project {} {
    if {[current_project -quiet] eq ""} {
        open_project [file join $::saltnet_project_dir SaltNET.xpr]
    }
    add_design_sources
}

# Register every .sv under sources_1/new/<folder>/ in sources_1 that is not there yet, referenced in place (no copy into
# the project). All RTL is in sources_1, so the run_tb_*.tcl scripts can run in any order on a fresh project.
proc add_design_sources {} {
    set new_dir [file join [project_srcs_dir] sources_1 new]
    set registered {}
    foreach registered_file [get_files -quiet -of_objects [get_filesets sources_1]] {
        lappend registered [file normalize $registered_file]
    }
    set missing {}
    foreach rtl_folder $::saltnet_rtl_folders {
        foreach path [glob -nocomplain -directory [file join $new_dir $rtl_folder] *.sv] {
            set path [file normalize $path]
            if {[lsearch -exact $registered $path] < 0} {
                lappend missing $path
            }
        }
    }
    if {[llength $missing] > 0} {
        add_files -fileset sources_1 -norecurse $missing
        update_compile_order -fileset sources_1
    }
}

# Create a simulation set on the first run; later runs keep the existing one and only add the files of tb_files
# it does not hold yet (e.g. a header added to the testbench later).
#   simset_name : simulation set to create
#   top_name    : testbench top module
#   tb_files    : testbench files relative to sim_1/new, e.g. {conv/tb_salt_conv_ready_high.sv conv/tb_salt_conv_common.svh}
proc create_simset_if_missing {simset_name top_name tb_files} {
    set tb_dir [file join [project_srcs_dir] sim_1 new]
    set tb_paths {}
    foreach tb_file $tb_files {
        lappend tb_paths [file normalize [file join $tb_dir $tb_file]]
    }
    if {[llength [get_filesets -quiet $simset_name]] > 0} {
        set registered {}
        foreach registered_file [get_files -quiet -of_objects [get_filesets $simset_name]] {
            lappend registered [file normalize $registered_file]
        }
        set missing {}
        foreach tb_path $tb_paths {
            if {[lsearch -exact $registered $tb_path] < 0} {
                lappend missing $tb_path
            }
        }
        if {[llength $missing] > 0} {
            add_files -fileset $simset_name -norecurse $missing
            update_compile_order -fileset $simset_name
        }
        return
    }
    create_fileset -simset $simset_name
    set simset [get_filesets $simset_name]
    set_property SOURCE_SET sources_1 $simset
    add_files -fileset $simset_name -norecurse $tb_paths
    set_property top $top_name $simset
    set_property top_lib xil_defaultlib $simset
    update_compile_order -fileset $simset_name
}

# Run each testbench in its own child Vivado (batch), one after another: one Vivado session runs one simulation set
# only (see run_tb_salt_conv.tcl). The child sources script_path with -tclargs <testbench> {*}child_args and writes
# SaltNET.sim/<testbench>.log; its results block is printed here. Raises an error at the end if any child failed.
proc run_testbenches_in_children {script_path testbenches child_args} {
    set sim_dir [file join $::saltnet_project_dir SaltNET.sim]
    set vivado_bat [file join $::env(XILINX_VIVADO) bin vivado.bat]
    set failed_testbenches {}
    foreach tb_name $testbenches {
        set log_path [file join $sim_dir $tb_name.log]
        puts "##### $tb_name: running in a child Vivado, log $log_path"
        set child_failed [catch {exec -ignorestderr $vivado_bat -mode batch -nojournal -log $log_path \
            -source $script_path -tclargs $tb_name {*}$child_args} child_output]
        if {$child_failed} {
            lappend failed_testbenches $tb_name
        }
        # Print the child's result block: from the results header to the end of its log
        set log_fd [open $log_path r]
        set printing 0
        foreach line [split [read $log_fd] "\n"] {
            if {[string match "===== $tb_name results =====" $line]} { set printing 1 }
            if {$printing && ![string match "#*" $line]} { puts $line }
        }
        close $log_fd
    }
    if {[llength $failed_testbenches] > 0} {
        error "failed testbenches: $failed_testbenches"
    }
    puts "All testbenches ALL PASS: $testbenches"
}

# Find the testbench summary line in simulate.log; it must carry the expected parameters
proc read_summary {log_path expected_prefix} {
    set log_fd [open $log_path r]
    set log_text [read $log_fd]
    close $log_fd
    foreach line [split $log_text "\n"] {
        if {[string first $expected_prefix $line] == 0} {
            return $line
        }
    }
    return ""
}

# Compile once, then elaborate and simulate every parameter set of one simulation set.
#   simset_name : simulation set that holds the testbench
#   tb_name     : used only in the printed report
#   ref_dir     : reference file directory relative to <project>.srcs (e.g. sim_1/new/conv/ref), passed to the
#                 testbench as +REF_DIR; empty for a testbench that reads no reference files
#   param_sets  : list of parameter sets, each a Tcl list
#   generic_cmd : command prefix; [{*}$generic_cmd $param_set] returns the simset generic string
#   prefix_cmd  : command prefix; [{*}$prefix_cmd $param_set] returns the expected summary line prefix
# Each set is judged from simulate.log right after it runs; any failure raises an error,
# so batch mode exits non-zero.
proc run_param_sets {simset_name tb_name ref_dir param_sets generic_cmd prefix_cmd} {
    set project_dir [get_property DIRECTORY [current_project]]
    set project_name [get_property NAME [current_project]]
    set simset [get_filesets $simset_name]
    set xsim_dir [file join $project_dir $project_name.sim $simset_name behav xsim]

    if {$ref_dir eq ""} {
        set_property -name xsim.simulate.xsim.more_options -value "" -objects $simset
    } else {
        set ref_path [file join [project_srcs_dir] $ref_dir]
        set_property -name xsim.simulate.xsim.more_options -value "-testplusarg REF_DIR=$ref_path" -objects $simset
    }
    # The default runtime is 1000ns, which cuts long testbenches off before $finish; run until $finish instead
    set_property -name xsim.simulate.runtime -value {-all} -objects $simset

    # launch_simulation -simset X still reads the xsim.simulate.* properties from the active simulation set
    # (seen in Vivado 2025.2: the xsim -key and -testplusarg came from the active simset), so make X active
    # while it runs and restore the previous one afterwards
    set previous_simset [current_fileset -simset]
    current_fileset -simset $simset

    set summaries {}
    set failed_sets {}
    try {
        launch_simulation -simset $simset_name -step compile
        foreach param_set $param_sets {
            set_property generic [{*}$generic_cmd $param_set] $simset
            launch_simulation -simset $simset_name -step elaborate -noclean_dir
            launch_simulation -simset $simset_name -step simulate -noclean_dir
            close_sim -quiet

            set expected_prefix [{*}$prefix_cmd $param_set]
            set summary [read_summary [file join $xsim_dir simulate.log] $expected_prefix]
            if {$summary eq ""} {
                set summary "$expected_prefix summary line not found, see [file join $xsim_dir simulate.log]"
                lappend failed_sets $param_set
            } elseif {![string match "*ALL PASS" $summary]} {
                lappend failed_sets $param_set
            }
            lappend summaries $summary
        }
    } finally {
        # Clear the generic so a plain GUI Run Simulation uses the testbench defaults
        set_property generic {} $simset
        current_fileset -simset $previous_simset
    }

    puts "===== $tb_name results ====="
    foreach summary $summaries {
        puts $summary
    }
    if {[llength $failed_sets] > 0} {
        error "$tb_name failed parameter sets: $failed_sets"
    }
    puts "All [llength $param_sets] parameter sets ALL PASS"
}
