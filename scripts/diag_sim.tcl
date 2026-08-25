# diag_sim.tcl — 诊断 sim_1 fileset 中 VHDL 文件属性
open_project vivado_sim/vivado_sim.xpr
set simset [get_filesets sim_1]
puts "=== sim_1 中 VHDL 文件 ==="
foreach f [get_files -of_objects $simset -filter {FILE_TYPE == VHDL}] {
    puts "[file tail $f] : used_in_sim=[get_property used_in_simulation $f] lib=[get_property library $f]"
}
puts "=== sim_1 中 SV 文件 ==="
foreach f [get_files -of_objects $simset -filter {FILE_TYPE == "SystemVerilog"}] {
    puts "[file tail $f] : used_in_sim=[get_property used_in_simulation $f]"
}
puts "=== sim_1 全部文件数: [llength [get_files -of_objects $simset]] ==="
puts "=== compile step 属性 ==="
puts "xvlog more: [get_property xsim.compile.xvlog.more_options $simset]"
puts "xelab more: [get_property xsim.elaborate.xelab.more_options $simset]"
