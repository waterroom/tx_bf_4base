# =============================================================================
# ⚠️ 已废弃 (2026-08): 本脚本生成的是旧 48 抽头单级结构
#   (fir_compiler_8x / dds_compiler_lo, 引用 ip/coef/*.coe 不存在)。
#   当前 RTL 使用 3 级半带内插 IP (fir_300to600/fir_600to1200/
#   fir_1200to2400_87p5pass_hf) + dds_core_tx_bf_4base, 全部在
#   vivado_sim 工程内管理 (sources_1/ip/), 不需要本脚本。
#   且 part 型号 xczu48dr-fsvb1156-2-e 与当前工程 ffvg1517 不一致,
#   即使运行也无效。保留仅供旧结构参考, 请勿再运行。
# =============================================================================
# build_ip.tcl  --  生成 Xilinx IP (旧结构, 已废弃)
# =============================================================================

set proj_name "tx_bf_4base_ip"
set part "xczu48dr-fsvb1156-2-e"   ;# ZU48DR (按实际型号调整)

create_project $proj_name ip/$proj_name -part $part -force

# ---------- 1. FIR Compiler (8 倍内插, 8 通道, 48 抽头对称) ----------
# 系数文件: ip/coef/fir_300Mto2400M_88Mpass.coe (由 gen_coe.m 生成)
create_ip -name fir_compiler -vendor xilinx.com -library ip -version 7.2 \
    -module_name fir_compiler_8x
set_property -dict [list \
    CONFIG.Filter_Type {Interpolation} \
    CONFIG.Sample_Frequency {300} \
    CONFIG.Clock_Frequency {300} \
    CONFIG.Coefficient_Sign {Signed} \
    CONFIG.Coefficient_Width {16} \
    CONFIG.Coefficient_Fractional_Bits {15} \
    CONFIG.Coefficient_Structure {Symmetric} \
    CONFIG.Data_Width {18} \
    CONFIG.Output_Rounding {Convergent_Symmetric_Rounding_to_Even} \
    CONFIG.Output_Width {18} \
    CONFIG.Interpolation_Rate {8} \
    CONFIG.Number_Channels {8} \
    CONFIG.Coefficient_File {ip/coef/fir_300Mto2400M_88Mpass.coe} \
    CONFIG.Channel_Sequence {Basic} \
    CONFIG.Select_Pattern {1} \
] [get_ips fir_compiler_8x]

# ---------- 2. DDS Compiler (32bit 相位, 16bit 输出, 8 并行) ----------
create_ip -name dds_compiler -vendor xilinx.com -library ip -version 6.0 \
    -module_name dds_compiler_lo
set_property -dict [list \
    CONFIG.Phase_Width {32} \
    CONFIG.Output_Width {16} \
    CONFIG.Phase_Increment {Programmable} \
    CONFIG.Phase_Offset {Programmable} \
    CONFIG.Output_Selection {Sine_and_Cosine} \
    CONFIG.Pipelined {true} \
    CONFIG.Output_Multiplied_By {8} \
    CONFIG.Noise_Shaping {None} \
    CONFIG.Memory_Type {Block_ROM} \
] [get_ips dds_compiler_lo]

# ---------- 3. RF Data Converter (ZU48DR 片内 RF-DAC, 8 通道复数 I/Q) ----------
# 注: RF Data Converter IP 配置依赖具体 ZU48DR 型号和 DAC tile 分配,
#     需在 Vivado IP Catalog 中手动配置 (8 DAC 通道, I/Q 模式, 2.4Gs/s, 1x 插值)
puts "TODO: RF Data Converter IP 需手动配置 (8 DAC 通道, I/Q 复数模式, 2.4Gs/s)"

# 生成
generate_target all [get_ips]

puts "=== IP 生成完成 ==="
puts "FIR Compiler: fir_compiler_8x (8ch, 8x interp, 48-tap symmetric)"
puts "DDS Compiler: dds_compiler_lo (32bit phase, 8 parallel sin/cos)"
puts "注: 综合时定义 USE_XILINX_FIR_IP 宏切换到 IP 版本"
