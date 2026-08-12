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

module da_data_gen #(
    // 片号 (0=片0, 1=片1): 16 元全局编址地址拆片, 两片各综合一次设不同值
    parameter int unsigned CHIP_ID = 0
)(
    input  logic                        dac_coreclk,    // 数据路径时钟 (= clk_300m)
    input  logic                        rst_dac,       // dac_coreclk 域异步复位 (高有效)


    // 64b 并行报文配置接口 
    input  logic                        rst_cmd,  // cmd_clk 域异步复位 (高有效)
    input  logic                        cmd_clk,
    input  logic [63:0]                 cmd_data,
    input  logic                        cmd_data_valid,

    // 4 路基带复 IQ 输入 (300MHz), 打包向量端口 (.v 顶层兼容):
    // 波束 b 的 16bit IQ 位于 [b*DATA_W +: DATA_W], valid 位 b
    input  logic signed [N_BEAM*DATA_W-1:0] bb_i,
    input  logic signed [N_BEAM*DATA_W-1:0] bb_q,
    input  logic [N_BEAM-1:0]               bb_valid,

    // DAC 输出经 AXI-Stream TDATA (见下方 sXX_axis_0_tdata 打包)

    // apply 报文到达脉冲 (配置已提交, 供外部主控协调两片)
    output logic                        rst_bf_request,
        // 两片 ZU48DR 同步: 本片收到 apply 报文并提交配置后拉高 rst_bf_request,
    // 供外部主控协调两片 (可同时拉高两片 rst_bf 做数据路径同步复位)
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

    // ---------- 两片同步: rst_bf 脉冲捕获 + 数据路径定时复位 ----------
    // rst_bf (外部主控给两片同时拉高): 8 拍移位寄存器按位或捕获
    // 每一个复位脉冲 (含短毛刺) 并展宽, 上升沿触发 RST_BF_WIDTH 拍
    // 定时复位 (rst_tx)。要求不漏复位请求, 不做防抖过滤。
    // 1 拍复位不够: 数据路径流水总 latency ~50-60 拍 (DDS ~8 + 混频 2 +
    // 3 级半带 FIR 每级 ~10-15 + 求和 2), 复位窗口必须覆盖内部流水
    // 排空, 否则复位释放后 latency 拍内输出仍是旧配置的过渡态。
    // 定时复位 (非电平): 主控只需拉高 ≥8 拍触发一次, 复位宽度硬件保证;
    // 两片各自复位 RST_BF_WIDTH 拍后同步恢复。
    // 配置提交 (delay/phase/FIR/weight) 均由 decode 内 apply 报文帧尾触发,
    // 不经 rst_bf。
    localparam int RST_BF_WIDTH = 64;   // ≥ 数据路径总 latency, 可调
    logic [7:0] rst_bf_reg;
    always_ff @(posedge dac_coreclk) begin
        if (rst_dac_sync) rst_bf_reg <= '0;
        else              rst_bf_reg <= {rst_bf_reg[6:0], rst_bf};
    end
    logic rst_bf_filt;
    // 按位或 = 捕获任意 rst_bf 高脉冲 (含 <8 拍毛刺), 移位展宽 8 拍 —
    // 保证不漏掉任何一个复位请求 (两片同步复位门必须抓住每次拉高),
    // filt 上升沿触发 RST_BF_WIDTH 拍定时复位。不用与 (&): 那是
    // 连续 8 拍确认 (防抖), 会漏掉短脉冲。
    assign rst_bf_filt = |rst_bf_reg;   // 捕获所有 rst_bf 脉冲, 展宽 8 拍
    // 捕获输出上升沿 → 1 拍触发脉冲
    logic rst_bf_filt_r, rst_bf_pulse;
    always_ff @(posedge dac_coreclk) begin
        if (rst_dac_sync) rst_bf_filt_r <= 0;
        else              rst_bf_filt_r <= rst_bf_filt;
    end
    assign rst_bf_pulse = rst_bf_filt & ~rst_bf_filt_r;
    // 数据路径复位: 上电复位 OR rst_bf 触发定时复位 (RST_BF_WIDTH 拍)
    logic [$clog2(RST_BF_WIDTH)-1:0] rst_bf_cnt;
    logic rst_tx;
    always_ff @(posedge dac_coreclk) begin
        if (rst_dac_sync) begin
            rst_bf_cnt <= '0;
            rst_tx     <= 1;
        end else if (rst_bf_pulse) begin
            rst_bf_cnt <= RST_BF_WIDTH - 1;   // 触发: 复位 RST_BF_WIDTH 拍
            rst_tx     <= 1;
        end else if (rst_bf_cnt != '0) begin
            rst_bf_cnt <= rst_bf_cnt - 1;     // 保持复位, 倒计时
            rst_tx     <= 1;
        end else begin
            rst_tx <= 0;
        end
    end

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
    logic [3:0]                     cfg_trunc;      // DAC 截位右移量 (decode 0x6704)

    decode_cmd_tx_bf #(.CHIP_ID(CHIP_ID)) u_decode (
        .da_clk          (dac_coreclk),
        .rst_da_clk      (rst_dac_sync),
        .cmd_clk         (cmd_clk),
        .rst_cmd_clk     (rst_cmd_sync),
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
        .cfg_apply_pulse (cfg_apply_pulse),
        .tx_bf_trunc     (cfg_trunc)
    );

    // ---------- tx_top 输出 → 内部 DAC 数据 (供 AXI-Stream TDATA 打包) ----------
    logic signed [DAC_W-1:0] dac_i_8p_int [N_ELEM-1:0][INTERP-1:0];
    logic signed [DAC_W-1:0] dac_q_8p_int [N_ELEM-1:0][INTERP-1:0];
    logic                    dac_valid_int [N_ELEM-1:0];

    // ================= 模拟基带源 (VIO 控制, 参考工程做法) =================
    // VIO probe_out0 = DDS 频率字 (up_dds0_incr), probe_out1 = 使能 (vio_dds0_en)。
    // 使能时: 内部 DDS 生成 4 波束同频正弦基带, 替代外部 bb 输入 (调试用,
    // 无外部基带也能输出信号); 使能上升沿 → rst_bf_request。
    wire [31:0] up_dds0_incr;
    wire        vio_dds0_en;
    vio_dac vio_dac0 (
        .clk       (dac_coreclk),
        .probe_in0 (1'b1),            // 输入探针占位 (无 clk_locked 可用)
        .probe_out0(up_dds0_incr),
        .probe_out1(vio_dds0_en)
    );
    // 使能上升沿捕获 (8 拍展宽, 不漏任何一次切换)
    reg vio_dds0_en_reg;
    always_ff @(posedge dac_coreclk) begin
        if (rst_dac_sync) vio_dds0_en_reg <= 0;
        else              vio_dds0_en_reg <= vio_dds0_en;
    end
    reg [7:0] vio_dds0_en_rise_reg;
    always_ff @(posedge dac_coreclk) begin
        if (rst_dac_sync) vio_dds0_en_rise_reg <= '0;
        else              vio_dds0_en_rise_reg <= {vio_dds0_en_rise_reg[6:0], ~vio_dds0_en_reg & vio_dds0_en};
    end
    wire vio_dds0_en_rise = |vio_dds0_en_rise_reg;

   
logic req_st;
always_ff @(posedge dac_coreclk) begin
    if (rst_dac_sync) begin
        req_st <= 0;
        rst_bf_request <= 0;        // ← 补上：复位时 request 也归 0
    end else case (req_st)
        0: begin
            rst_bf_request <= 0;
            if (cfg_apply_pulse || vio_dds0_en_rise)
                req_st <= 1'b1;
        end
        1: begin
            rst_bf_request <= 1;
            if (rst_bf_pulse)
                req_st <= 1'b0;
        end
    endcase
end

    // 内部基带 DDS (复用 dds_core_tx_bf_4base): {相位, 频率字}
    wire [31:0] base_tdata;
    dds_core_tx_bf_4base u_dds_base (
        .aclk               (dac_coreclk),
        .aclken             (1'b1),
        .aresetn            (~rst_dac_sync),
        .s_axis_phase_tvalid(1'b1),
        .s_axis_phase_tdata ({32'd0, up_dds0_incr}),
        .m_axis_data_tvalid (),
        .m_axis_data_tdata  (base_tdata)
    );
    wire signed [15:0] base_i = {base_tdata[13:0], 2'b00};   // cos (14bit<<2)
    wire signed [15:0] base_q = {base_tdata[29:16], 2'b00};  // sin (14bit<<2)
    // 基带 mux: VIO 使能 → 内部 DDS (4 波束同频), 否则外部 bb
    logic signed [N_BEAM*DATA_W-1:0] bb_i_eff, bb_q_eff;
    always_comb begin
        bb_i_eff = bb_i;
        bb_q_eff = bb_q;
        if (vio_dds0_en) begin
            for (int b = 0; b < N_BEAM; b++) begin
                bb_i_eff[b*DATA_W +: DATA_W] = base_i;
                bb_q_eff[b*DATA_W +: DATA_W] = base_q;
            end
        end
    end

    // ---------- tx_top (cfg_* 端口版, 同步高有效复位) ----------
    // 基带向量端口 → 数组拆包 (tx_top 内部用数组; 用 bb_*_eff: VIO 使能时是内部 DDS)
    logic signed [DATA_W-1:0] bb_i_arr [N_BEAM-1:0];
    logic signed [DATA_W-1:0] bb_q_arr [N_BEAM-1:0];
    logic                     bb_valid_arr [N_BEAM-1:0];
    always_comb begin
        for (int b = 0; b < N_BEAM; b++) begin
            bb_i_arr[b]    = bb_i_eff[b*DATA_W +: DATA_W];
            bb_q_arr[b]    = bb_q_eff[b*DATA_W +: DATA_W];
            // VIO 使能时强制 valid: 无外部基带 (bb_valid=0) 也能输出模拟基带
            bb_valid_arr[b] = bb_valid[b] | vio_dds0_en;
        end
    end
    tx_top u_tx (
        .clk_300m         (dac_coreclk),
        .rst              (rst_tx),
        .bb_i             (bb_i_arr),
        .bb_q             (bb_q_arr),
        .bb_valid         (bb_valid_arr),
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
        .cfg_trunc        (cfg_trunc),
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
