# =============================================================================
# create_ila_dac.tcl — 创建 ila_dac IP (DAC 输出调试观测)
# =============================================================================
# probe0-15  : 128bit x16  (8 通道 x 8 样本 {I,Q})
# probe16    : 8bit        (8 路 TREADY)
# probe17    : 1bit        (nco_update_busy)
# probe18    : 48bit       (converter0_nco_freq)
# probe19    : 1bit        (nco_update_request)
# probe20    : 6bit        (控制/复位: user_sysref_dac,rst_bf,rst_bf_request,
#                           rst_tx,rst_bf_filt,vio_dds0_en)
# 深度 1024, 无触发输入
# 用法: vivado -mode batch -source scripts/create_ila_dac.tcl (在 vivado_sim 工程内)
# =============================================================================

cd C:/workbuddy_chat/tx_bf_4base

if {[catch {open_project vivado_sim/vivado_sim.xpr} res]} {
    puts "打开工程失败: $res"; exit 1
}

# 已存在则跳过
if {[llength [get_ips ila_dac]] > 0} {
    puts "ila_dac 已存在, 跳过创建"
} else {
    create_ip -name ila -vendor xilinx.com -library ip -version 6.2 -module_name ila_dac
    set_property -dict [list \
        CONFIG.C_DATA_DEPTH     {1024}      \
        CONFIG.C_NUM_OF_PROBES  {21}        \
        CONFIG.C_PROBE0_WIDTH   {128}       \
        CONFIG.C_PROBE1_WIDTH   {128}       \
        CONFIG.C_PROBE2_WIDTH   {128}       \
        CONFIG.C_PROBE3_WIDTH   {128}       \
        CONFIG.C_PROBE4_WIDTH   {128}       \
        CONFIG.C_PROBE5_WIDTH   {128}       \
        CONFIG.C_PROBE6_WIDTH   {128}       \
        CONFIG.C_PROBE7_WIDTH   {128}       \
        CONFIG.C_PROBE8_WIDTH   {128}       \
        CONFIG.C_PROBE9_WIDTH   {128}       \
        CONFIG.C_PROBE10_WIDTH  {128}       \
        CONFIG.C_PROBE11_WIDTH  {128}       \
        CONFIG.C_PROBE12_WIDTH  {128}       \
        CONFIG.C_PROBE13_WIDTH  {128}       \
        CONFIG.C_PROBE14_WIDTH  {128}       \
        CONFIG.C_PROBE15_WIDTH  {128}       \
        CONFIG.C_PROBE16_WIDTH  {8}         \
        CONFIG.C_PROBE17_WIDTH  {1}         \
        CONFIG.C_PROBE18_WIDTH  {48}        \
        CONFIG.C_PROBE19_WIDTH  {1}         \
        CONFIG.C_PROBE20_WIDTH  {6}         \
        CONFIG.C_TRIGIN_EN      {false}     \
    ] [get_ips ila_dac]
    puts "ila_dac 已创建 (21 probes, 深度 1024)"
}

generate_target all [get_ips ila_dac]
puts "=== ila_dac 生成完成 ==="
close_project
