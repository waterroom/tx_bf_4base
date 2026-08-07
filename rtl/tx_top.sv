`timescale 1ns/1ps

// =============================================================================
// tx_top.sv  --  数据路径顶层: 4 波束 × 8 阵元 → 8 路复数 RF-DAC
// =============================================================================
// 配置由外部并行端口 cfg_* 驱动 (decode_cmd_tx_bf 或 cfg_bus 包装均可)。
// 数据流:
//   BB1..4 (300MHz 复 IQ) → 4× beam_duc (DBF+内插+上变频) → 4×8路复数 @2.4GHz等效
//     → 8× sum_4to1 (每阵元求 4 波束之和) → 8 路复数 I/Q (8并行 @300MHz)
//     → 截位 16bit → 8 路 RF-DAC
//
// 内部: 4 beam_duc + 8 sum_4to1 + DAC 截位 (复位为同步高有效 rst, 由顶层同步后提供)
// =============================================================================

`ifndef TX_TOP_SV
`define TX_TOP_SV
import tx_bf_pkg::*;

module tx_top (
    input  logic                        clk_300m,      // 主时钟 300MHz
    input  logic                        rst,           // 同步高有效复位 (顶层已同步, 本模块不再内部同步)

    // 4 路基带复 IQ 输入 (300MHz)
    input  logic signed [DATA_W-1:0]    bb_i [N_BEAM-1:0],
    input  logic signed [DATA_W-1:0]    bb_q [N_BEAM-1:0],
    input  logic                        bb_valid [N_BEAM-1:0],

    // ---------- 并行配置端口 (由 decode_cmd_tx_bf 或 cfg_bus 驱动) ----------
    input  logic [$clog2(MAX_DELAY+1)-1:0] cfg_delay_val   [N_BEAM-1:0][N_ELEM-1:0],
    input  logic [DDS_PHASE_W-1:0]         cfg_phase_inc   [N_BEAM-1:0],
    input  logic [DDS_PHASE_W-1:0]         cfg_phase_offset[N_BEAM-1:0],
    // FIR 系数串行加载 (共享 sel_ch/addr/data, 每波束独立 load 脉冲)
    input  logic                           cfg_fir_load    [N_BEAM-1:0],
    input  logic [$clog2(N_ELEM)-1:0]      cfg_fir_sel_ch,
    input  logic [$clog2(TAPS)-1:0]        cfg_fir_coef_addr,
    input  logic signed [COEF_W-1:0]       cfg_fir_coef_data,
    // 复数权重串行加载 (共享 sel_ch/re/im, 每波束独立 load 脉冲)
    input  logic                           cfg_weight_load [N_BEAM-1:0],
    input  logic [$clog2(N_ELEM)-1:0]      cfg_weight_sel_ch,
    input  logic signed [COEF_W-1:0]       cfg_weight_re,
    input  logic signed [COEF_W-1:0]       cfg_weight_im,
    // DAC 截位右移量 (0-15, 默认 4 = SUM_OUT_W-DAC_W; decode 0x6704 配置)
    input  logic [3:0]                     cfg_trunc,

    // 8 路 RF-DAC 输出 (复数 I/Q, 8 并行 @300MHz = 2.4Gs/s)
    output logic signed [DAC_W-1:0]     dac_i_8p [N_ELEM-1:0][INTERP-1:0],
    output logic signed [DAC_W-1:0]     dac_q_8p [N_ELEM-1:0][INTERP-1:0],
    output logic                        dac_valid [N_ELEM-1:0]
);

    // ---------- 4 个波束处理单元 ----------
    logic signed [MIXER_OUT_W-1:0] beam_i [N_BEAM-1:0][N_ELEM-1:0][INTERP-1:0];
    logic signed [MIXER_OUT_W-1:0] beam_q [N_BEAM-1:0][N_ELEM-1:0][INTERP-1:0];
    logic                           beam_valid [N_BEAM-1:0];

    // 求和 valid: 4 波束 valid 与
    logic beam_valid_all;
    always_comb begin
        beam_valid_all = 1'b1;
        for (int bm = 0; bm < N_BEAM; bm++)
            beam_valid_all = beam_valid_all & beam_valid[bm];
    end

    genvar b;
    generate
        for (b = 0; b < N_BEAM; b++) begin : g_beam
            beam_duc #(
                .N_CH  (N_ELEM),
                .N_PAR (INTERP)
            ) u_beam (
                .clk            (clk_300m),
                .rst            (rst),
                .bb_i           (bb_i[b]),
                .bb_q           (bb_q[b]),
                .bb_valid       (bb_valid[b]),
                .delay_val      (cfg_delay_val[b]),
                .fir_coef_load  (cfg_fir_load[b]),
                .fir_coef_addr  (cfg_fir_coef_addr),
                .fir_coef_data  (cfg_fir_coef_data),
                .fir_sel_ch     (cfg_fir_sel_ch),
                // 权重: 标量直连 (cfg_weight_re/im + cfg_weight_sel_ch 由外部驱动)
                .weight_load    (cfg_weight_load[b]),
                .weight_sel_ch  (cfg_weight_sel_ch),
                .weight_re      (cfg_weight_re),
                .weight_im      (cfg_weight_im),
                .phase_inc      (cfg_phase_inc[b]),
                .phase_offset   (cfg_phase_offset[b]),
                .out_i          (beam_i[b]),
                .out_q          (beam_q[b]),
                .out_valid      (beam_valid[b])
            );
        end
    endgenerate

    // ---------- 8 个阵元求和 (4 波束 → 1 路) ----------
    logic signed [SUM_OUT_W-1:0] sum_i [N_ELEM-1:0][INTERP-1:0];
    logic signed [SUM_OUT_W-1:0] sum_q [N_ELEM-1:0][INTERP-1:0];
    logic                        sum_valid [N_ELEM-1:0];

    genvar e;
    generate
        for (e = 0; e < N_ELEM; e++) begin : g_sum
            logic signed [MIXER_OUT_W-1:0] bsum_i_in [3:0][INTERP-1:0];
            logic signed [MIXER_OUT_W-1:0] bsum_q_in [3:0][INTERP-1:0];
            always_comb begin
                for (int bm = 0; bm < N_BEAM; bm++) begin
                    for (int p = 0; p < INTERP; p++) begin
                        bsum_i_in[bm][p] = beam_i[bm][e][p];
                        bsum_q_in[bm][p] = beam_q[bm][e][p];
                    end
                end
            end

            sum_4to1 #(
                .IN_W  (MIXER_OUT_W),
                .OUT_W (SUM_OUT_W),
                .N_PAR (INTERP)
            ) u_sum (
                .clk       (clk_300m),
                .rst       (rst),
                .in_i_8p   (bsum_i_in),
                .in_q_8p   (bsum_q_in),
                .in_valid  (beam_valid_all),
                .out_i_8p  (sum_i[e]),
                .out_q_8p  (sum_q[e]),
                .out_valid (sum_valid[e])
            );
        end
    endgenerate

    // ---------- DAC 输出截位 (20bit → 16bit, 可配置右移量 + 饱和) ----------
    // 截位右移量 cfg_trunc (0-15, 默认 4): sum >>> cfg_trunc 后饱和到 DAC_W。
    // cfg_trunc=0 时无右移 (输出可能饱和), 通常 4 匹配原固定行为。
    function automatic logic signed [DAC_W-1:0] dac_sat(input logic signed [SUM_OUT_W-1:0] v);
        if (v >  ((1 <<< (DAC_W-1)) - 1)) return  ((1 <<< (DAC_W-1)) - 1);
        else if (v < -(1 <<< (DAC_W-1)))  return -(1 <<< (DAC_W-1));
        else return v[DAC_W-1:0];
    endfunction
    genvar d;
    generate
        for (d = 0; d < N_ELEM; d++) begin : g_dac
            always_ff @(posedge clk_300m) begin
                if (rst) begin
                    for (int p = 0; p < INTERP; p++) begin
                        dac_i_8p[d][p] <= '0;
                        dac_q_8p[d][p] <= '0;
                    end
                    dac_valid[d] <= 1'b0;
                end else begin
                    for (int p = 0; p < INTERP; p++) begin
                        dac_i_8p[d][p] <= dac_sat(sum_i[d][p] >>> cfg_trunc);
                        dac_q_8p[d][p] <= dac_sat(sum_q[d][p] >>> cfg_trunc);
                    end
                    dac_valid[d] <= sum_valid[d];
                end
            end
        end
    endgenerate

endmodule : tx_top

`endif // TX_TOP_SV
