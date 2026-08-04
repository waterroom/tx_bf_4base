// =============================================================================
// dds_multi_phase_wrap.sv — 8 相位 DDS 合成器 (基于 Xilinx DDS Compiler IP)
// =============================================================================
// 替代手写 dds_nco (LUT + $readmemh, 仿真易 X)。
// 参考: C:\prj\z669\...\new\dds_core_multi_phase.v
//   多相位累加 (每拍推进 N_PAR×freq) + 每相位例化一个 dds_core IP
//   (s_axis_phase_tdata 64bit = {相位字[31:0], 频率字[31:0]};
//    m_axis_data_tdata 32bit = {sin[15:0], cos[15:0]}, 有效 14bit)
//
// 接口与 dds_nco 完全一致 (beam_duc 只改模块名):
//   clk/rst/phase_inc/phase_offset/cos_8p[N_PAR]/sin_8p[N_PAR]
// 输出: cos = tdata[13:0]<<2, sin = tdata[29:16]<<2 (参考实现, 14bit 有效)
// DDS 核自带 aresetn (低有效), 上电复位 → 仿真无 X
// =============================================================================
`timescale 1ns/1ps

module dds_multi_phase_wrap #(
    parameter int unsigned PHASE_W = 32,
    parameter int unsigned OUT_W   = 16,
    parameter int unsigned N_PAR   = 8
)(
    input  logic                             clk,
    input  logic                             rst,
    input  logic [PHASE_W-1:0]               phase_inc,     // 频率控制字 (每拍相位步进)
    input  logic [PHASE_W-1:0]               phase_offset,  // 初始相位
    output logic signed [OUT_W-1:0]          cos_8p [N_PAR-1:0],
    output logic signed [OUT_W-1:0]          sin_8p [N_PAR-1:0]
);

    // ---------- 相位累加器: 每拍前进 N_PAR×phase_inc (8 并行) ----------
    logic [PHASE_W-1:0] phase_acc;
    always_ff @(posedge clk) begin
        if (rst)
            phase_acc <= phase_offset;
        else
            phase_acc <= phase_acc + phase_inc * N_PAR;   // N_PAR 为常量, 常数乘
    end

    // ---------- 每相位相位字: phase_acc + k×phase_inc (k=0..N_PAR-1) ----------
    logic [PHASE_W-1:0] phase_k [N_PAR-1:0];
    always_comb begin
        for (int p = 0; p < N_PAR; p++) begin
            phase_k[p] = phase_acc + phase_inc * p;        // p 为循环常量, 常数乘
        end
    end

    // ---------- N_PAR 个 DDS 核 ----------
    logic [31:0] dds_tdata  [N_PAR-1:0];
    logic        dds_tvalid [N_PAR-1:0];

    for (genvar p = 0; p < N_PAR; p++) begin : g_dds
        dds_core u_dds (
            .aclk                (clk),
            .aclken              (1'b1),
            .aresetn             (~rst),
            .s_axis_phase_tvalid (1'b1),
            .s_axis_phase_tdata  ({phase_k[p], phase_inc}),   // {相位, 频率} 64bit
            .m_axis_data_tvalid  (dds_tvalid[p]),
            .m_axis_data_tdata   (dds_tdata[p])               // {sin, cos} 各 16bit
        );
        // 输出: cos = tdata[13:0]<<2, sin = tdata[29:16]<<2 (参考实现, 14bit 有效)
        assign cos_8p[p] = {dds_tdata[p][13:0], 2'b00};
        assign sin_8p[p] = {dds_tdata[p][29:16], 2'b00};
    end

endmodule : dds_multi_phase_wrap
