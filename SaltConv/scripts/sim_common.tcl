# Shared helpers for the run_tb_*.tcl scripts of the SaltConv project.
# Sourced by each run_tb_*.tcl; not meant to be run on its own.
# This file is ASCII only: Vivado reads Tcl sources in the system code page, not UTF-8.

# Use the project already open in the GUI; open it only in batch mode
proc open_saltconv_project {scripts_dir} {
    if {[current_project -quiet] eq ""} {
        open_project [file normalize [file join $scripts_dir .. SaltConv.xpr]]
    }
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
#   param_sets  : list of parameter sets, each a Tcl list
#   generic_cmd : command prefix; [{*}$generic_cmd $param_set] returns the simset generic string
#   prefix_cmd  : command prefix; [{*}$prefix_cmd $param_set] returns the expected summary line prefix
# Each set is judged from simulate.log right after it runs; any failure raises an error,
# so batch mode exits non-zero.
proc run_param_sets {simset_name tb_name param_sets generic_cmd prefix_cmd} {
    set project_dir [get_property DIRECTORY [current_project]]
    set project_name [get_property NAME [current_project]]
    set simset [get_filesets $simset_name]
    set xsim_dir [file join $project_dir $project_name.sim $simset_name behav xsim]
    set ref_dir [file join $project_dir $project_name.srcs sim_1 new ref]

    set_property -name xsim.simulate.xsim.more_options -value "-testplusarg REF_DIR=$ref_dir" -objects $simset
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
