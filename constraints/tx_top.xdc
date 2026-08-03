# =============================================================================
# tx_top.xdc  --  时序与引脚约束 (ZU48DR RFSoC)
# =============================================================================
# 本约束为模板, 实际引脚分配需按 PCB 设计填写。
# =============================================================================

# ---------- 主时钟 300MHz (PL 时钟, 兼作 RF-DAC AXI-Stream 时钟) ----------
create_clock -period 3.333 -name clk_300m [get_ports clk_300m]

# ---------- 异步复位: false_path ----------
set_false_path -from [get_ports async_rst_n] -to [get_clocks clk_300m]

# ---------- APB 配置口: 若异步于 300MHz ----------
# 假设 APB 时钟与 300MHz 同源; 若异步则取消注释:
# create_clock -period 10.0 -name apb_clk [get_ports apb_clk]
# set_false_path -from [get_clocks apb_clk] -to [get_clocks clk_300m]
# set_false_path -from [get_clocks clk_300m] -to [get_clocks apb_clk]

# ---------- 配置寄存器 (静态配置, false_path) ----------
# delay_val / weight / phase_inc 等配置寄存器为静态, 不做时序收敛
set_false_path -to [get_cells -hier -filter {NAME =~ *u_cfg*delay_reg*}]
set_false_path -to [get_cells -hier -filter {NAME =~ *u_cfg*wre_reg*}]
set_false_path -to [get_cells -hier -filter {NAME =~ *u_cfg*wim_reg*}]
set_false_path -to [get_cells -hier -filter {NAME =~ *u_cfg*pinc_reg*}]
set_false_path -to [get_cells -hier -filter {NAME =~ *u_cfg*poff_reg*}]

# ---------- 内部 8 并行数据总线对齐 ----------
# 从 interp_fir → cmult_8p → sum_4to1 的 8 并行总线 (288bit 复数)
set_bus_skew  -from [get_cells -hier -filter {NAME =~ *u_fir_*mac_out*}] \
              -to   [get_cells -hier -filter {NAME =~ *u_mix*u_cmult*}] 0.0
set_max_delay -from [get_cells -hier -filter {NAME =~ *u_fir_*mac_out*}] \
              -to   [get_cells -hier -filter {NAME =~ *u_mix*u_cmult*}] 3.333

# ---------- RF-DAC 接口 ----------
# RF Data Converter IP 自动处理 RF-DAC tile 时钟与 PL AXI-Stream 时钟的跨时钟域
# PL 侧 8 并行 @300MHz AXI-Stream 连接由 RF Data Converter IP 约束
# 此处不手动分配 RF-DAC 引脚 (RFSoC RF-DAC 引脚固定)

# ---------- 基带输入 ----------
# 4 路基带 IQ 输入, 按实际来源 (JESD204 / 并行 LVDS) 约束
# set_input_delay -clock clk_300m [get_ports {bb_i_* bb_q_*}]

# ---------- 引脚分配 (模板, 按实际 PCB 填写) ----------
# set_property PACKAGE_PIN XX [get_ports clk_300m]
# set_property IOSTANDARD LVCMOS18 [get_ports clk_300m]
# ... 其余引脚按 PCB

# ---------- 无效路径: DDS NCO LROM ----------
# dds_nco 的 sin_lut 用 $readmemh 初始化, 综合时为 BRAM, 无时序路径约束需求
