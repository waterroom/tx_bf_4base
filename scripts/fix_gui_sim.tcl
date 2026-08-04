# fix_gui_sim.tcl — 修复 GUI Run Simulation 的 aresetn 端口不匹配
# 问题: GUI 仿真编译 .gen 的 IP 模型 (无 aresetn), wrapper 例化 aresetn → VRFC 10-8333
# 修复: sim_1 用 sim_src 明文模型 (手工加了 aresetn), xci 排除仿真 (综合不受影响)
open_project vivado_sim/vivado_sim.xpr
set simset [get_filesets sim_1]

# 1. sim_1 添加 sim_src 明文 IP 模型 (带 aresetn)
puts "=== 添加 sim_src IP 模型到 sim_1 ==="
set src_dir [file join [file dirname [file normalize [info script]]] ".." "sim_src"]
add_files -norecurse -fileset $simset [list \
    [file join $src_dir fir_300to600_87p5pass_hf.vhd] \
    [file join $src_dir fir_600to1200_87p5pass_hf.vhd] \
    [file join $src_dir fir_1200to2400_87p5pass_hf.vhd]]
foreach n {fir_300to600_87p5pass_hf.vhd fir_600to1200_87p5pass_hf.vhd fir_1200to2400_87p5pass_hf.vhd} {
    set_property library xil_defaultlib [get_files -of_objects $simset $n]
}

# 2. xci 排除仿真 (GUI 仿真不编译 .gen 模型, 避免与 sim_src 同名重复)
puts "=== xci 排除仿真 ==="
foreach f [get_files -filter {FILE_TYPE == "IP"} -of_objects [get_filesets sources_1]] {
    set_property used_in_simulation false $f
    puts "  [file tail $f] used_in_sim=false"
}

# 3. 确认 xelab 链接预编译库 (若未设置则补)
set cur [get_property xsim.elaborate.xelab.more_options $simset]
if {[string first "fir_compiler_v7_2_18" $cur] < 0} {
    set_property -dict [list xsim.elaborate.xelab.more_options {-L fir_compiler_v7_2_18 -L xbip_utils_v3_0_10 -L axi_utils_v2_0_6}] $simset
    puts "  xelab more_options 已设置"
} else {
    puts "  xelab more_options 已存在: $cur"
}

puts "=== 完成: GUI Run Behavioral Simulation 现在会编译 sim_src 模型 (带 aresetn) ==="
