# Run tb_neuron_memory once per parameter set, using simulation set sim_neuron_memory of the SaltConv project.
# Generate the reference files first (WSL): gen_neuron_memory_ref.py.
# The parameter list below must match PARAM_SETS in that script.
# The first run also adds NeuronMemory.sv to sources_1 and creates the simulation set; later runs skip that.
# Compile runs once; each parameter set changes the simset generic, then elaborates and simulates.
# Usage:
#   PowerShell (batch mode, close the GUI first):
#       cd D:\Project\SALT-FPGA\SaltConv\SaltConv.sim
#       vivado -mode batch -source D:/Project/SALT-FPGA/SaltConv/scripts/run_tb_neuron_memory.tcl
#   Do not source this from the GUI Tcl console: there the repeated elaborate steps intermittently fail with
#   'Spawn failed' (cause unknown, see the vivado-usage skill, section 8.7). Use the GUI only for a single
#   Run Simulation with the testbench defaults.
#   (Vivado writes vivado.log/.jou and crash dumps to the launch directory; start it inside SaltConv.sim.)
# Outputs go to SaltConv.sim/sim_neuron_memory/behav/xsim; each set is judged from simulate.log right after it runs.
# This file is ASCII only: Vivado reads Tcl sources in the system code page, not UTF-8.

set scripts_dir [file dirname [file normalize [info script]]]
source [file join $scripts_dir sim_common.tcl]

set simset_name sim_neuron_memory

# KERNEL_SIZE STRIDE PADDING OUT_ROWS OUT_COLS OUT_CHANNELS Y_WIDTH X_WIDTH MEMBRANE_WIDTH TIME_WIDTH
set param_sets {
    {3 2 1 17 17 8 6 6 12 16}
    {3 2 1 17 17 8 6 6 9 16}
    {3 2 1 9 9 16 5 5 14 16}
    {3 2 1 9 9 16 5 5 11 16}
    {3 1 1 13 11 5 4 4 5 3}
    {4 1 0 7 5 3 4 3 2 1}
    {5 2 2 10 7 3 5 4 17 21}
    {1 2 0 4 3 2 3 3 7 5}
    {3 1 1 1 1 1 2 2 3 2}
}

proc neuron_memory_generic {param_set} {
    lassign $param_set kernel_size stride padding out_rows out_cols out_channels y_width x_width \
        membrane_width time_width
    return "KERNEL_SIZE=$kernel_size STRIDE=$stride PADDING=$padding OUT_ROWS=$out_rows OUT_COLS=$out_cols OUT_CHANNELS=$out_channels Y_WIDTH=$y_width X_WIDTH=$x_width MEMBRANE_WIDTH=$membrane_width TIME_WIDTH=$time_width"
}

# tb_neuron_memory prints the same NAME=value list as the generic, followed by a colon
proc neuron_memory_prefix {param_set} {
    return "[neuron_memory_generic $param_set]:"
}

open_saltconv_project $scripts_dir

# First run only: register the design source and create the simulation set.
# Files are referenced in place (no copy into the project), same as the other testbenches.
set srcs_dir [file join [get_property DIRECTORY [current_project]] [get_property NAME [current_project]].srcs]
if {[llength [get_files -quiet -of_objects [get_filesets sources_1] *NeuronMemory.sv]] == 0} {
    add_files -fileset sources_1 -norecurse [file join $srcs_dir sources_1 new NeuronMemory.sv]
}
update_compile_order -fileset sources_1
if {[llength [get_filesets -quiet $simset_name]] == 0} {
    create_fileset -simset $simset_name
    set_property SOURCE_SET sources_1 [get_filesets $simset_name]
    add_files -fileset $simset_name -norecurse [file join $srcs_dir sim_1 new tb_neuron_memory.sv]
    set_property top tb_neuron_memory [get_filesets $simset_name]
    set_property top_lib xil_defaultlib [get_filesets $simset_name]
    update_compile_order -fileset $simset_name
}

run_param_sets $simset_name tb_neuron_memory $param_sets neuron_memory_generic neuron_memory_prefix
