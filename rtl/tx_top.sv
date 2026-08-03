// =============================================================================
// tx_top.sv  --  顶层: 4 波束 × 8 阵元 → 8 路复数 RF-DAC
// =============================================================================
// 单 FPGA 实体 (ZU48DR RFSoC), 两片 FPGA 组成 16 阵元系统。
//
// 数据流:
//   BB1..4 (300MHz 复 IQ) → 4× beam_duc (DBF+内插+上变频) → 4×8路复数 @2.4GHz等效
//     → 8× sum_4to1 (每阵元求 4 波束之和) → 8 路复数 I/Q (8并行 @300MHz)
//     → 截位 16bit → 8 路 RF-DAC (AXI-Stream, 复数 I/Q 模式)
//
// 内部: reset_sync + cfg_bus + 4 beam_duc + 8 sum_4to1
// =============================================================================

`ifndef TX_TOP_SV
`define TX_TOP_SV

`include "reset_sync.sv"
`include "cfg_bus.sv"
`include "beam_duc.sv"
`include "sum_4to1.sv"
import tx_bf_pkg::*;

module tx_top (
    input  logic                        clk_300m,      // 主时钟 300MHz
    input  logic                        async_rst_n,   // 异步复位 (低有效)

    // 4 路基带复 IQ 输入 (300MHz)
    input  logic signed [DATA_W-1:0]    bb_i [N_BEAM-1:0],
    input  logic signed [DATA_W-1:0]    bb_q [N_BEAM-1:0],
    input  logic                        bb_valid [N_BEAM-1:0],

    // APB 配置接口
    input  logic                        apb_psel,
    input  logic                        apb_penable,
    input  logic                        apb_pwrite,
    input  logic [15:0]                 apb_paddr,
    input  logic [31:0]                 apb_pwdata,
    output logic                        apb_pready,
    output logic [31:0]                 apb_prdata,
    output logic                        apb_pslverr,

    // 8 路 RF-DAC 输出 (复数 I/Q, 8 并行 @300MHz = 2.4Gs/s)
    output logic signed [DAC_W-1:0]     dac_i_8p [N_ELEM-1:0][INTERP-1:0],
    output logic signed [DAC_W-1:0]     dac_q_8p [N_ELEM-1:0][INTERP-1:0],
    output logic                        dac_valid [N_ELEM-1:0]
);

    // ---------- 全局同步释放复位 ----------
    logic rst;
    reset_sync u_rst_sync (
        .clk         (clk_300m),
        .async_rst_n (async_rst_n),
        .rst         (rst)
    );

    // ---------- 配置总线 ----------
    logic [$clog2(MAX_DELAY+1)-1:0] cfg_delay_val [N_BEAM-1:0][N_ELEM-1:0];
    logic signed [COEF_W-1:0]       cfg_weight_re [N_BEAM-1:0][N_ELEM-1:0];
    logic signed [COEF_W-1:0]       cfg_weight_im [N_BEAM-1:0][N_ELEM-1:0];
    logic [DDS_PHASE_W-1:0]         cfg_phase_inc [N_BEAM-1:0];
    logic [DDS_PHASE_W-1:0]         cfg_phase_offset [N_BEAM-1:0];
    logic                           cfg_fir_load [N_BEAM-1:0];
    logic [$clog2(N_ELEM)-1:0]     cfg_fir_sel_ch;
    logic [$clog2(TAPS)-1:0]       cfg_fir_coef_addr;
    logic signed [COEF_W-1:0]       cfg_fir_coef_data;

    cfg_bus u_cfg (
        .clk             (clk_300m),
        .rst             (rst),
        .apb_psel        (apb_psel),
        .apb_penable     (apb_penable),
        .apb_pwrite      (apb_pwrite),
        .apb_paddr       (apb_paddr),
        .apb_pwdata      (apb_pwdata),
        .apb_pready      (apb_pready),
        .apb_prdata      (apb_prdata),
        .apb_pslverr     (apb_pslverr),
        .cfg_delay_val   (cfg_delay_val),
        .cfg_weight_re   (cfg_weight_re),
        .cfg_weight_im   (cfg_weight_im),
        .cfg_phase_inc   (cfg_phase_inc),
        .cfg_phase_offset(cfg_phase_offset),
        .cfg_fir_load    (cfg_fir_load),
        .cfg_fir_sel_ch  (cfg_fir_sel_ch),
        .cfg_fir_coef_addr (cfg_fir_coef_addr),
        .cfg_fir_coef_data (cfg_fir_coef_data)
    );

    // ---------- 4 个波束处理单元 ----------
    logic signed [MIXER_OUT_W-1:0] beam_i [N_BEAM-1:0][N_ELEM-1:0][INTERP-1:0];
    logic signed [MIXER_OUT_W-1:0] beam_q [N_BEAM-1:0][N_ELEM-1:0][INTERP-1:0];
    logic                           beam_valid [N_BEAM-1:0];

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
                .weight_load    (1'b0),    // 权重由 cfg_bus 直接输出, 此处置 0
                .weight_sel_ch  ('0),
                .weight_re      ('0),
                .weight_im      ('0),
                .phase_inc      (cfg_phase_inc[b]),
                .phase_offset   (cfg_phase_offset[b]),
                .out_i          (beam_i[b]),
                .out_q          (beam_q[b]),
                .out_valid      (beam_valid[b])
            );
        end
    endgenerate

    // 注: tx_bf_core 的 weight_load 接口当前由 cfg_bus 直出寄存器, 但 tx_bf_core
    //   需要串行加载。此处简化: weight_load=0, 实际需将 cfg_weight_re/im 串行写入。
    //   TODO: 补充 weight 串行加载逻辑 (类似 FIR 系数加载口)。

    // ---------- 8 个阵元求和 (4 波束 → 1 路) ----------
    logic signed [SUM_OUT_W-1:0] sum_i [N_ELEM-1:0][INTERP-1:0];
    logic signed [SUM_OUT_W-1:0] sum_q [N_ELEM-1:0][INTERP-1:0];
    logic                        sum_valid [N_ELEM-1:0];

    genvar e;
    generate
        for (e = 0; e < N_ELEM; e++) begin : g_sum
            // 打包 4 波束对应阵元 e 的数据
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
                .in_valid  (beam_valid[0]),  // 4 波束 valid 同步 (同源等延迟)
                .out_i_8p  (sum_i[e]),
                .out_q_8p  (sum_q[e]),
                .out_valid (sum_valid[e])
            );
        end
    endgenerate

    // ---------- DAC 输出截位 (20bit → 16bit, 保符号截高位) ----------
    // sum 是 20bit (s20), DAC 16bit. 取高 16 位 [19:4], 保留 2bit 增益头。
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
                        dac_i_8p[d][p] <= sum_i[d][p][SUM_OUT_W-1 : SUM_OUT_W-DAC_W];
                        dac_q_8p[d][p] <= sum_q[d][p][SUM_OUT_W-1 : SUM_OUT_W-DAC_W];
                    end
                    dac_valid[d] <= sum_valid[d];
                end
            end
        end
    endgenerate

endmodule : tx_top

`endif // TX_TOP_SV
