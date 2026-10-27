# Run tb_fc_weight_lookup once per parameter set, using simulation set sim_fc_weight_lookup of the SaltNET project.
# Generate the reference files first (WSL): gen_fc_weight_lookup_ref.py.
# The parameter list below must match TRAINED_LAYERS and SYNTHETIC_SETS in that script; READ_LATENCY does not change
# the reference, so one reference file serves several READ_LATENCY values.
# Every set, trained or synthetic, uses the weight file written by gen_fc_weight_lookup_ref.py (sim_1/new/fc/ref/):
# the trained FC weights depend on n_col, which is not chosen yet, so they are not in sources_1/mem/.
# The first run creates the simulation set (sim_common.tcl registers all RTL in sources_1); later runs skip that.
# Compile runs once; each parameter set changes the simset generic, then elaborates and simulates.
# Usage:
#   PowerShell (batch mode, close the GUI first):
#       cd D:\Project\SALT-FPGA\SaltNET\SaltNET.sim
#       vivado -mode batch -source D:/Project/SALT-FPGA/SaltNET/scripts/fc/run_tb_fc_weight_lookup.tcl
#   Do not source this from the GUI Tcl console: there the repeated elaborate steps intermittently fail with
#   'Spawn failed' (cause unknown, see the vivado-usage skill, section 8.7). Use the GUI only for a single
#   Run Simulation with the testbench defaults.
#   (Vivado writes vivado.log/.jou and crash dumps to the launch directory; start it inside SaltNET.sim.)
# Outputs go to SaltNET.sim/sim_fc_weight_lookup/behav/xsim; each set is judged from simulate.log right after it runs.
# This file is ASCII only: Vivado reads Tcl sources in the system code page, not UTF-8.

set scripts_dir [file dirname [file normalize [info script]]]
source [file join $scripts_dir .. sim_common.tcl]

set simset_name sim_fc_weight_lookup

# IN_NEURONS OUT_NEURONS NEURONS_PER_ROW WEIGHT_WIDTH READ_LATENCY
set param_sets {
    {1296 10 4 7 1}
    {1296 10 4 7 2}
    {7 5 1 7 1}
    {7 10 3 9 2}
    {5 3 4 4 1}
    {1 1 1 4 2}
}

# NAME=value list of the integer parameters, shared by the generic and the summary line prefix
proc fc_weight_lookup_integer_params {param_set} {
    lassign $param_set in_neurons out_neurons neurons_per_row weight_width read_latency
    return "IN_NEURONS=$in_neurons OUT_NEURONS=$out_neurons NEURONS_PER_ROW=$neurons_per_row WEIGHT_WIDTH=$weight_width READ_LATENCY=$read_latency"
}

# Weight file name rule: same as ref_file_stem in gen_fc_weight_lookup_ref.py
proc fc_weight_lookup_generic {param_set} {
    lassign $param_set in_neurons out_neurons neurons_per_row weight_width
    set weight_path [file join [project_srcs_dir] sim_1 new fc ref \
        fc_weight_lookup_IN${in_neurons}_OUT${out_neurons}_COL${neurons_per_row}_B${weight_width}_weight.mem]
    if {![file exists $weight_path]} {
        error "weight file not found: $weight_path"
    }
    return "[fc_weight_lookup_integer_params $param_set] WEIGHT_FILE=\"$weight_path\""
}

# tb_fc_weight_lookup prints the integer parameters as NAME=value, followed by a colon
proc fc_weight_lookup_prefix {param_set} {
    return "[fc_weight_lookup_integer_params $param_set]:"
}

open_saltnet_project
create_simset_if_missing $simset_name tb_fc_weight_lookup {fc/tb_fc_weight_lookup.sv}

run_param_sets $simset_name tb_fc_weight_lookup sim_1/new/fc/ref $param_sets fc_weight_lookup_generic fc_weight_lookup_prefix
