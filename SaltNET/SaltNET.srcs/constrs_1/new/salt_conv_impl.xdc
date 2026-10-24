# SaltConv implementation-only constraints (read after synth_design; in a project, set USED_IN_SYNTHESIS false).
# This file is ASCII only: Vivado reads Tcl/XDC sources in the system code page, not UTF-8.
#
# Keep place_design's Physical Synthesis In Placer (DSP Register optimization) from moving the cut register
# (NeuronUpdate, COMPUTE_LATENCY = 2, merged into the DSP PREG) out of the multiply DSP.
# Measured 2026-10-21, SaltConvNet saturate, 4.8 ns, same RTL and flow (docs/SNN/Todo Part 9):
#   default: the placer pushed 9 PREG registers of one conv1 DSP out to slice FFs during global placement;
#            that bank's stage-1 path (into the cut register) became the worst path, routed WNS +0.028 ns.
#   DONT_TOUCH on the DSPs: nothing else in the PSIP summary changed except one BRAM register move;
#            routed WNS +0.136 ns.
# Only these DSPs are protected: register moves between BRAMs and slices are left to the tool.
# The pattern has no '/' before neuron_update: generate block names are joined with '.'
# (e.g. conv1/row_banks[0].col_banks[0].neuron_update/rounded_product), so '*/neuron_update' matches nothing.
set_property DONT_TOUCH true [get_cells -hierarchical -filter {REF_NAME == DSP48E2 && NAME =~ *neuron_update/rounded_product}]
