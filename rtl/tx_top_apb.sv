`timescale 1ns/1ps

// =============================================================================
// tx_top_apb.sv  --  APB 薄包装: cfg_bus + tx_top(cfg端口)
// =============================================================================
// 保留原 tx_top 的 APB 接口, 内部桥接到 cfg_* 并行端口的 tx_top。
// tb_tx_top.sv 仅需把 DUT 名 tx_top → tx_top_apb 即可回归。
//
// 桥接说明: cfg_bus 输出 weight_re/im 为数组 [N_BEAM][N_ELEM] + sel_ch,
//   tx_top 期望标量 weight_re/im + sel_ch + load[4]。
//   用 load 高的波束 b 选中 cfg_weight_re[b][sel_ch] 作为标量输出。
// =============================================================================

`ifndef TX_TOP_APB_SV
`define TX_TOP_APB_SV
import tx_bf_pkg::*;

module tx_top_apb (
    input  logic                        clk_300m,
    input  logic                        arst,       // 高有效异步复位 (顶层入口, 内部同步)

    // 4 路基带复 IQ 输入
    input  logic signed [DATA_W-1:0]    bb_i [N_BEAM-1:0],
    input  logic signed [DATA_W-1:0]    bb_q [N_BEAM-1:0],
    input  logic                        bb_valid [N_BEAM-1:0],

    // APB 配置接口 (与原 tx_top 完全相同)
    input  logic                        apb_psel,
    input  logic                        apb_penable,
    input  logic                        apb_pwrite,
    input  logic [15:0]                 apb_paddr,
    input  logic [31:0]                 apb_pwdata,
    output logic                        apb_pready,
    output logic [31:0]                 apb_prdata,
    output logic                        apb_pslverr,

    // 8 路 RF-DAC 输出
    output logic signed [DAC_W-1:0]     dac_i_8p [N_ELEM-1:0][INTERP-1:0],
    output logic signed [DAC_W-1:0]     dac_q_8p [N_ELEM-1:0][INTERP-1:0],
    output logic                        dac_valid [N_ELEM-1:0]
);

    // ---------- 同步复位 ----------
    logic rst;
    reset_sync u_rst_sync (
        .clk         (clk_300m),
        .arst        (arst),
        .rst         (rst)
    );

    // ---------- cfg_bus 输出 (数组形式) ----------
    logic [$clog2(MAX_DELAY+1)-1:0] cfg_delay_val   [N_BEAM-1:0][N_ELEM-1:0];
    logic signed [COEF_W-1:0]       cfg_weight_re_arr [N_BEAM-1:0][N_ELEM-1:0];
    logic signed [COEF_W-1:0]       cfg_weight_im_arr [N_BEAM-1:0][N_ELEM-1:0];
    logic [DDS_PHASE_W-1:0]         cfg_phase_inc   [N_BEAM-1:0];
    logic [DDS_PHASE_W-1:0]         cfg_phase_offset[N_BEAM-1:0];
    logic                           cfg_fir_load    [N_BEAM-1:0];
    logic [$clog2(N_ELEM)-1:0]     cfg_fir_sel_ch;
    logic [$clog2(TAPS)-1:0]       cfg_fir_coef_addr;
    logic signed [COEF_W-1:0]       cfg_fir_coef_data;
    logic                           cfg_weight_load [N_BEAM-1:0];
    logic [$clog2(N_ELEM)-1:0]     cfg_weight_sel_ch;

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
        .cfg_weight_re   (cfg_weight_re_arr),
        .cfg_weight_im   (cfg_weight_im_arr),
        .cfg_phase_inc   (cfg_phase_inc),
        .cfg_phase_offset(cfg_phase_offset),
        .cfg_fir_load    (cfg_fir_load),
        .cfg_fir_sel_ch  (cfg_fir_sel_ch),
        .cfg_fir_coef_addr (cfg_fir_coef_addr),
        .cfg_fir_coef_data (cfg_fir_coef_data),
        .cfg_weight_load (cfg_weight_load),
        .cfg_weight_sel_ch (cfg_weight_sel_ch),
        .cfg_trunc       (4'd0)          // APB 路径 DBF 输出无右移 (默认)
    );

    // ---------- 权重数组 → 标量桥接 ----------
    // cfg_bus 一次写一个波束一个通道, weight_load[b] 高时选中波束 b 的 sel_ch 通道值
    logic [$clog2(N_BEAM)-1:0] weight_load_beam;
    always_comb begin
        weight_load_beam = '0;
        for (int b = 0; b < N_BEAM; b++)
            if (cfg_weight_load[b]) weight_load_beam = b[$clog2(N_BEAM)-1:0];
    end
    logic signed [COEF_W-1:0] cfg_weight_re_scalar;
    logic signed [COEF_W-1:0] cfg_weight_im_scalar;
    assign cfg_weight_re_scalar = cfg_weight_re_arr[weight_load_beam][cfg_weight_sel_ch];
    assign cfg_weight_im_scalar = cfg_weight_im_arr[weight_load_beam][cfg_weight_sel_ch];

    // ---------- tx_top (cfg_* 端口版) ----------
    tx_top u_tx (
        .clk_300m         (clk_300m),
        .rst              (rst),
        .bb_i             (bb_i),
        .bb_q             (bb_q),
        .bb_valid         (bb_valid),
        .cfg_delay_val    (cfg_delay_val),
        .cfg_phase_inc    (cfg_phase_inc),
        .cfg_phase_offset (cfg_phase_offset),
        .cfg_fir_load     (cfg_fir_load),
        .cfg_fir_sel_ch   (cfg_fir_sel_ch),
        .cfg_fir_coef_addr(cfg_fir_coef_addr),
        .cfg_fir_coef_data(cfg_fir_coef_data),
        .cfg_weight_load  (cfg_weight_load),
        .cfg_weight_sel_ch(cfg_weight_sel_ch),
        .cfg_weight_re    (cfg_weight_re_scalar),
        .cfg_weight_im    (cfg_weight_im_scalar),
        .dac_i_8p         (dac_i_8p),
        .dac_q_8p         (dac_q_8p),
        .dac_valid        (dac_valid)
    );

endmodule : tx_top_apb

`endif // TX_TOP_APB_SV
