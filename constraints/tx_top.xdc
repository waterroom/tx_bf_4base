# =============================================================================
# tx_top.xdc  --  时序约束 (da_data_gen 顶层, ZU48DR RFSoC)
# =============================================================================
# 顶层 da_data_gen 端口: dac_coreclk / cmd_clk / rst_dac / rst_cmd / rst_bf /
#   cmd_data[63:0]+valid / bb_i/bb_q[63:0]+bb_valid[3:0] /
#   rst_bf_request / sXX_axis_0_tdata[255:0]+tready
# 引脚分配按实际 PCB 填写 (见文件尾模板)。
# =============================================================================

# ---------- 1. 主时钟 ----------
# 数据路径时钟 300MHz (dac_coreclk)
create_clock -period 3.333 -name dac_coreclk [get_ports dac_coreclk]
# 配置报文时钟 (cmd_clk, 一般 10-20MHz; 按实际调整)
create_clock -period 10.0  -name cmd_clk     [get_ports cmd_clk]

# ---------- 2. 异步复位: false_path ----------
set_false_path -from [get_ports rst_dac]
set_false_path -from [get_ports rst_cmd]
set_false_path -from [get_ports rst_bf]

# ---------- 3. 异步时钟域 (cmd_clk ⇄ dac_coreclk, CDC FIFO 处理) ----------
set_clock_groups -asynchronous \
    -group [get_clocks dac_coreclk] \
    -group [get_clocks cmd_clk]
set_false_path -from [get_clocks cmd_clk]     -to [get_clocks dac_coreclk]
set_false_path -from [get_clocks dac_coreclk] -to [get_clocks cmd_clk]

# ---------- 4. 配置寄存器 (静态配置, false_path) ----------
# decode_cmd_tx_bf 内实际寄存器名: delay_val/delay_val_temp/phase_inc/phase_offset/
# wre_reg/wim_reg/fir_coef 等, 只在 apply 时更新, 不参与数据路径时序收敛
set_false_path -to [get_cells -hier -filter {NAME =~ *u_decode*delay_val*}]
set_false_path -to [get_cells -hier -filter {NAME =~ *u_decode*phase_inc*}]
set_false_path -to [get_cells -hier -filter {NAME =~ *u_decode*phase_offset*}]
set_false_path -to [get_cells -hier -filter {NAME =~ *u_decode*wre_reg*}]
set_false_path -to [get_cells -hier -filter {NAME =~ *u_decode*wim_reg*}]
set_false_path -to [get_cells -hier -filter {NAME =~ *u_decode*fir_coef*}]

# ---------- 5. 复位树扇出限制 ----------
# 数据路径复位 rst_tx 高扇出 (~8 万 FF): MAX_FANOUT 对复位引脚无效
# (Vivado 只对组合逻辑复制, 复位默认不复制) — 改用 BUFG 全局网络分发:
# 复位信号走全局时钟网络, 到达全片 FF 时序均衡, 扇出不再是布线问题
# (UG949 高扇出复位推荐做法; 同步复位 64 拍脉冲, BUFG ~1-2ns 延迟裕量大)
set_property MAX_FANOUT 512 [get_nets -hier -filter {NAME =~ *rst_tx*}]
set_property CLOCK_BUFFER_TYPE BUFG [get_nets -hier -filter {NAME =~ *rst_tx*}]

# ---------- 7. 输入输出延时 (按实际来源/去向约束) ----------
# 基带输入: 外部提供 4 路基带 (300MHz), 按实际时序
# set_input_delay  -clock dac_coreclk -max 1.5 [get_ports {bb_i bb_q bb_valid}]
# 配置报文输入 (cmd_clk 域)
# set_input_delay  -clock cmd_clk -max 3.0 [get_ports {cmd_data cmd_data_valid}]
# DAC 输出 (8 路 AXI-Stream TDATA, 300MHz)
# set_output_delay -clock dac_coreclk -max 1.5 [get_ports {s00_axis_0_tdata s02_axis_0_tdata}]
# set_output_delay -clock dac_coreclk -max 1.5 [get_ports {s10_axis_0_tdata s12_axis_0_tdata}]
# set_output_delay -clock dac_coreclk -max 1.5 [get_ports {s20_axis_0_tdata s22_axis_0_tdata}]
# set_output_delay -clock dac_coreclk -max 1.5 [get_ports {s30_axis_0_tdata s32_axis_0_tdata}]

# ---------- 8. 引脚分配 (模板, 按实际 PCB 填写) ----------
# set_property PACKAGE_PIN XX [get_ports dac_coreclk]
# set_property IOSTANDARD LVCMOS18 [get_ports dac_coreclk]
# ... 其余端口按 PCB 原理图
