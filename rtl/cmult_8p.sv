`timescale 1ns/1ps

// =============================================================================
// cmult_8p.sv  --  8 并行复数混频器
// =============================================================================
// 将 8 并行复 IQ 与 8 并行复本振 (cos+j·sin) 做复数乘法, 输出 8 并行复数。
// 用于 2.4GHz 等效域的上变频混频 (DAC 为复数 I/Q, 必须保留 I+jQ 两路)。
//
// 内部例化 8 个 cmult_3dsp (3-DSP 复数乘法, 直接复用参考仓库), 每路处理
// 1 个并行采样。3 DSP/路 × 8 路 = 24 DSP/阵元。
//
// 端口:
//   in_i_8p, in_q_8p : 8 并行 IQ 输入 (来自内插 FIR, 18bit)
//   cos_8p, sin_8p   : 8 并行 DDS 本振 (16bit)
//   out_i_8p, out_q_8p : 8 并行复数输出 (18bit, 已饱和)
//   流水延迟: 7 拍 (cmult_3dsp 7 级流水)
// =============================================================================

`ifndef CMULT_8P_SV
`define CMULT_8P_SV
import tx_bf_pkg::*;

module cmult_8p #(
    parameter int unsigned IQ_W   = FIR_OUT_W,    // 18
    parameter int unsigned NCO_W  = DDS_OUT_W,    // 16
    parameter int unsigned OUT_W  = MIXER_OUT_W,  // 18
    parameter int unsigned N_PAR  = INTERP        // 8
)(
    input  logic              clk,
    input  logic              rst,
    input  logic signed [IQ_W-1:0]  in_i_8p [N_PAR-1:0],
    input  logic signed [IQ_W-1:0]  in_q_8p [N_PAR-1:0],
    input  logic signed [NCO_W-1:0] cos_8p [N_PAR-1:0],
    input  logic signed [NCO_W-1:0] sin_8p [N_PAR-1:0],
    input  logic              in_valid,
    output logic signed [OUT_W-1:0] out_i_8p [N_PAR-1:0],
    output logic signed [OUT_W-1:0] out_q_8p [N_PAR-1:0],
    output logic              out_valid
);

    // 第 0 路的 valid (8 路同源 in_valid + 等流水, valid 相同)
    logic v0;

    genvar i;
    generate
        for (i = 0; i < N_PAR; i++) begin : g_mix
            // 复数乘法: (I+jQ)·(cos+j·sin) = (I·cos−Q·sin) + j(I·sin+Q·cos)
            // cmult_3dsp 的 3-DSP 算法:
            //   P0=I·cos, P1=Q·sin, P2=(I+Q)(cos+sin), Re=P0−P1, Im=P2−P0−P1
            if (i == 0) begin : g_v
                cmult_3dsp #(
                    .A_W   (IQ_W),
                    .B_W   (NCO_W),
                    .OUT_W (OUT_W)
                ) u_cmult (
                    .clk       (clk),
                    .rst       (rst),
                    .valid_in  (in_valid),
                    .a_re      (in_i_8p[i]),
                    .a_im      (in_q_8p[i]),
                    .b_re      (cos_8p[i]),
                    .b_im      (sin_8p[i]),
                    .o_re      (out_i_8p[i]),
                    .o_im      (out_q_8p[i]),
                    .valid_out (v0)
                );
            end else begin : g_nv
                cmult_3dsp #(
                    .A_W   (IQ_W),
                    .B_W   (NCO_W),
                    .OUT_W (OUT_W)
                ) u_cmult (
                    .clk       (clk),
                    .rst       (rst),
                    .valid_in  (in_valid),
                    .a_re      (in_i_8p[i]),
                    .a_im      (in_q_8p[i]),
                    .b_re      (cos_8p[i]),
                    .b_im      (sin_8p[i]),
                    .o_re      (out_i_8p[i]),
                    .o_im      (out_q_8p[i]),
                    .valid_out ()
                );
            end
        end
    endgenerate

    // valid 直通: cmult_3dsp 内部第 6 级已寄存 valid_out, 与 o_re/o_im 同拍对齐
    assign out_valid = v0;

endmodule : cmult_8p

`endif // CMULT_8P_SV
