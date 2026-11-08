# Run tb_salt_fc_no_spike once per parameter set, using simulation set sim_salt_fc_no_spike of the SaltNET project.
# Generate the reference files first (WSL): gen_salt_fc_ref.py (also writes the weight and decay files next to them).
# The parameter list below must match TRAINED_SETS and the SPIKE_OUTPUT = 0 entries of SYNTHETIC_SETS in that script.
# The layer with spikes (SPIKE_OUTPUT = 1) is run by run_tb_salt_fc.tcl.
# The first run creates the simulation set (sim_common.tcl registers all RTL in sources_1); later runs skip that.
# Compile runs once; each parameter set changes the simset generic, then elaborates and simulates.
# Usage:
#   PowerShell (batch mode, close the GUI first):
#       cd D:\Project\SALT-FPGA\SaltNET\SaltNET.sim
#       vivado -mode batch -source D:/Project/SALT-FPGA/SaltNET/scripts/fc/run_tb_salt_fc_no_spike.tcl
#   Do not source this from the GUI Tcl console: there the repeated elaborate steps intermittently fail with
#   'Spawn failed' (cause unknown, see the vivado-usage skill, section 8.7). Use the GUI only for a single
#   Run Simulation with the testbench defaults.
#   (Vivado writes vivado.log/.jou and crash dumps to the launch directory; start it inside SaltNET.sim.)
# Outputs go to SaltNET.sim/sim_salt_fc_no_spike/behav/xsim; each set is judged from simulate.log right after it runs.
# This file is ASCII only: Vivado reads Tcl sources in the system code page, not UTF-8.

set scripts_dir [file dirname [file normalize [info script]]]
source [file join $scripts_dir .. sim_common.tcl]

set simset_name sim_salt_fc_no_spike
set ref_dir sim_1/new/fc/ref

# IN_NEURONS OUT_NEURONS NEURONS_PER_ROW TIME_WIDTH WEIGHT_WIDTH MEMBRANE_INT_WIDTH MEMBRANE_FRAC_WIDTH
# DECAY_FRAC_WIDTH DECAY_TABLE_DEPTH ROUND SATURATE FIFO_DEPTH.
# READ_LATENCY, COMPUTE_LATENCY, OVERLAP, MEMBRANE_OUTPUT are added below.
set base_param_sets {
    {1296 10 4 16 7 14 0 6 75 1 0 16}
    {1296 10 10 16 7 14 0 6 75 1 0 16}
    {1296 10 4 16 7 11 0 6 75 1 1 16}
    {1296 10 10 16 7 11 0 6 75 1 1 16}
    {7 10 3 11 5 6 0 4 10 1 0 4}
    {7 10 4 12 6 7 2 5 20 0 1 16}
    {5 3 4 10 4 5 0 3 4 1 1 2}
    {7 5 1 12 7 8 0 6 12 0 0 16}
    {1 1 1 9 4 4 0 3 3 1 1 4}
}

# Each set above runs once per {READ_LATENCY COMPUTE_LATENCY OVERLAP} below. They only change the cycle count;
# the reference files list the cycle count for every entry of CYCLE_CONFIGS in gen_salt_conv_ref.py (R, C in 1..2).
# OVERLAP only matters when R + C > 2, so {1 1 1} is not listed.
# MEMBRANE_OUTPUT = 1 for all of them; every set runs once more with MEMBRANE_OUTPUT = 0 and {2 2 1}:
# membrane_valid must stay 0 and nothing else changes.
set pipeline_configs {{1 1 0} {2 1 0} {2 1 1} {1 2 0} {1 2 1} {2 2 0} {2 2 1}}
set param_sets {}
foreach base_set $base_param_sets {
    foreach pipeline_config $pipeline_configs {
        lappend param_sets [concat $base_set $pipeline_config 1]
    }
}
foreach base_set $base_param_sets {
    lappend param_sets [concat $base_set {2 2 1} 0]
}

# NAME=value list of the integer parameters, shared by the generic and the summary line prefix
proc salt_fc_integer_params {param_set} {
    lassign $param_set in_neurons out_neurons neurons_per_row time_width weight_width membrane_int_width \
        membrane_frac_width decay_frac_width decay_table_depth round saturate fifo_depth read_latency \
        compute_latency overlap membrane_output
    return "IN_NEURONS=$in_neurons OUT_NEURONS=$out_neurons NEURONS_PER_ROW=$neurons_per_row TIME_WIDTH=$time_width WEIGHT_WIDTH=$weight_width MEMBRANE_INT_WIDTH=$membrane_int_width MEMBRANE_FRAC_WIDTH=$membrane_frac_width DECAY_FRAC_WIDTH=$decay_frac_width DECAY_TABLE_DEPTH=$decay_table_depth ROUND=$round SATURATE=$saturate FIFO_DEPTH=$fifo_depth READ_LATENCY=$read_latency COMPUTE_LATENCY=$compute_latency OVERLAP=$overlap MEMBRANE_OUTPUT=$membrane_output"
}

# Data file name rule: same as ParamSet.stem in gen_salt_fc_ref.py (SPIKE_OUTPUT = 0)
proc salt_fc_generic {param_set} {
    lassign $param_set in_neurons out_neurons neurons_per_row time_width weight_width membrane_int_width \
        membrane_frac_width decay_frac_width decay_table_depth round saturate
    set stem salt_fc_IN${in_neurons}_OUT${out_neurons}_COL${neurons_per_row}_IV${membrane_int_width}_FV${membrane_frac_width}_RD${round}_SAT${saturate}_SPK0
    set generic [salt_fc_integer_params $param_set]
    foreach {name suffix} {WEIGHT_FILE _weight.mem DECAY_FILE _decay.mem} {
        set path [file join [project_srcs_dir] $::ref_dir $stem$suffix]
        if {![file exists $path]} {
            error "data file not found: $path"
        }
        append generic " $name=\"$path\""
    }
    return $generic
}

# tb_salt_fc_no_spike prints the integer parameters as NAME=value, followed by a colon
proc salt_fc_prefix {param_set} {
    return "[salt_fc_integer_params $param_set]:"
}

open_saltnet_project
create_simset_if_missing $simset_name tb_salt_fc_no_spike {fc/tb_salt_fc_no_spike.sv fc/tb_salt_fc_update_lines.svh
    fc/tb_salt_fc_membrane_check.svh}

run_param_sets $simset_name tb_salt_fc_no_spike $ref_dir $param_sets salt_fc_generic salt_fc_prefix
