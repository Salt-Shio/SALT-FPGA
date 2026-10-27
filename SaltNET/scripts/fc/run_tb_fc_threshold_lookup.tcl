# Run tb_fc_threshold_lookup once per parameter set, using simulation set sim_fc_threshold_lookup of the SaltNET project.
# Generate the reference files first (WSL): gen_fc_threshold_lookup_ref.py.
# The parameter list below must match SYNTHETIC_SETS in that script; READ_LATENCY does not change the reference.
# Every set uses the threshold file written by gen_fc_threshold_lookup_ref.py (sim_1/new/fc/ref/): the trained FC layer
# does not fire and has no thresholds, so all sets are synthetic.
# The first run creates the simulation set (sim_common.tcl registers all RTL in sources_1); later runs skip that.
# Compile runs once; each parameter set changes the simset generic, then elaborates and simulates.
# Usage:
#   PowerShell (batch mode, close the GUI first):
#       cd D:\Project\SALT-FPGA\SaltNET\SaltNET.sim
#       vivado -mode batch -source D:/Project/SALT-FPGA/SaltNET/scripts/fc/run_tb_fc_threshold_lookup.tcl
#   Do not source this from the GUI Tcl console: there the repeated elaborate steps intermittently fail with
#   'Spawn failed' (cause unknown, see the vivado-usage skill, section 8.7). Use the GUI only for a single
#   Run Simulation with the testbench defaults.
#   (Vivado writes vivado.log/.jou and crash dumps to the launch directory; start it inside SaltNET.sim.)
# Outputs go to SaltNET.sim/sim_fc_threshold_lookup/behav/xsim; each set is judged from simulate.log right after it runs.
# This file is ASCII only: Vivado reads Tcl sources in the system code page, not UTF-8.

set scripts_dir [file dirname [file normalize [info script]]]
source [file join $scripts_dir .. sim_common.tcl]

set simset_name sim_fc_threshold_lookup

# OUT_NEURONS NEURONS_PER_ROW MEMBRANE_WIDTH READ_LATENCY
set param_sets {
    {10 4 14 1}
    {10 4 11 2}
    {10 3 9 2}
    {5 1 7 1}
    {3 4 6 1}
    {1 1 4 2}
}

# NAME=value list of the integer parameters, shared by the generic and the summary line prefix
proc fc_threshold_lookup_integer_params {param_set} {
    lassign $param_set out_neurons neurons_per_row membrane_width read_latency
    return "OUT_NEURONS=$out_neurons NEURONS_PER_ROW=$neurons_per_row MEMBRANE_WIDTH=$membrane_width READ_LATENCY=$read_latency"
}

# Threshold file name rule: same as ref_file_stem in gen_fc_threshold_lookup_ref.py
proc fc_threshold_lookup_generic {param_set} {
    lassign $param_set out_neurons neurons_per_row membrane_width
    set threshold_path [file join [project_srcs_dir] sim_1 new fc ref \
        fc_threshold_lookup_OUT${out_neurons}_COL${neurons_per_row}_W${membrane_width}_threshold.mem]
    if {![file exists $threshold_path]} {
        error "threshold file not found: $threshold_path"
    }
    return "[fc_threshold_lookup_integer_params $param_set] THRESHOLD_FILE=\"$threshold_path\""
}

# tb_fc_threshold_lookup prints the integer parameters as NAME=value, followed by a colon
proc fc_threshold_lookup_prefix {param_set} {
    return "[fc_threshold_lookup_integer_params $param_set]:"
}

open_saltnet_project
create_simset_if_missing $simset_name tb_fc_threshold_lookup {fc/tb_fc_threshold_lookup.sv}

run_param_sets $simset_name tb_fc_threshold_lookup sim_1/new/fc/ref $param_sets fc_threshold_lookup_generic fc_threshold_lookup_prefix
