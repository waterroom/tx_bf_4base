`timescale 1ns/1ps

// =============================================================================
// tx_bf_core.sv  --  16-channel wideband TX beamforming core (TTD)
// =============================================================================
// 把 1 路基带 IQ 分配到 16 个通道，每通道执行：
//   1) 整数延时 (int_delay.sv，移位寄存器，0 DSP)
//   2) 分数延时 FIR (frac_delay_fir.sv，16-tap FIR，系数动态加载，16 DSP)
//   3) 复数乘法 (cmult_3dsp.sv，3-DSP 全分离流水，相位补偿/波束扫描)
// 产生 16 路并行 IQ 输出，后续交由插值/DUC/JESD 处理。
//
// 数据广播：所有 16 个通道共享同一对 in_re/in_im，仅延时/FIR 系数/权重不同。
// 总流水延迟：delay_val + 34 个时钟（int_delay 2 + FIR 24 + cmult 7 + 输出 1）
// 目标频率：300 MHz
//
// 端口：
//   in_re/in_im    : 1 路基带 IQ 输入
//   delay_val[k]   : 通道 k 的整数延时 (0..MAX_DELAY)
//   fir_coef_*     : 复用接口，由软件串行加载每通道的 FIR 系数
//   weight_*       : 复用接口，由软件串行加载每通道的复数权重
//   out_re/out_im[k]: 16 路并行输出（18 位有符号，已饱和）
// =============================================================================

`ifndef TX_BF_CORE_SV
`define TX_BF_CORE_SV

`include "int_delay.sv"
`include "frac_delay_fir.sv"
`include "cmult_3dsp.sv"

module tx_bf_core #(
    parameter int unsigned N_CH        = 16,
    parameter int unsigned DATA_W       = 16,
    parameter int unsigned MAX_DELAY    = 64,    // 整数延时最大深度
    parameter int unsigned TAPS         = 16,    // FIR 抽头
    parameter int unsigned COEF_W       = 16,    // FIR 系数位宽
    parameter int unsigned FIR_OUT_W    = 18     // FIR 输出位宽 (= OUT_W)
) (
    input  logic                                       clk,
    input  logic                                       rst,

    // —— 1路基带 IQ 输入 ——
    input  logic signed [DATA_W-1:0]                   in_re,
    input  logic signed [DATA_W-1:0]                   in_im,
    input  logic                                       in_valid,

    // —— 每通道整数延时值 ——
    input  logic [$clog2(MAX_DELAY+1)-1:0]            delay_val [N_CH-1:0],

    // —— FIR 系数加载接口（每通道独立加载） ——
    // 用法：软件设置 fir_sel_ch 选中通道，逐 tap 写 coef_data
    input  logic                                       fir_coef_load,
    input  logic [$clog2(TAPS)-1:0]                   fir_coef_addr,
    input  logic signed [COEF_W-1:0]                  fir_coef_data,
    input  logic [$clog2(N_CH)-1:0]                   fir_sel_ch,

    // —— 复数权重加载接口（每通道独立加载，用于相位补偿/波束扫描） ——
    // 用法：软件设置 weight_sel_ch 选中通道，写 weight_re/weight_im
    input  logic                                       weight_load,
    input  logic [$clog2(N_CH)-1:0]                   weight_sel_ch,
    input  logic signed [COEF_W-1:0]                  weight_re,
    input  logic signed [COEF_W-1:0]                  weight_im,

    // —— 16 路并行输出 ——
    output logic signed [FIR_OUT_W-1:0]               out_re [N_CH-1:0],
    output logic signed [FIR_OUT_W-1:0]               out_im [N_CH-1:0],
    output logic                                       out_valid
);

    // ----------------------------------------------------------------
    // 整数延时后的中间信号（每通道一对 IQ）
    // ----------------------------------------------------------------
    logic signed [DATA_W-1:0] id_re [N_CH-1:0];
    logic signed [DATA_W-1:0] id_im [N_CH-1:0];
    logic                    id_v  [N_CH-1:0];

    // ----------------------------------------------------------------
    // 复数权重寄存器（每通道一对）
    // ----------------------------------------------------------------
    logic signed [COEF_W-1:0] w_re [N_CH-1:0];
    logic signed [COEF_W-1:0] w_im [N_CH-1:0];
    always_ff @(posedge clk) begin
        if (rst) begin
            for (int k = 0; k < N_CH; k++) begin
                w_re[k] <= '0;
                w_im[k] <= '0;
            end
        end else if (weight_load) begin
            w_re[weight_sel_ch] <= weight_re;
            w_im[weight_sel_ch] <= weight_im;
        end
    end

    // cmult_3dsp 输出（18 位，内部已饱和）
    logic signed [FIR_OUT_W-1:0] cmult_re [N_CH-1:0];
    logic signed [FIR_OUT_W-1:0] cmult_im [N_CH-1:0];
    logic                        cmult_v  [N_CH-1:0];

    // 8 通道 valid 对齐: 各通道 delay_val 不同, int_delay/frac_delay_fir/cmult 的
    // valid 到达时刻不同。取所有通道 valid 的与, 等最慢通道就绪后再输出,
    // 保证下游 8 通道并行 FIR IP 收到的 8 路数据同拍有效。
    // (数据本身的 TTD 时间差异是波束形成所需, 不受影响; 此处仅对齐 valid 时钟)
    logic all_cmult_v;
    always_comb begin
        all_cmult_v = 1'b1;
        for (int k = 0; k < N_CH; k++) all_cmult_v = all_cmult_v & cmult_v[k];
    end

    // ----------------------------------------------------------------
    // 16 通道例化
    // ----------------------------------------------------------------
    genvar k;
    generate
        for (k = 0; k < N_CH; k++) begin : g_ch

            // ---- 1) 整数延时 ----
            int_delay #(
                .DATA_W    (DATA_W),
                .MAX_DEPTH  (MAX_DELAY)
            ) u_intd (
                .clk        (clk),
                .rst      (rst),
                .valid_in   (in_valid),
                .in_re      (in_re),
                .in_im      (in_im),
                .delay_val  (delay_val[k]),
                .out_re     (id_re[k]),
                .out_im     (id_im[k]),
                .valid_out  (id_v[k])
            );

            // ---- 2) 分数延时 FIR（直接输出到 out_*）----
            // 系数加载：仅当 fir_sel_ch == k 时写本通道系数
            logic ch_coef_load;
            logic [$clog2(TAPS)-1:0]                   fir_coef_addr_sr;
            logic signed [COEF_W-1:0]                  fir_coef_data_sr;
            always_ff @(posedge clk) begin
                    ch_coef_load <= fir_coef_load & (fir_sel_ch == k[$clog2(N_CH)-1:0]);
                    fir_coef_addr_sr<=fir_coef_addr;
                    fir_coef_data_sr<=fir_coef_data;
            end
            

            // FIR 输出（中间信号）
            logic signed [FIR_OUT_W-1:0] fd_re, fd_im;
            logic                        fd_v;

            frac_delay_fir #(
                .TAPS       (TAPS),
                .DATA_W     (DATA_W),
                .COEF_W     (COEF_W),
                .ACC_W      (0),
                .OUT_W      (FIR_OUT_W),
                .PIPE_DEPTH (4)    // 300MHz: 乘法前加一级输入寄存
            ) u_fir (
                .clk        (clk),
                .rst        (rst),
                .valid_in   (id_v[k]),
                .in_re      (id_re[k]),
                .in_im      (id_im[k]),
                .coef_load  (ch_coef_load),
                .coef_addr  (fir_coef_addr_sr),
                .coef_data  (fir_coef_data_sr),
                .out_re     (fd_re),
                .out_im     (fd_im),
                .valid_out  (fd_v)
            );

            // ---- 3) 复数乘法（相位补偿/波束扫描，3-DSP 全分离流水）----
            cmult_3dsp #(
                .A_W   (FIR_OUT_W),                       // 18
                .B_W   (COEF_W),                          // 16
                .OUT_W (FIR_OUT_W)                        // 18（内部已饱和）
            ) u_cmult (
                .clk       (clk),
                .rst       (rst),
                .valid_in  (fd_v),
                .a_re      (fd_re),
                .a_im      (fd_im),
                .b_re      (w_re[k]),
                .b_im      (w_im[k]),
                .o_re      (cmult_re[k]),
                .o_im      (cmult_im[k]),
                .valid_out (cmult_v[k])
            );
        end
    endgenerate

    // ----------------------------------------------------------------
    // 输出寄存（cmult_3dsp 内部已饱和到 18 位，直接寄存输出）
    // ----------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (rst) begin
            for (int k = 0; k < N_CH; k++) begin
                out_re[k] <= '0;
                out_im[k] <= '0;
            end
            out_valid <= 1'b0;
        end else begin
            for (int k = 0; k < N_CH; k++) begin
                out_re[k] <= cmult_re[k];
                out_im[k] <= cmult_im[k];
            end
            out_valid <= all_cmult_v;   // 8 通道 valid 对齐后输出
        end
    end

endmodule : tx_bf_core

`endif // TX_BF_CORE_SV