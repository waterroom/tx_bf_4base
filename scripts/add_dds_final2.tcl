# add_dds_final2.tcl — 清理残留引用 + 添加 dds_core.xci + 升级器件 + 生成
open_project vivado_sim/vivado_sim.xpr
puts "=== 清理 dds_core 旧引用 (xcix) ==="
foreach f [get_files -filter {NAME =~ *dds_core*}] {
    puts "  remove: [file tail $f]"
    remove_files $f
}
puts "=== 清理 sim_1 fir_sim_models 残留 ==="
foreach f [get_files -of_objects [get_filesets sim_1] -filter {NAME =~ *fir_sim_models*}] {
    puts "  remove: [file tail $f]"
    remove_files $f
}
puts "=== 添加 dds_core.xci ==="
set xci [file join [pwd] "vivado_sim" "vivado_sim.srcs" "sources_1" "ip" "dds_core" "dds_core.xci"]
add_files -norecurse $xci
update_compile_order -fileset sources_1
puts "=== upgrade_ip (器件 fsvg-2-i -> ffvg-2-e) ==="
upgrade_ip [get_ips dds_core]
puts "=== generate_target ==="
generate_target all [get_ips dds_core]
puts "=== 产物验证 ==="
set gen [file join [pwd] "vivado_sim" "vivado_sim.gen" "sources_1" "ip" "dds_core"]
foreach t {synth sim} {
    puts "  $t: [file exists [file join $gen $t]]"
}
puts "=== 完成 ==="
