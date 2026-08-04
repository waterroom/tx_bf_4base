# fix_gui_sim2.tcl — 排除全部 IP xci 参与仿真
open_project vivado_sim/vivado_sim.xpr
foreach f [get_files -of_objects [get_filesets sources_1] -filter {FILE_TYPE == "IP Sources"}] {
    set_property used_in_simulation false $f
    puts "excluded: [file tail $f]"
}
puts "=== 完成 ==="
