# Run tb_neuron_update (DecayLookup feeding NeuronUpdate) once per parameter set, using simulation set
# sim_neuron_update of the SaltNET project.
# Generate the reference files first (WSL): gen_neuron_update_ref.py.
# The parameter list below must match TRAINED_LAYERS and SYNTHETIC_SETS in that script.
# Trained layers use the decay files exported by the training repo (sources_1/mem/<quant folder>/);
# synthetic sets use the decay files written by gen_neuron_update_ref.py (sim_1/new/lib/ref/).
# Every set runs with all four ROUND x SATURATE combinations with SPIKE_OUTPUT = 1, and again with SPIKE_OUTPUT = 0
# for ROUND = 1 with both SATURATE values (the no-fire path only differs after the fit, so wrap and saturate are enough).
# The first run creates the simulation set (sim_common.tcl registers all RTL in sources_1); later runs skip that.
# Compile runs once; each parameter set changes the simset generic, then elaborates and simulates.
# Usage:
#   PowerShell (batch mode, close the GUI first):
#       cd D:\Project\SALT-FPGA\SaltNET\SaltNET.sim
#       vivado -mode batch -source D:/Project/SALT-FPGA/SaltNET/scripts/lib/run_tb_neuron_update.tcl
#   Do not source this from the GUI Tcl console: there the repeated elaborate steps intermittently fail with
#   'Spawn failed' (cause unknown, see the vivado-usage skill, section 8.7). Use the GUI only for a single
#   Run Simulation with the testbench defaults.
#   (Vivado writes vivado.log/.jou and crash dumps to the launch directory; start it inside SaltNET.sim.)
# Outputs go to SaltNET.sim/sim_neuron_update/behav/xsim; each set is judged from simulate.log right after it runs.
# This file is ASCII only: Vivado reads Tcl sources in the system code page, not UTF-8.

set scripts_dir [file dirname [file normalize [info script]]]
source [file join $scripts_dir .. sim_common.tcl]

set simset_name sim_neuron_update

# Exported .mem directories of the trained models, chosen in quant_versions.txt
set wrap_dir [quant_mem_dir wrap]
set saturate_dir [quant_mem_dir saturate]

# TIME_WIDTH WEIGHT_WIDTH MEMBRANE_INT_WIDTH MEMBRANE_FRAC_WIDTH DECAY_FRAC_WIDTH DECAY_TABLE_DEPTH
# decay file (relative to SaltNET.srcs)
set base_sets [list \
    [list 16 7 12 0 6 75 $wrap_dir/conv1_decay.mem] \
    [list 16 7 14 0 6 75 $wrap_dir/conv2_decay.mem] \
    [list 16 7 9 0 6 75 $saturate_dir/conv1_decay.mem] \
    [list 16 7 11 0 6 75 $saturate_dir/conv2_decay.mem] \
    [list 2 3 4 0 3 2 sim_1/new/lib/ref/neuron_update_B3_IV4_FV0_FA3_D2_T2_decay.mem] \
    [list 2 2 2 0 1 1 sim_1/new/lib/ref/neuron_update_B2_IV2_FV0_FA1_D1_T2_decay.mem] \
    [list 3 4 3 2 4 5 sim_1/new/lib/ref/neuron_update_B4_IV3_FV2_FA4_D5_T3_decay.mem] \
    [list 20 9 18 3 12 40 sim_1/new/lib/ref/neuron_update_B9_IV18_FV3_FA12_D40_T20_decay.mem] \
]

# Each parameter set is a base set followed by ROUND SATURATE SPIKE_OUTPUT
set param_sets {}
foreach base_set $base_sets {
    foreach round_enabled {0 1} {
        foreach saturate_enabled {0 1} {
            lappend param_sets [concat $base_set [list $round_enabled $saturate_enabled 1]]
            if {$round_enabled} {
                lappend param_sets [concat $base_set [list $round_enabled $saturate_enabled 0]]
            }
        }
    }
}

# NAME=value list of the integer parameters, shared by the generic and the summary line prefix
proc neuron_update_integer_params {param_set} {
    lassign $param_set time_width weight_width membrane_int_width membrane_frac_width decay_frac_width \
        decay_table_depth decay_file round_enabled saturate_enabled spike_output
    return "TIME_WIDTH=$time_width WEIGHT_WIDTH=$weight_width MEMBRANE_INT_WIDTH=$membrane_int_width MEMBRANE_FRAC_WIDTH=$membrane_frac_width DECAY_FRAC_WIDTH=$decay_frac_width DECAY_TABLE_DEPTH=$decay_table_depth ROUND=$round_enabled SATURATE=$saturate_enabled SPIKE_OUTPUT=$spike_output"
}

proc neuron_update_generic {param_set} {
    set decay_file [lindex $param_set 6]
    set srcs_dir [project_srcs_dir]
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

open_saltnet_project
create_simset_if_missing $simset_name tb_neuron_update {lib/tb_neuron_update.sv}

run_param_sets $simset_name tb_neuron_update sim_1/new/lib/ref $param_sets neuron_update_generic neuron_update_prefix
