# Run tb_candidate_axis once per parameter set, using simulation set sim_candidate_axis of the SaltConv project.
# Generate the reference files first (WSL): gen_candidate_axis_ref.py.
# The parameter list below must match PARAM_SETS in that script.
# Compile runs once; each parameter set changes the simset generic, then elaborates and simulates.
# Usage:
#   Vivado Tcl console: source D:/Project/SALT-FPGA/SaltConv/scripts/run_tb_candidate_axis.tcl
#   PowerShell:         cd D:\Project\SALT-FPGA\SaltConv\SaltConv.sim
#                       vivado -mode batch -source D:/Project/SALT-FPGA/SaltConv/scripts/run_tb_candidate_axis.tcl
#   (Vivado writes vivado.log/.jou and crash dumps to the launch directory; start it inside SaltConv.sim.)
# Outputs go to SaltConv.sim/sim_candidate_axis/behav/xsim; each set is judged from simulate.log right after it runs.
# This file is ASCII only: Vivado reads Tcl sources in the system code page, not UTF-8.

set simset_name sim_candidate_axis

# KERNEL_SIZE STRIDE PADDING OUT_SIZE IN_COORD_WIDTH
set param_sets {
    {3 1 1 64 9}
    {3 2 1 32 6}
    {5 2 2 20 6}
    {4 1 0 7 4}
    {7 3 3 15 5}
    {1 2 0 16 5}
    {2 3 0 10 5}
    {3 1 1 1 3}
}

# Use the project already open in the GUI; open it only in batch mode
if {[current_project -quiet] eq ""} {
    open_project [file normalize [file join [file dirname [info script]] .. SaltConv.xpr]]
}
set project_dir [get_property DIRECTORY [current_project]]
set simset [get_filesets $simset_name]
set xsim_dir [file join $project_dir SaltConv.sim $simset_name behav xsim]
set ref_dir [file join $project_dir SaltConv.srcs sim_1 new ref]

set_property -name xsim.simulate.xsim.more_options -value "-testplusarg REF_DIR=$ref_dir" -objects $simset

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

set summaries {}
set failed_sets {}
try {
    launch_simulation -simset $simset_name -step compile
    foreach param_set $param_sets {
        lassign $param_set kernel_size stride padding out_size in_coord_width
        set_property generic "KERNEL_SIZE=$kernel_size STRIDE=$stride PADDING=$padding OUT_SIZE=$out_size IN_COORD_WIDTH=$in_coord_width" $simset
        launch_simulation -simset $simset_name -step elaborate -noclean_dir
        launch_simulation -simset $simset_name -step simulate -noclean_dir
        close_sim -quiet

        set expected_prefix "K=$kernel_size S=$stride P=$padding OUT_SIZE=$out_size IN_COORD_WIDTH=$in_coord_width:"
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
}

puts "===== tb_candidate_axis results ====="
foreach summary $summaries {
    puts $summary
}
if {[llength $failed_sets] > 0} {
    error "tb_candidate_axis failed parameter sets: $failed_sets"
}
puts "All [llength $param_sets] parameter sets ALL PASS"
