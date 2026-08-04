`timescale 1ns/1ps

// =============================================================================
// sum_4to1.sv  --  4 路复数求和器 (8 并行, → 1 路复数 DAC)
// =============================================================================
// 将 4 个波束对应同一阵元的 8 并行复数输出求和, 产生 1 路 8 并行复数 DAC 输出。
// I/Q 两路各自独立例化 add_tree_4 (4 输入加法树)。
//
// 位宽: 输入 18bit (mix_t) → 输出 20bit (sum_t), 4 路求和增 2 bit。
// 流水延迟: 2 拍 (add_tree_4 两级寄存)。
//
// 端口:
//   in_i_8p[3:0], in_q_8p[3:0] : 4 波束的 8 并行 I/Q
//   out_i_8p, out_q_8p         : 求和后 8 并行复数
// =============================================================================

`ifndef SUM_4TO1_SV
`define SUM_4TO1_SV
import tx_bf_pkg::*;

module sum_4to1 #(
    parameter int unsigned IN_W   = MIXER_OUT_W,  // 18
    parameter int unsigned OUT_W  = SUM_OUT_W,    // 20
    parameter int unsigned N_PAR  = INTERP        // 8
)(
    input  logic                        clk,
    input  logic                        rst,
    input  logic signed [IN_W-1:0]      in_i_8p [3:0][N_PAR-1:0],
    input  logic signed [IN_W-1:0]      in_q_8p [3:0][N_PAR-1:0],
    input  logic                        in_valid,
    output logic signed [OUT_W-1:0]     out_i_8p [N_PAR-1:0],
    output logic signed [OUT_W-1:0]     out_q_8p [N_PAR-1:0],
    output logic                        out_valid
);

    // I 路加法树
    add_tree_4 #(
        .IN_W  (IN_W),
        .OUT_W (OUT_W),
        .N_PAR (N_PAR)
    ) u_tree_i (
        .clk       (clk),
        .rst       (rst),
        .in_8p     (in_i_8p),
        .in_valid  (in_valid),
        .out_8p    (out_i_8p),
        .out_valid (out_valid)
    );

    // Q 路加法树 (valid 与 I 路相同, 不重复输出)
    logic unused_v;
    add_tree_4 #(
        .IN_W  (IN_W),
        .OUT_W (OUT_W),
        .N_PAR (N_PAR)
    ) u_tree_q (
        .clk       (clk),
        .rst       (rst),
        .in_8p     (in_q_8p),
        .in_valid  (in_valid),
        .out_8p    (out_q_8p),
        .out_valid (unused_v)
    );

endmodule : sum_4to1

`endif // SUM_4TO1_SV
