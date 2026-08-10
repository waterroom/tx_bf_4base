// =============================================================================
// interp_hb_3stage.sv — 3 级半带内插 (300→600→1200→2400 MHz), 基于 Xilinx FIR Compiler IP
// =============================================================================
// 替代 interp_fir_8x_wrap (手写 48 抽头 8 并行), 接口完全兼容:
//   输入: 每通道每拍 1 样本 (300M s/s, 18bit)
//   输出: 每通道每拍 8 并行样本 (2.4G s/s 等效, 18bit)
//
// 结构 (每通道, FIR Compiler 单速率多 VECT 并行 = 等效插值 2/4/8):
//   级1 fir_300to600_87p5pass_hf : 1×16bit → 2×31bit   (等效 600M s/s)
//   级2 fir_600to1200_87p5pass_hf: 2×16bit → 4×31bit   (等效 1200M s/s)
//   级3 fir_1200to2400_87p5pass_hf: 4×16bit → 8×31bit  (等效 2400M s/s)
//
// VECT 布局 (demo_tb 确认): 输出 TDATA 每 32bit 槽 1 个 31bit 样本,
//   vect0 = 最低槽 = 时间上最早的样本; 输入 TDATA 每 16bit 槽 1 个样本, 低位在先
// 级间截位: 31bit → 16bit 取高 16bit [30:15] (半带 DC 增益≈1, 有效信号在高位)
// 输入截位: 18bit → 16bit 取低 16bit [15:0] (高 2 位符号扩展位, 标度不变)
// 输出扩展: 16bit → 18bit 符号扩展 2bit (与混频链路 18bit 对齐)
//
// DSP: 每通道 6+2+2 = 10 MADDS × 8ch × 4beam × 2(I/Q) = 640
//       (手写 48 抽头 8 并行: 3072) — 省 ~79%
// =============================================================================
`timescale 1ns/1ps

module interp_hb_3stage #(
    parameter int unsigned IN_W  = 18,
    parameter int unsigned OUT_W = 18,
    parameter int unsigned N_CH  = 8,
    parameter int unsigned N_PAR = 8
)(
    input  logic                         clk,
    input  logic                         rst,     // 保留 (接口兼容); IP 无复位, 数据流持续
    input  logic signed [IN_W-1:0]       in_data  [N_CH-1:0],
    input  logic                         in_valid,
    output logic signed [OUT_W-1:0]      out_data [N_CH-1:0][N_PAR-1:0],
    output logic                         out_valid
);

    logic v1 [N_CH-1:0];   // 级1 输出 valid (每通道)
    logic v2 [N_CH-1:0];
    logic v3 [N_CH-1:0];

    for (genvar ch = 0; ch < N_CH; ch++) begin : g_ch
        // ---- 级间信号 ----
        logic [15:0]  in16;              // 输入截位 16bit
        logic [63:0]  m1;                // 级1 输出 2×31bit
        logic [31:0]  d2;                // 级2 输入 2×16bit 打包
        logic [127:0] m2;                // 级2 输出 4×31bit
        logic [63:0]  d3;                // 级3 输入 4×16bit 打包
        logic [255:0] m3;                // 级3 输出 8×31bit
        logic [15:0]  s3 [N_PAR-1:0];    // 级3 输出截位 8×16bit

        // 输入 18bit → 16bit: 取低 16bit [15:0] (高 2 位是符号扩展位,
        // 实际信号在 16bit 内; 不能取 [17:2], 那会右移 2 位 = ÷4 缩小信号)
        assign in16 = in_data[ch][15:0];

        // ---------- 级1: 300→600 MHz (1×16 → 2×31) ----------
        fir_300to600_87p5pass_hf u_st1 (
            .aclk               (clk),
            .aresetn            (~rst),   // sim_src 仿真模型带 aresetn; 综合需 IP 带复位
            .s_axis_data_tvalid (in_valid),
            .s_axis_data_tready (),
            .s_axis_data_tdata  (in16),
            .m_axis_data_tvalid (v1[ch]),
            .m_axis_data_tdata  (m1)
        );
        // 级1 输出 2×31bit → 截位 2×16bit → 打包级2 输入 (vect0=低位=最早)
        assign d2 = {m1[62:47], m1[30:15]};

        // ---------- 级2: 600→1200 MHz (2×16 → 4×31) ----------
        fir_600to1200_87p5pass_hf u_st2 (
            .aclk               (clk),
            .aresetn            (~rst),   // sim_src 仿真模型带 aresetn; 综合需 IP 带复位
            .s_axis_data_tvalid (v1[ch]),
            .s_axis_data_tready (),
            .s_axis_data_tdata  (d2),
            .m_axis_data_tvalid (v2[ch]),
            .m_axis_data_tdata  (m2)
        );
        // 级2 输出 4×31bit → 截位 4×16bit → 打包级3 输入
        assign d3 = {m2[126:111], m2[94:79], m2[62:47], m2[30:15]};

        // ---------- 级3: 1200→2400 MHz (4×16 → 8×31) ----------
        fir_1200to2400_87p5pass_hf u_st3 (
            .aclk               (clk),
            .aresetn            (~rst),   // sim_src 仿真模型带 aresetn; 综合需 IP 带复位
            .s_axis_data_tvalid (v2[ch]),
            .s_axis_data_tready (),
            .s_axis_data_tdata  (d3),
            .m_axis_data_tvalid (v3[ch]),
            .m_axis_data_tdata  (m3)
        );
        // 级3 输出 8×31bit (每 32bit 槽) → 截位 8×16bit → 18bit 符号扩展
        for (genvar p = 0; p < N_PAR; p++) begin : g_p
            assign s3[p] = m3[32*p + 30 -: 16];       // 取 32bit 槽的高 16bit
            assign out_data[ch][p] = {{2{s3[p][15]}}, s3[p]};
        end
    end

    // valid: 各通道同一 valid 链 (输入同源), 输出 valid = 级3 valid (数据同拍)
    assign out_valid = v3[0];

endmodule
