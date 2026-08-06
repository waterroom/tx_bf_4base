`timescale 1ns/1ps

// =============================================================================
// da_data_gen.sv  --  顶层封装: 64b 报文配置 + tx_top 数据路径
// =============================================================================
// 两片 ZU48DR 各自独立运行一个 da_data_gen (8 元 4 波束), 合计 16 元。
// 内部: reset_sync×2 (dac_clk + cmd_clk) + decode_cmd_tx_bf + tx_top(cfg端口)
//
// 端口参考: C:\prj\z669\...\da_data_gen.sv (简化: 去掉 VIO/ILA/DUC IP)
// =============================================================================

`ifndef DA_DATA_GEN_SV
`define DA_DATA_GEN_SV
import tx_bf_pkg::*;

module da_data_gen (
    input  logic                        dac_coreclk,    // 数据路径时钟 (= clk_300m)
    // 分时钟域复位 (高有效同步复位, 由外部按各自时钟域产生)
    input  logic                        rst_dac,        // dac_coreclk 域复位 (高有效)
    input  logic                        rst_cmd,        // cmd_clk 域复位 (高有效)

    // 64b 并行报文配置接口
    input  logic                        cmd_clk,
    input  logic [63:0]                 cmd_data,
    input  logic                        cmd_data_valid,

    // 4 路基带复 IQ 输入 (300MHz)
    input  logic signed [DATA_W-1:0]    bb_i [N_BEAM-1:0],
    input  logic signed [DATA_W-1:0]    bb_q [N_BEAM-1:0],
    input  logic                        bb_valid [N_BEAM-1:0],

    // 8 路 RF-DAC 输出 (复数 I/Q, 8 并行 @300MHz = 2.4Gs/s)
    output logic signed [DAC_W-1:0]     dac_i_8p [N_ELEM-1:0][INTERP-1:0],
    output logic signed [DAC_W-1:0]     dac_q_8p [N_ELEM-1:0][INTERP-1:0],
    output logic                        dac_valid [N_ELEM-1:0],

    // apply 报文到达脉冲 (运行时重配握手, 可选)
    output logic                        rst_bf_request
);

    // ---------- 复位: 外部按时钟域提供高有效同步复位 ----------
    // dac 域: rst_dac 直接用 (decode rst_da_clk);
    //         tx_top 内部是 async_rst_n(低有效)+reset_sync, 取反转换
    // cmd 域: rst_cmd 直接用 (decode rst_cmd_clk)

    // ---------- decode 输出 cfg_* ----------
    logic [$clog2(MAX_DELAY+1)-1:0] cfg_delay_val    [N_BEAM-1:0][N_ELEM-1:0];
    logic [DDS_PHASE_W-1:0]         cfg_phase_inc    [N_BEAM-1:0];
    logic [DDS_PHASE_W-1:0]         cfg_phase_offset [N_BEAM-1:0];
    logic                           cfg_fir_load     [N_BEAM-1:0];
    logic [$clog2(N_ELEM)-1:0]      cfg_fir_sel_ch;
    logic [$clog2(TAPS)-1:0]        cfg_fir_coef_addr;
    logic signed [COEF_W-1:0]       cfg_fir_coef_data;
    logic                           cfg_weight_load  [N_BEAM-1:0];
    logic [$clog2(N_ELEM)-1:0]      cfg_weight_sel_ch;
    logic signed [COEF_W-1:0]       cfg_weight_re;
    logic signed [COEF_W-1:0]       cfg_weight_im;
    logic                           cfg_apply_pulse;

    decode_cmd_tx_bf u_decode (
        .da_clk          (dac_coreclk),
        .rst_da_clk      (rst_dac),
        .cmd_clk         (cmd_clk),
        .rst_cmd_clk     (rst_cmd),
        .cmd_data        (cmd_data),
        .cmd_data_valid  (cmd_data_valid),
        .delay_val       (cfg_delay_val),
        .phase_inc       (cfg_phase_inc),
        .phase_offset    (cfg_phase_offset),
        .fir_coef_load   (cfg_fir_load),
        .fir_sel_ch      (cfg_fir_sel_ch),
        .fir_coef_addr   (cfg_fir_coef_addr),
        .fir_coef_data   (cfg_fir_coef_data),
        .weight_load     (cfg_weight_load),
        .weight_sel_ch   (cfg_weight_sel_ch),
        .weight_re       (cfg_weight_re),
        .weight_im       (cfg_weight_im),
        .cfg_apply_pulse (cfg_apply_pulse)
    );
    assign rst_bf_request = cfg_apply_pulse;

    // ---------- tx_top (cfg_* 端口版) ----------
    // tx_top 内部是 async_rst_n(低有效)+reset_sync, 由 rst_dac(高有效)取反
    tx_top u_tx (
        .clk_300m         (dac_coreclk),
        .async_rst_n      (~rst_dac),
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
        .cfg_weight_re    (cfg_weight_re),
        .cfg_weight_im    (cfg_weight_im),
        .dac_i_8p         (dac_i_8p),
        .dac_q_8p         (dac_q_8p),
        .dac_valid        (dac_valid)
    );

endmodule : da_data_gen

`endif // DA_DATA_GEN_SV
