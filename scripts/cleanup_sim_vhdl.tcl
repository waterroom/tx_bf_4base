# cleanup_sim_vhdl.tcl — 清理 sim_1 里残留/重复的 VHDL (同名 IP 实体重复问题)
open_project vivado_sim/vivado_sim.xpr
set simset [get_filesets sim_1]
puts "=== sim_1 现有 VHDL 文件 ==="
set vhdls [get_files -of_objects $simset -filter {FILE_TYPE == VHDL}]
foreach f $vhdls {
    puts "  [file tail $f]  (from [file dirname $f])"
}
puts "=== 移除全部 VHDL (编译走 run_sim_vivado.tcl 手动 xvhdl) ==="
foreach f $vhdls {
    remove_files $f
    puts "  removed: [file tail $f]"
}
puts "=== 移除后 sim_1 剩余文件 ==="
foreach f [get_files -of_objects $simset] {
    puts "  [file tail $f]"
}
puts "=== 完成 ==="
