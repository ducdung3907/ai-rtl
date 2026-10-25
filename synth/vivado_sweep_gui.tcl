# Vivado sweep for your EXISTING project (project mode, run from the GUI).
#
# Uses the project's own runs (synth_1 / impl_1) and settings: part, out-of-context
# synthesis, timing.xdc, strategies. For each MAC_LAT and N it sets the generics,
# re-runs synthesis + implementation, and appends one CSV row.
#
# How to run:
#   1. Open your project in Vivado (e.g. C:/work/vivado/sa_vivado/sa_vivado.xpr).
#   2. Edit the three settings below if needed.
#   3. In the Tcl Console:  source C:/work/ai-rtl/synth/vivado_sweep_gui.tcl
#   The GUI is busy until the sweep finishes; progress is printed in the console.
#
# Results: <out_dir>/results_vivado_mac1.csv and results_vivado_mac2.csv
# Reports: <project dir>/sweep_reports/mac<L>_N<N>_{utilization,timing,power}.rpt
# Max clock = 1000 / (period - WNS) MHz. Power is Vivado's vectorless estimate.

# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------
set sizes   {2 4 8 12 15 16}        ;# array sizes to run
set lats    {2}                     ;# MAC versions: 1 = single-cycle, 2 = pipelined
set out_dir C:/work/ai-rtl/synth    ;# where the CSV files go (your repo's synth folder)
set period  5.0                     ;# must match create_clock in timing.xdc
set jobs    8                       ;# parallel jobs for the runs

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
# First number in the report-table row whose label matches, e.g.
# "| Slice LUTs | 2098 | ..." -> 2098. Returns "?" if the row is missing.
proc table_value {report label} {
    if {[regexp -line "^\\|\\s*${label}\\*?\\s*\\|\\s*(\[0-9.\]+)" $report -> v]} {
        return $v
    }
    return "?"
}

proc csv_append {file line} {
    set f [open $file a]
    puts $f $line
    close $f
}

set rpt_dir [file join [get_property DIRECTORY [current_project]] sweep_reports]
file mkdir $rpt_dir
file mkdir $out_dir

# ---------------------------------------------------------------------------
# Sweep
# ---------------------------------------------------------------------------
foreach L $lats {
    set csv [file join $out_dir results_vivado_mac$L.csv]
    if {![file exists $csv]} {
        csv_append $csv "mac_lat,N,PEs,luts,lutram,ffs,dsps,wns_ns,fmax_mhz,power_w,status"
    }

    foreach N $sizes {
        set tag   "mac${L}_N${N}"
        set start [clock seconds]
        puts "\n=== MAC_LAT=$L  N=$N  ([clock format $start -format %H:%M:%S]) ==="

        catch {close_design}
        set_property generic "N=$N MAC_LAT=$L" [current_fileset]
        reset_run synth_1
        launch_runs impl_1 -jobs $jobs
        wait_on_run impl_1

        set status [get_property STATUS [get_runs impl_1]]
        if {![string match "*route_design Complete*" $status]} {
            puts "FAILED: $status"
            csv_append $csv "$L,$N,[expr {$N*$N}],,,,,,,,failed: $status"
            continue
        }

        open_run impl_1
        set util [report_utilization -return_string]
        set pwr  [report_power -return_string]
        report_utilization    -file [file join $rpt_dir ${tag}_utilization.rpt]
        report_timing_summary -file [file join $rpt_dir ${tag}_timing.rpt]
        report_power          -file [file join $rpt_dir ${tag}_power.rpt]

        set luts   [table_value $util "Slice LUTs"]
        set lutram [table_value $util "LUT as Memory"]
        set ffs    [table_value $util "Slice Registers"]
        set dsps   [table_value $util "DSPs"]
        set power  "?"
        regexp {Total On-Chip Power \(W\)\s*\|\s*([0-9.]+)} $pwr -> power

        set wns  [get_property SLACK [get_timing_paths -setup -max_paths 1 -nworst 1]]
        set fmax [format %.1f [expr {1000.0 / ($period - $wns)}]]

        csv_append $csv "$L,$N,[expr {$N*$N}],$luts,$lutram,$ffs,$dsps,$wns,$fmax,$power,ok"
        puts [format "MAC_LAT=%s N=%-3s LUTs=%-6s LUTRAM=%-4s FFs=%-6s DSPs=%-4s WNS=%s ns  fmax=%s MHz  power=%s W  (%d s)" \
                  $L $N $luts $lutram $ffs $dsps $wns $fmax $power [expr {[clock seconds] - $start}]]
        close_design
    }
    puts "\nSaved $csv"
}