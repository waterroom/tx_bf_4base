// =============================================================================
// add_tree_4.sv  --  4 输入加法树 (8 并行, 单实数维度)
// =============================================================================
// 将 4 路输入 (每路 8 并行实数) 求和为 1 路 8 并行输出。
// 2 级加法树: (a+b) + (c+d), 每级 1 拍寄存, 总 2 拍流水。
// 位宽: IN_W + 2 (4 路求和最坏增 2 bit)。
//
// 本模块处理单一实数维度 (I 或 Q), sum_4to1 内 I/Q 各例化 1 个。
//
// 端口:
//   in_8p[3:0] : 4 路输入, 每路 8 并行实数 (18bit)
//   out_8p     : 8 并行求和输出 (20bit)
//   流水延迟: 2 拍
// =============================================================================

`ifndef ADD_TREE_4_SV
`define ADD_TREE_4_SV

import tx_bf_pkg::*;

module add_tree_4 #(
    parameter int unsigned IN_W   = MIXER_OUT_W,  // 18
    parameter int unsigned OUT_W  = SUM_OUT_W,    // 20
    parameter int unsigned N_PAR  = INTERP        // 8
)(
    input  logic                        clk,
    input  logic                        rst,
    input  logic signed [IN_W-1:0]      in_8p [3:0][N_PAR-1:0],
    input  logic                        in_valid,
    output logic signed [OUT_W-1:0]     out_8p [N_PAR-1:0],
    output logic                        out_valid
);

    // ---------- 第 1 级: (a+b) 和 (c+d), 扩展 1 位 ----------
    localparam int S1_W = IN_W + 1;     // 2 路求和增 1 bit
    logic signed [S1_W-1:0] sum_ab [N_PAR-1:0];
    logic signed [S1_W-1:0] sum_cd [N_PAR-1:0];
    logic                   v1;

    always_ff @(posedge clk) begin
        if (rst) begin
            for (int p = 0; p < N_PAR; p++) begin
                sum_ab[p] <= '0;
                sum_cd[p] <= '0;
            end
            v1 <= 1'b0;
        end else begin
            for (int p = 0; p < N_PAR; p++) begin
                sum_ab[p] <= {in_8p[0][p][IN_W-1], in_8p[0][p]} + {in_8p[1][p][IN_W-1], in_8p[1][p]};
                sum_cd[p] <= {in_8p[2][p][IN_W-1], in_8p[2][p]} + {in_8p[3][p][IN_W-1], in_8p[3][p]};
            end
            v1 <= in_valid;
        end
    end

    // ---------- 第 2 级: (ab)+(cd), 再扩展 1 位 ----------
    // OUT_W = IN_W + 2, S1_W = IN_W + 1, 求和后截位/扩展到 OUT_W
    always_ff @(posedge clk) begin
        if (rst) begin
            for (int p = 0; p < N_PAR; p++) out_8p[p] <= '0;
            out_valid <= 1'b0;
        end else begin
            for (int p = 0; p < N_PAR; p++) begin
                // S1_W+1 = IN_W+2 = OUT_W, 符号扩展后求和
                out_8p[p] <= {{(OUT_W-S1_W){sum_ab[p][S1_W-1]}}, sum_ab[p]}
                           + {{(OUT_W-S1_W){sum_cd[p][S1_W-1]}}, sum_cd[p]};
            end
            out_valid <= v1;
        end
    end

endmodule : add_tree_4

`endif // ADD_TREE_4_SV
