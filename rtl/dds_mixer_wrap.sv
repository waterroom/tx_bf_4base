`timescale 1ns/1ps

// =============================================================================
// dds_mixer_wrap.sv  --  DDS (NCO) + 复数混频包装 (8 并行 @2.4GHz 等效)
// =============================================================================
// 功能: NCO 产生 8 并行复本振 (cos+j·sin), 与 8 并行复 IQ 复数混频, 输出 8 并行复数。
//   (I+jQ)·(cos+j·sin) = (I·cos-Q·sin) + j(I·sin+Q·cos)
//   DAC 为复数 I/Q, 必须保留 I+jQ 两路。
//
// NCO: 用可综合 dds_nco (相位累加器 + 1/4 波 LUT)。
//   用户后续可替换为 Xilinx DDS Compiler IP 以节省资源 (dds_nco 接口兼容)。
//
// LO 按波束: 每个 beam_duc 内 1 个本模块, phase_inc 对应该波束 LO 频率。
//
// 流水延迟: dds_nco 2 拍 + cmult_3dsp 7 拍 = 9 拍。
// =============================================================================

`ifndef DDS_MIXER_WRAP_SV
`define DDS_MIXER_WRAP_SV
import tx_bf_pkg::*;

module dds_mixer_wrap #(
    parameter int unsigned PHASE_W = DDS_PHASE_W,    // 32
    parameter int unsigned NCO_W    = DDS_OUT_W,     // 16
    parameter int unsigned IQ_W     = FIR_OUT_W,     // 18
    parameter int unsigned OUT_W    = MIXER_OUT_W,   // 18
    parameter int unsigned N_PAR    = INTERP         // 8
)(
    input  logic                        clk,
    input  logic                        rst,
    // DDS 配置
    input  logic [PHASE_W-1:0]          phase_inc,     // 相位步进 (对应 LO 频率)
    input  logic [PHASE_W-1:0]          phase_offset,  // 相位初值 (可选, 默认 0)
    // 8 并行复 IQ 输入 (来自内插 FIR)
    input  logic signed [IQ_W-1:0]      in_i_8p [N_PAR-1:0],
    input  logic signed [IQ_W-1:0]      in_q_8p [N_PAR-1:0],
    input  logic                        in_valid,
    // 8 并行复数输出 (I+jQ)
    output logic signed [OUT_W-1:0]     out_i_8p [N_PAR-1:0],
    output logic signed [OUT_W-1:0]     out_q_8p [N_PAR-1:0],
    output logic                        out_valid
);

    // =========================================================================
    // NCO: 8 并行 cos/sin
    // =========================================================================
    logic signed [NCO_W-1:0] cos_8p [N_PAR-1:0];
    logic signed [NCO_W-1:0] sin_8p [N_PAR-1:0];

    dds_nco #(
        .PHASE_W (PHASE_W),
        .OUT_W   (NCO_W),
        .N_PAR   (N_PAR)
    ) u_nco (
        .clk          (clk),
        .rst          (rst),
        .phase_inc    (phase_inc),
        .phase_offset (phase_offset),
        .cos_8p       (cos_8p),
        .sin_8p       (sin_8p)
    );

    // =========================================================================
    // 复数混频: 8 并行 (I+jQ)·(cos+j·sin)
    // =========================================================================
    cmult_8p #(
        .IQ_W  (IQ_W),
        .NCO_W (NCO_W),
        .OUT_W (OUT_W),
        .N_PAR (N_PAR)
    ) u_cmult_8p (
        .clk       (clk),
        .rst       (rst),
        .in_i_8p   (in_i_8p),
        .in_q_8p   (in_q_8p),
        .cos_8p    (cos_8p),
        .sin_8p    (sin_8p),
        .in_valid  (in_valid),
        .out_i_8p  (out_i_8p),
        .out_q_8p  (out_q_8p),
        .out_valid (out_valid)
    );

endmodule : dds_mixer_wrap

`endif // DDS_MIXER_WRAP_SV
