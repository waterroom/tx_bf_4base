# =============================================================================
# create_vio_dac.tcl — 创建 vio_dac IP (模拟基带源控制)
# =============================================================================
# probe_out0[31:0] = DDS 频率字 (up_dds0_incr)
# probe_out1[0:0]  = 模拟基带使能 (vio_dds0_en)
# 用法: vivado -mode batch -source scripts/create_vio_dac.tcl (在 vivado_sim 工程内)
# =============================================================================

cd C:/workbuddy_chat/tx_bf_4base

if {[catch {open_project vivado_sim/vivado_sim.xpr} res]} {
    puts "打开工程失败: $res"; exit 1
}

# 已存在则跳过
if {[llength [get_ips vio_dac]] > 0} {
    puts "vio_dac 已存在, 跳过创建"
} else {
    create_ip -name vio -vendor xilinx.com -library ip -version 3.0 -module_name vio_dac
    set_property -dict [list \
        CONFIG.C_PROBE_IN0_WIDTH  {1}  \
        CONFIG.C_PROBE_OUT0_WIDTH {32} \
        CONFIG.C_PROBE_OUT1_WIDTH {1}  \
    ] [get_ips vio_dac]
    puts "vio_dac 已创建 (out0=32bit 频率字, out1=1bit 使能)"
}

generate_target all [get_ips vio_dac]
puts "=== vio_dac 生成完成 ==="
close_project
