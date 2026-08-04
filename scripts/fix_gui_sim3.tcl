# fix_gui_sim3.tcl — 按文件名匹配排除全部 xci 参与仿真
open_project vivado_sim/vivado_sim.xpr
foreach f [get_files -of_objects [get_filesets sources_1]] {
    if {[string match "*.xci" $f]} {
        set_property used_in_simulation false $f
        puts "excluded: [file tail $f]"
    }
}
puts "=== 完成 ==="
