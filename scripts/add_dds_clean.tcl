# add_dds_clean.tcl — 添加 dds_core.xci (工程已清理) + 升级器件 + 生成
open_project vivado_sim/vivado_sim.xpr
puts "=== 添加 dds_core.xci ==="
set xci [file join [pwd] "vivado_sim" "vivado_sim.srcs" "sources_1" "ip" "dds_core" "dds_core.xci"]
add_files -norecurse $xci
update_compile_order -fileset sources_1
puts "=== upgrade_ip ==="
upgrade_ip [get_ips dds_core]
puts "=== generate_target ==="
generate_target all [get_ips dds_core]
puts "=== 产物验证 ==="
set gen [file join [pwd] "vivado_sim" "vivado_sim.gen" "sources_1" "ip" "dds_core"]
foreach t {synth sim} {
    puts "  $t: [file exists [file join $gen $t]]"
}
puts "=== 完成 ==="
