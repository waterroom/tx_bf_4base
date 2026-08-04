`timescale 1ns/1ps

// =============================================================================
// beam_duc.sv  --  单波束处理单元 (DBF → 内插 → 复数上变频)
// =============================================================================
// 数据流:
//   BB(复IQ, 300MHz) → tx_bf_core(8通道DBF) → 8路复IQ @300MHz
//     → interp_fir_8x_wrap ×2 (I/Q 各一, 8倍内插) → 8路 × 8并行复IQ @2.4GHz等效
//     → dds_nco(1个, 共享LO) + cmult_8p ×8 (每阵元1个, 共享cos/sin) → 8路 × 8并行复数
//
// LO 按波束: 1 个 dds_nco 产生 8 并行 cos/sin, 广播给 8 个 cmult_8p (8 阵元共享)。
//
// 输出: 8 阵元各自的 8 并行复数 (I+jQ), 供 sum_4to1 跨波束求和。
//
// 流水延迟: DBF(delay_val+34) + 内插FIR(3) + cmult_3dsp(7) ≈ delay_val+44 拍
// =============================================================================

`ifndef BEAM_DUC_SV
`define BEAM_DUC_SV

`include "tx_bf_core.sv"
`include "interp_hb_3stage.sv"   // 3 级半带 FIR IP 级联 (替代手写 48 抽头 interp_fir_8x_wrap)
`include "dds_nco.sv"
`include "cmult_8p.sv"
import tx_bf_pkg::*;

module beam_duc #(
    parameter int unsigned N_CH   = N_ELEM,        // 8 阵元
    parameter int unsigned N_PAR  = INTERP         // 8 并行
)(
    input  logic                        clk,
    input  logic                        rst,
    // 基带输入
    input  logic signed [DATA_W-1:0]    bb_i,
    input  logic signed [DATA_W-1:0]    bb_q,
    input  logic                        bb_valid,
    // DBF 配置 (tx_bf_core)
    input  logic [$clog2(MAX_DELAY+1)-1:0] delay_val [N_CH-1:0],
    input  logic                        fir_coef_load,
    input  logic [$clog2(TAPS)-1:0]    fir_coef_addr,
    input  logic signed [COEF_W-1:0]   fir_coef_data,
    input  logic [$clog2(N_CH)-1:0]    fir_sel_ch,
    input  logic                        weight_load,
    input  logic [$clog2(N_CH)-1:0]    weight_sel_ch,
    input  logic signed [COEF_W-1:0]   weight_re,
    input  logic signed [COEF_W-1:0]   weight_im,
    // DDS 配置
    input  logic [DDS_PHASE_W-1:0]     phase_inc,
    input  logic [DDS_PHASE_W-1:0]     phase_offset,
    // 输出: 8 阵元 × 8 并行 复数 (I+jQ)
    output logic signed [MIXER_OUT_W-1:0] out_i [N_CH-1:0][N_PAR-1:0],
    output logic signed [MIXER_OUT_W-1:0] out_q [N_CH-1:0][N_PAR-1:0],
    output logic                        out_valid
);

    // ---------- 1. DBF: 8 通道 TTD 波束形成 ----------
    logic signed [FIR_OUT_W-1:0] bf_re [N_CH-1:0];
    logic signed [FIR_OUT_W-1:0] bf_im [N_CH-1:0];
    logic                        bf_valid;

    tx_bf_core #(
        .N_CH      (N_CH),
        .DATA_W    (DATA_W),
        .MAX_DELAY (MAX_DELAY),
        .TAPS      (TAPS),
        .COEF_W    (COEF_W),
        .FIR_OUT_W (FIR_OUT_W)
    ) u_bf_core (
        .clk            (clk),
        .rst            (rst),
        .in_re          (bb_i),
        .in_im          (bb_q),
        .in_valid       (bb_valid),
        .delay_val      (delay_val),
        .fir_coef_load  (fir_coef_load),
        .fir_coef_addr  (fir_coef_addr),
        .fir_coef_data  (fir_coef_data),
        .fir_sel_ch     (fir_sel_ch),
        .weight_load    (weight_load),
        .weight_sel_ch  (weight_sel_ch),
        .weight_re      (weight_re),
        .weight_im      (weight_im),
        .out_re         (bf_re),
        .out_im         (bf_im),
        .out_valid      (bf_valid)
    );

    // ---------- 2. 8 倍内插: I/Q 分别内插, 8 通道并行 ----------
    logic signed [FIR_OUT_W-1:0] up_i [N_CH-1:0][N_PAR-1:0];
    logic signed [FIR_OUT_W-1:0] up_q [N_CH-1:0][N_PAR-1:0];
    logic                        up_valid;

    interp_hb_3stage #(
        .IN_W  (FIR_OUT_W),
        .OUT_W (FIR_OUT_W),
        .N_CH  (N_CH),
        .N_PAR (N_PAR)
    ) u_fir_i (
        .clk      (clk),
        .rst      (rst),
        .in_data  (bf_re),      // 8 通道 I 分量
        .in_valid (bf_valid),
        .out_data (up_i),
        .out_valid(up_valid)
    );

    interp_hb_3stage #(
        .IN_W  (FIR_OUT_W),
        .OUT_W (FIR_OUT_W),
        .N_CH  (N_CH),
        .N_PAR (N_PAR)
    ) u_fir_q (
        .clk      (clk),
        .rst      (rst),
        .in_data  (bf_im),      // 8 通道 Q 分量
        .in_valid (bf_valid),
        .out_data (up_q),
        .out_valid()            // 与 u_fir_i 同步
    );

    // ---------- 3. NCO: 共享 LO, 8 并行 cos/sin ----------
    logic signed [DDS_OUT_W-1:0] cos_8p [N_PAR-1:0];
    logic signed [DDS_OUT_W-1:0] sin_8p [N_PAR-1:0];

    dds_nco #(
        .PHASE_W (DDS_PHASE_W),
        .OUT_W   (DDS_OUT_W),
        .N_PAR   (N_PAR)
    ) u_nco (
        .clk          (clk),
        .rst          (rst),
        .phase_inc    (phase_inc),
        .phase_offset (phase_offset),
        .cos_8p       (cos_8p),
        .sin_8p       (sin_8p)
    );

    // ---------- 4. 复数混频: 8 阵元各 1 个 cmult_8p, 共享 cos/sin ----------
    genvar c;
    generate
        for (c = 0; c < N_CH; c++) begin : g_mix
            logic mix_v;
            cmult_8p #(
                .IQ_W  (FIR_OUT_W),
                .NCO_W (DDS_OUT_W),
                .OUT_W (MIXER_OUT_W),
                .N_PAR (N_PAR)
            ) u_mix (
                .clk       (clk),
                .rst       (rst),
                .in_i_8p   (up_i[c]),
                .in_q_8p   (up_q[c]),
                .cos_8p    (cos_8p),
                .sin_8p    (sin_8p),
                .in_valid  (up_valid),
                .out_i_8p  (out_i[c]),
                .out_q_8p  (out_q[c]),
                .out_valid (mix_v)
            );
            // 8 路混频 valid 相同, 取第 0 路
            if (c == 0) assign out_valid = mix_v;
        end
    endgenerate

endmodule : beam_duc

`endif // BEAM_DUC_SV
