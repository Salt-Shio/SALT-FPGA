# Read quant_versions.txt (the same file the Python reference scripts read): which quantized model the tests use.
# Sourced by sim_common.tcl and the synth_*.tcl scripts; not meant to be run on its own.
# This file is ASCII only: Vivado reads Tcl sources in the system code page, not UTF-8.

set ::quant_versions_path [file normalize [file join [file dirname [info script]] quant_versions.txt]]

# Value of one entry (quant_run_dir, wrap, saturate); errors if the file is malformed or the entry is missing
proc quant_version {name} {
    set config_fd [open $::quant_versions_path r]
    set config_text [read $config_fd]
    close $config_fd
    set entries [dict create]
    set line_number 0
    foreach line [split $config_text "\n"] {
        incr line_number
        set fields [regexp -all -inline {\S+} [lindex [split $line "#"] 0]]
        if {[llength $fields] == 0} {
            continue
        }
        if {[llength $fields] != 2 || [lsearch -exact {quant_run_dir wrap saturate} [lindex $fields 0]] < 0
            || [dict exists $entries [lindex $fields 0]]} {
            error "$::quant_versions_path line $line_number is malformed: $line"
        }
        dict set entries [lindex $fields 0] [lindex $fields 1]
    }
    if {![dict exists $entries $name]} {
        error "$::quant_versions_path has no entry '$name'"
    }
    return [dict get $entries $name]
}

# Directory of the exported .mem files of one model (wrap or saturate), relative to <project>.srcs
proc quant_mem_dir {name} {
    return sources_1/mem/[quant_version $name]
}
