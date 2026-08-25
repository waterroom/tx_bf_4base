# add_dds_core.tcl — 复制参考项目 dds_core IP (xcix) 到本工程并生成
open_project vivado_sim/vivado_sim.xpr
set dds_src "C:/prj/z669/ZU48_F1_V100_4P8G_sync_260729/ZU48_F1_V100.srcs/sources_1/ip/dds_core.xcix"
set dds_dst [file join [pwd] "vivado_sim" "vivado_sim.srcs" "sources_1" "ip" "dds_core.xcix"]
puts "=== 复制 dds_core.xcix ==="
file copy -force $dds_src $dds_dst
puts "  复制到: $dds_dst"
puts "=== 加入工程 ==="
add_files -norecurse $dds_dst
puts "=== 生成 IP ==="
if {[llength [get_ips dds_core]] > 0} {
    generate_target all [get_ips dds_core]
    puts "  dds_core 生成完成"
} else {
    puts "  WARNING: get_ips dds_core 未找到, 尝试全量"
    generate_target all [get_ips]
}
puts "=== 完成 ==="
