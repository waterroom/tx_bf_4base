# refresh_ip_aresetn.tcl — refresh IP 定义后强制重新生成 (aresetn 生效)
open_project vivado_sim/vivado_sim.xpr
puts "=== refresh IP (重新加载 xci 定义) ==="
refresh_ip [get_ips]
puts "=== reset_target ==="
reset_target all [get_ips]
puts "=== generate_target ==="
generate_target all [get_ips]
# 复制新 sim 模型到 sim_src
foreach n {fir_300to600_87p5pass_hf fir_600to1200_87p5pass_hf fir_1200to2400_87p5pass_hf} {
    set src [file join [pwd] "vivado_sim" "vivado_sim.gen" "sources_1" "ip" $n "sim" "$n.vhd"]
    set dst [file join [pwd] "sim_src" "$n.vhd"]
    file copy -force $src $dst
    puts "  sim_src/$n.vhd 已更新"
}
puts "=== 完成 ==="
