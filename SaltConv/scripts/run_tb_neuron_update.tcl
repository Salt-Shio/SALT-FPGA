# Run tb_neuron_update once per parameter set, using simulation set sim_neuron_update of the SaltConv project.
# Generate the reference files first (WSL): gen_neuron_update_ref.py.
# The parameter list below must match TRAINED_LAYERS and SYNTHETIC_SETS in that script.
# Trained layers use the decay files exported by the training repo (sources_1/mem/<quant folder>/);
# synthetic sets use the decay files written by gen_neuron_update_ref.py (sim_1/new/ref/).
# Every set runs with all four ROUND x SATURATE combinations.
# The first run also adds NeuronUpdate.sv to sources_1 and creates the simulation set; later runs skip that.
# Compile runs once; each parameter set changes the simset generic, then elaborates and simulates.
# Usage:
#   PowerShell (batch mode, close the GUI first):
#       cd D:\Project\SALT-FPGA\SaltConv\SaltConv.sim
#       vivado -mode batch -source D:/Project/SALT-FPGA/SaltConv/scripts/run_tb_neuron_update.tcl
#   Do not source this from the GUI Tcl console: there the repeated elaborate steps intermittently fail with
#   'Spawn failed' (cause unknown, see the vivado-usage skill, section 8.7). Use the GUI only for a single
#   Run Simulation with the testbench defaults.
#   (Vivado writes vivado.log/.jou and crash dumps to the launch directory; start it inside SaltConv.sim.)
# Outputs go to SaltConv.sim/sim_neuron_update/behav/xsim; each set is judged from simulate.log right after it runs.
# This file is ASCII only: Vivado reads Tcl sources in the system code page, not UTF-8.

set scripts_dir [file dirname [file normalize [info script]]]
source [file join $scripts_dir sim_common.tcl]

set simset_name sim_neuron_update

set wrap_dir sources_1/mem/best_val50_b7_fa6_fv0_round_pc_clip100_wrap_g1
set saturate_dir sources_1/mem/best_val50_b7_fa6_fv0_round_pc_clip100_saturate_iv9-11-11

# TIME_WIDTH WEIGHT_WIDTH MEMBRANE_INT_WIDTH MEMBRANE_FRAC_WIDTH DECAY_FRAC_WIDTH DECAY_TABLE_DEPTH
# decay file (relative to SaltConv.srcs)
set base_sets [list \
    [list 16 7 12 0 6 75 $wrap_dir/conv1_decay.mem] \
    [list 16 7 14 0 6 75 $wrap_dir/conv2_decay.mem] \
    [list 16 7 9 0 6 75 $saturate_dir/conv1_decay.mem] \
    [list 16 7 11 0 6 75 $saturate_dir/conv2_decay.mem] \
    [list 2 3 4 0 3 2 sim_1/new/ref/neuron_update_B3_IV4_FV0_FA3_D2_T2_decay.mem] \
    [list 2 2 2 0 1 1 sim_1/new/ref/neuron_update_B2_IV2_FV0_FA1_D1_T2_decay.mem] \
    [list 3 4 3 2 4 5 sim_1/new/ref/neuron_update_B4_IV3_FV2_FA4_D5_T3_decay.mem] \
    [list 20 9 18 3 12 40 sim_1/new/ref/neuron_update_B9_IV18_FV3_FA12_D40_T20_decay.mem] \
]

# Each parameter set is a base set followed by ROUND SATURATE
set param_sets {}
foreach base_set $base_sets {
    foreach round_enabled {0 1} {
        foreach saturate_enabled {0 1} {
            lappend param_sets [concat $base_set [list $round_enabled $saturate_enabled]]
        }
    }
}

# NAME=value list of the integer parameters, shared by the generic and the summary line prefix
proc neuron_update_integer_params {param_set} {
    lassign $param_set time_width weight_width membrane_int_width membrane_frac_width decay_frac_width \
        decay_table_depth decay_file round_enabled saturate_enabled
    return "TIME_WIDTH=$time_width WEIGHT_WIDTH=$weight_width MEMBRANE_INT_WIDTH=$membrane_int_width MEMBRANE_FRAC_WIDTH=$membrane_frac_width DECAY_FRAC_WIDTH=$decay_frac_width DECAY_TABLE_DEPTH=$decay_table_depth ROUND=$round_enabled SATURATE=$saturate_enabled"
}

proc neuron_update_generic {param_set} {
    set decay_file [lindex $param_set 6]
    set srcs_dir [file join [get_property DIRECTORY [current_project]] [get_property NAME [current_project]].srcs]
    set decay_path [file join $srcs_dir $decay_file]
    if {![file exists $decay_path]} {
        error "decay file not found: $decay_path"
    }
    return "[neuron_update_integer_params $param_set] DECAY_FILE=\"$decay_path\""
}

# tb_neuron_update prints the integer parameters as NAME=value, followed by a colon
proc neuron_update_prefix {param_set} {
    return "[neuron_update_integer_params $param_set]:"
}

open_saltconv_project $scripts_dir

# First run only: register the design source and create the simulation set.
# Files are referenced in place (no copy into the project), same as the other testbenches.
set srcs_dir [file join [get_property DIRECTORY [current_project]] [get_property NAME [current_project]].srcs]
if {[llength [get_files -quiet -of_objects [get_filesets sources_1] *NeuronUpdate.sv]] == 0} {
    add_files -fileset sources_1 -norecurse [file join $srcs_dir sources_1 new NeuronUpdate.sv]
}
update_compile_order -fileset sources_1
if {[llength [get_filesets -quiet $simset_name]] == 0} {
    create_fileset -simset $simset_name
    set_property SOURCE_SET sources_1 [get_filesets $simset_name]
    add_files -fileset $simset_name -norecurse [file join $srcs_dir sim_1 new tb_neuron_update.sv]
    set_property top tb_neuron_update [get_filesets $simset_name]
    set_property top_lib xil_defaultlib [get_filesets $simset_name]
    update_compile_order -fileset $simset_name
}

run_param_sets $simset_name tb_neuron_update $param_sets neuron_update_generic neuron_update_prefix
