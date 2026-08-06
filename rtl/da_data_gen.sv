`timescale 1ns/1ps

// =============================================================================
// da_data_gen.sv  --  顶层封装: 64b 报文配置 + tx_top 数据路径
// =============================================================================
// 两片 ZU48DR 各自独立运行一个 da_data_gen (8 元 4 波束), 合计 16 元。
// 内部: reset_sync×2 (dac_clk + cmd_clk) + decode_cmd_tx_bf + tx_top(cfg端口)
//
// Ports aligned to external DA data path (no VIO/ILA/DUC IP)
// =============================================================================

`ifndef DA_DATA_GEN_SV
`define DA_DATA_GEN_SV
import tx_bf_pkg::*;

module da_data_gen (
    input  logic                        dac_coreclk,    // 数据路径时钟 (= clk_300m)
    input  logic                        rst_dac,       // dac_coreclk 域异步复位 (高有效)


    // 64b 并行报文配置接口 
    input  logic                        rst_cmd,  // cmd_clk 域异步复位 (高有效)
    input  logic                        cmd_clk,
    input  logic [63:0]                 cmd_data,
    input  logic                        cmd_data_valid,

    // 4 路基带复 IQ 输入 (300MHz)
    input  logic signed [DATA_W-1:0]    bb_i [N_BEAM-1:0],
    input  logic signed [DATA_W-1:0]    bb_q [N_BEAM-1:0],
    input  logic                        bb_valid [N_BEAM-1:0],

    // DAC 输出经 AXI-Stream TDATA (见下方 sXX_axis_0_tdata 打包)

    // apply 报文到达脉冲 (DDS 频率切换请求, 供外部主控触发两片同步)
    output logic                        rst_bf_request,
        // 两片 ZU48DR 同步: 切换 DDS 频率时本片拉高 rst_bf_request 请求,
    // 等待外部主控给两片同时拉高 rst_bf (同步), rst_bf 有效期间提交
    // 新 DDS 频率 (phase_inc) 并复位数据路径, 实现两片同步切换
    input  logic                        rst_bf,        // 两片同步复位门 (高有效)

    // ILA probe inputs (调试监控, 板级挂 ILA; 逻辑透传)
    input  wire                         dac0_nco_0_nco_update_busy,
    input  wire [47:0]                  dac0_nco_0_converter0_nco_freq,
    input  wire                         dac0_nco_0_nco_update_request,
    input  wire                         user_sysref_dac,
    // AXI-Stream TREADY inputs (ILA 监控用, 逻辑透传)
    input  wire                         s00_axis_0_tready,
    input  wire                         s02_axis_0_tready,
    input  wire                         s10_axis_0_tready,
    input  wire                         s12_axis_0_tready,
    input  wire                         s20_axis_0_tready,
    input  wire                         s22_axis_0_tready,
    input  wire                         s30_axis_0_tready,
    input  wire                         s32_axis_0_tready,

    // DAC data outputs (AXI-Stream TDATA, 每路 256bit = 8 并行 × 交替 {I,Q} 16bit)
    // s00=阵元0, s02=阵元1, s10=阵元2, s12=阵元3, s20=阵元4, s22=阵元5, s30=阵元6, s32=阵元7
    output logic [INTERP*32-1:0]        s00_axis_0_tdata,
    output logic [INTERP*32-1:0]        s02_axis_0_tdata,
    output logic [INTERP*32-1:0]        s10_axis_0_tdata,
    output logic [INTERP*32-1:0]        s12_axis_0_tdata,
    output logic [INTERP*32-1:0]        s20_axis_0_tdata,
    output logic [INTERP*32-1:0]        s22_axis_0_tdata,
    output logic [INTERP*32-1:0]        s30_axis_0_tdata,
    output logic [INTERP*32-1:0]        s32_axis_0_tdata
);

    // ---------- 顶层入口: 各时钟域异步复位各自同步一次 ----------
    // 端口 rst_dac/rst_cmd 为异步输入 (高有效), 同步后输出 rst_dac_sync/rst_cmd_sync
    logic rst_dac_sync, rst_cmd_sync;
    reset_sync u_rst_dac (
        .clk         (dac_coreclk),
        .arst        (rst_dac),
        .rst         (rst_dac_sync)
    );
    reset_sync u_rst_cmd (
        .clk         (cmd_clk),
        .arst        (rst_cmd),
        .rst         (rst_cmd_sync)
    );

    // ---------- 两片同步: rst_bf 滤波 + 数据路径复位门 ----------
    // rst_bf (外部主控给两片同时拉高) 8 拍移位滤波防抖 (参考工程做法),
    // 有效期间: 提交新 DDS 频率 (decode rst_bf 门) + 复位数据路径 (rst_tx)
    logic [7:0] rst_bf_reg;
    always_ff @(posedge dac_coreclk) begin
        if (rst_dac_sync) rst_bf_reg <= '0;
        else              rst_bf_reg <= {rst_bf_reg[6:0], rst_bf};
    end
    logic rst_bf_filt;
    assign rst_bf_filt = |rst_bf_reg;   // rst_bf 持续 8 拍以上视为有效
    // 数据路径复位: 上电复位 OR rst_bf 同步复位 (两片同步切频)
    logic rst_tx;
    assign rst_tx = rst_dac_sync | rst_bf_filt;

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
        .rst_da_clk      (rst_dac_sync),
        .cmd_clk         (cmd_clk),
        .rst_cmd_clk     (rst_cmd_sync),
        .cmd_data        (cmd_data),
        .cmd_data_valid  (cmd_data_valid),
        .rst_bf          (rst_bf_filt),   // 两片同步门: 有效时提交 delay/phase (DDS 频率)
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

    // ---------- tx_top 输出 → 内部 DAC 数据 (供 AXI-Stream TDATA 打包) ----------
    logic signed [DAC_W-1:0] dac_i_8p_int [N_ELEM-1:0][INTERP-1:0];
    logic signed [DAC_W-1:0] dac_q_8p_int [N_ELEM-1:0][INTERP-1:0];
    logic                    dac_valid_int [N_ELEM-1:0];

    // ---------- tx_top (cfg_* 端口版, 同步高有效复位) ----------
    tx_top u_tx (
        .clk_300m         (dac_coreclk),
        .rst              (rst_tx),
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
        .dac_i_8p         (dac_i_8p_int),
        .dac_q_8p         (dac_q_8p_int),
        .dac_valid        (dac_valid_int)
    );

    // ---------- AXI-Stream TDATA 打包 (参考工程格式) ----------
    // 每路 256bit = 8 并行样本 × 交替 {I[15:0], Q[15:0]}:
    //   tdata[16*2p+0 +: 16] = I[p], tdata[16*2p+1 +: 16] = Q[p]
    // 路映射: s00=阵元0, s02=阵元1, s10=阵元2, s12=阵元3,
    //         s20=阵元4, s22=阵元5, s30=阵元6, s32=阵元7
    // (SV 允许读 output 端口, 直接打包 dac_i_8p/dac_q_8p)
    assign s00_axis_0_tdata = {dac_q_8p_int[0][7], dac_i_8p_int[0][7], dac_q_8p_int[0][6], dac_i_8p_int[0][6],
                               dac_q_8p_int[0][5], dac_i_8p_int[0][5], dac_q_8p_int[0][4], dac_i_8p_int[0][4],
                               dac_q_8p_int[0][3], dac_i_8p_int[0][3], dac_q_8p_int[0][2], dac_i_8p_int[0][2],
                               dac_q_8p_int[0][1], dac_i_8p_int[0][1], dac_q_8p_int[0][0], dac_i_8p_int[0][0]};
    assign s02_axis_0_tdata = {dac_q_8p_int[1][7], dac_i_8p_int[1][7], dac_q_8p_int[1][6], dac_i_8p_int[1][6],
                               dac_q_8p_int[1][5], dac_i_8p_int[1][5], dac_q_8p_int[1][4], dac_i_8p_int[1][4],
                               dac_q_8p_int[1][3], dac_i_8p_int[1][3], dac_q_8p_int[1][2], dac_i_8p_int[1][2],
                               dac_q_8p_int[1][1], dac_i_8p_int[1][1], dac_q_8p_int[1][0], dac_i_8p_int[1][0]};
    assign s10_axis_0_tdata = {dac_q_8p_int[2][7], dac_i_8p_int[2][7], dac_q_8p_int[2][6], dac_i_8p_int[2][6],
                               dac_q_8p_int[2][5], dac_i_8p_int[2][5], dac_q_8p_int[2][4], dac_i_8p_int[2][4],
                               dac_q_8p_int[2][3], dac_i_8p_int[2][3], dac_q_8p_int[2][2], dac_i_8p_int[2][2],
                               dac_q_8p_int[2][1], dac_i_8p_int[2][1], dac_q_8p_int[2][0], dac_i_8p_int[2][0]};
    assign s12_axis_0_tdata = {dac_q_8p_int[3][7], dac_i_8p_int[3][7], dac_q_8p_int[3][6], dac_i_8p_int[3][6],
                               dac_q_8p_int[3][5], dac_i_8p_int[3][5], dac_q_8p_int[3][4], dac_i_8p_int[3][4],
                               dac_q_8p_int[3][3], dac_i_8p_int[3][3], dac_q_8p_int[3][2], dac_i_8p_int[3][2],
                               dac_q_8p_int[3][1], dac_i_8p_int[3][1], dac_q_8p_int[3][0], dac_i_8p_int[3][0]};
    assign s20_axis_0_tdata = {dac_q_8p_int[4][7], dac_i_8p_int[4][7], dac_q_8p_int[4][6], dac_i_8p_int[4][6],
                               dac_q_8p_int[4][5], dac_i_8p_int[4][5], dac_q_8p_int[4][4], dac_i_8p_int[4][4],
                               dac_q_8p_int[4][3], dac_i_8p_int[4][3], dac_q_8p_int[4][2], dac_i_8p_int[4][2],
                               dac_q_8p_int[4][1], dac_i_8p_int[4][1], dac_q_8p_int[4][0], dac_i_8p_int[4][0]};
    assign s22_axis_0_tdata = {dac_q_8p_int[5][7], dac_i_8p_int[5][7], dac_q_8p_int[5][6], dac_i_8p_int[5][6],
                               dac_q_8p_int[5][5], dac_i_8p_int[5][5], dac_q_8p_int[5][4], dac_i_8p_int[5][4],
                               dac_q_8p_int[5][3], dac_i_8p_int[5][3], dac_q_8p_int[5][2], dac_i_8p_int[5][2],
                               dac_q_8p_int[5][1], dac_i_8p_int[5][1], dac_q_8p_int[5][0], dac_i_8p_int[5][0]};
    assign s30_axis_0_tdata = {dac_q_8p_int[6][7], dac_i_8p_int[6][7], dac_q_8p_int[6][6], dac_i_8p_int[6][6],
                               dac_q_8p_int[6][5], dac_i_8p_int[6][5], dac_q_8p_int[6][4], dac_i_8p_int[6][4],
                               dac_q_8p_int[6][3], dac_i_8p_int[6][3], dac_q_8p_int[6][2], dac_i_8p_int[6][2],
                               dac_q_8p_int[6][1], dac_i_8p_int[6][1], dac_q_8p_int[6][0], dac_i_8p_int[6][0]};
    assign s32_axis_0_tdata = {dac_q_8p_int[7][7], dac_i_8p_int[7][7], dac_q_8p_int[7][6], dac_i_8p_int[7][6],
                               dac_q_8p_int[7][5], dac_i_8p_int[7][5], dac_q_8p_int[7][4], dac_i_8p_int[7][4],
                               dac_q_8p_int[7][3], dac_i_8p_int[7][3], dac_q_8p_int[7][2], dac_i_8p_int[7][2],
                               dac_q_8p_int[7][1], dac_i_8p_int[7][1], dac_q_8p_int[7][0], dac_i_8p_int[7][0]};

endmodule : da_data_gen

`endif // DA_DATA_GEN_SV
