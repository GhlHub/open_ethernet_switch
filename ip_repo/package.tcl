# Generate a relocatable Vivado IP catalog from the checked-in manifests.
# vivado -mode batch -source ip_repo/package.tcl -tclargs [output-directory]
if {[catch {
set root [file dirname [file dirname [file normalize [info script]]]]
set out [file normalize [expr {[llength $argv] ? [lindex $argv 0] : "$root/build/ip_catalog"}]]
file mkdir $out
foreach name {gem_port pl_port sfp_port switch_fabric management} {
    set dest $out/$name
    if {[file exists $dest/component.xml]} {error "Catalog already exists: $dest; use a fresh output directory"}
    create_project -force package_$name $out/.projects/$name -part xck26-sfvc784-2LV-c
    set_property target_language Verilog [current_project]
    set_property XPM_LIBRARIES {XPM_MEMORY XPM_CDC} [current_project]
    set paths [split [exec python3 $root/scripts/ip_sources.py --core $name] "\n"]
    # Staged copies are build output, not additional editable source copies.
    set staged {}
    foreach src $paths {
        set rel [string range $src [expr {[string length $root]+1}] end]
        file mkdir [file dirname $dest/$rel]
        file copy -force $src $dest/$rel
        lappend staged $dest/$rel
    }
    add_files -norecurse $staged
    set top [exec python3 -c {import json,sys; print(json.load(open(sys.argv[1]))['top'])} $root/ip_repo/$name/manifest.json]
    set_property top $top [current_fileset]
    update_compile_order -fileset sources_1
    ipx::package_project -root_dir $dest -vendor ghlhub.org -library ethernet -taxonomy /Networking -import_files -set_current true
    set core [ipx::current_core]
    set_property name $name $core
    set_property version 1.0 $core
    set_property display_name "Open Ethernet Switch: $name" $core
    set_property description [exec python3 -c {import json,sys; print(json.load(open(sys.argv[1]))['description'])} $root/ip_repo/$name/manifest.json] $core
    set_property supported_families {zynquplus Production} $core
    if {$name eq "switch_fabric"} {
        # Vivado's HDL parser promotes these imported package constants into
        # nonexistent module parameters. The interface geometry is fixed by
        # the packages, not configurable through the IP GUI. Preserve the
        # elaborated widths and remove the invalid parameter overrides.
        foreach port [ipx::get_ports -of_objects $core] {
            foreach side {left right} {
                set dep [get_property SIZE_[string toupper $side]_DEPENDENCY $port]
                if {[regexp {MODELPARAM_VALUE\.(PORT_ID_W|BUF_ID_W|LENGTH_W)} $dep]} {
                    set_property SIZE_[string toupper $side]_RESOLVE_TYPE immediate $port
                    set_property SIZE_[string toupper $side]_DEPENDENCY {} $port
                }
            }
        }
        foreach constant {PORT_ID_W BUF_ID_W LENGTH_W} {
            ipx::remove_hdl_parameter $constant $core
            ipx::remove_user_parameter $constant $core
        }
    }
    # Inferred buses are associated with their actual clocks, not a guessed
    # common domain. Scalar GEM FIFO and snapshot-mailbox ports remain explicit.
    foreach busif [ipx::get_bus_interfaces -of_objects $core] {
        set assoc [ipx::get_bus_parameters ASSOCIATED_BUSIF -of_objects $busif]
        if {[llength $assoc]} {ipx::remove_bus_parameter ASSOCIATED_BUSIF $busif}
    }
    set clock_lines [split [exec python3 -c {import json,sys; c=json.load(open(sys.argv[1])); print('\n'.join(k+' '+':'.join(v) for k,v in c['clocks'].items()))} $root/ip_repo/$name/manifest.json] "\n"]
    foreach line $clock_lines {
        set clock [lindex $line 0]
        set buses [lindex $line 1]
        foreach bus [split $buses :] {
            if {$bus eq ""} {continue}
            if {[llength [ipx::get_bus_interfaces $bus -of_objects $core]] != 1} {
                error "Missing inferred bus $name/$bus"
            }
            ipx::associate_bus_interfaces -busif $bus -clock $clock $core
        }
    }
    set clock_if [ipx::get_bus_interfaces clk -of_objects $core]
    set reset_param [ipx::get_bus_parameters ASSOCIATED_RESET -of_objects $clock_if]
    if {![llength $reset_param]} {set reset_param [ipx::add_bus_parameter ASSOCIATED_RESET $clock_if]}
    set_property value rst_n $reset_param
    ipx::create_xgui_files $core
    ipx::update_checksums $core
    ipx::check_integrity $core
    ipx::save_core $core
    close_project
}
puts "IP catalog created at $out"
} message options]} {
    puts stderr [dict get $options -errorinfo]
    exit 1
}
