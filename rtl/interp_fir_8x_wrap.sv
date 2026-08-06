`timescale 1ns/1ps

// =============================================================================
// interp_fir_8x_wrap.sv  --  8 倍内插 FIR 包装 (8 通道, 8 并行输出)
// =============================================================================
// 输入: 8 通道, 每通道 1 样本/拍 @300MHz (复 IQ 的 I 或 Q 之一, 18bit)
// 输出: 8 通道, 每通道 8 并行样本/拍 @300MHz (等效 2.4GHz)
//
// 滤波器: 48 抽头 Type2 线性相位 FIR, 88MHz 通带, 8 倍内插
//   系数来自 rtl/fdacoefs_fir_300Mto2400M_88Mpass.h (int16, s16,15)
//
// 实现:
//   - 仿真/默认: 可综合多相 FIR (8 相位 × 6 抽头/相位, DSP 推断)
//     注: 此版本 DSP 用量大 (8ch×8ph×6tap=384 DSP/IQ), 仅适合仿真或单波束验证
//   - 综合优化: 定义 `USE_XILINX_FIR_IP 宏后例化 Xilinx FIR Compiler IP
//     (8 通道, 8 倍内插, 对称系数, 多通道时分复用 DSP, 资源最优)
//
// 多相公式: y_p[n] = sum_{j=0}^{5} h[p+8*j] * x[n-j],  p=0..7
//   每输入样本产生 8 个并行输出 (对应 8 个内插相位)
//
// 流水延迟: 7 拍 (输入寄存 1 + 移位寄存 1 + 乘法 1 + 两两相加 1 + 三输入和 C1 1 + C2 1 + 输出 1)
//   三输入和拆两级: 每级仅 1 个 37bit 加法, 300MHz 时序友好
// =============================================================================

`ifndef INTERP_FIR_8X_WRAP_SV
`define INTERP_FIR_8X_WRAP_SV

import tx_bf_pkg::*;

module interp_fir_8x_wrap #(
    parameter int unsigned IN_W   = FIR_OUT_W,    // 18
    parameter int unsigned OUT_W  = FIR_OUT_W,    // 18
    parameter int unsigned N_CH   = N_ELEM,       // 8 通道
    parameter int unsigned N_PAR  = INTERP,       // 8 并行
    parameter int unsigned TAPS   = 48,           // 48 抽头
    parameter int unsigned COEF_W = 16            // 系数位宽
)(
    input  logic                      clk,
    input  logic                      rst,
    input  logic signed [IN_W-1:0]    in_data  [N_CH-1:0],   // 8 通道输入
    input  logic                      in_valid,
    output logic signed [OUT_W-1:0]   out_data [N_CH-1:0][N_PAR-1:0], // 8ch×8并行
    output logic                      out_valid
);

    // ---------- 48 抽头系数 (int16, 来自 fdacoefs_fir_300Mto2400M_88Mpass.h) ----------
    localparam logic signed [COEF_W-1:0] COEFF [0:TAPS-1] = '{
        16'sd8,    16'sd196,  16'sd207,  16'sd275,  16'sd310,  16'sd292,
        16'sd202,  16'sd30,   -16'sd216, -16'sd514, -16'sd818, -16'sd1072,
        -16'sd1204,-16'sd1148,-16'sd846, -16'sd265, 16'sd597,  16'sd1705,
        16'sd2984, 16'sd4332, 16'sd5626, 16'sd6739, 16'sd7554, 16'sd7985,
        16'sd7985, 16'sd7554, 16'sd6739, 16'sd5626, 16'sd4332, 16'sd2984,
        16'sd1705, 16'sd597,  -16'sd265, -16'sd846, -16'sd1148,-16'sd1204,
        -16'sd1072,-16'sd818, -16'sd514, -16'sd216, 16'sd30,   16'sd202,
        16'sd292,  16'sd310,  16'sd275,  16'sd207,  16'sd196,  16'sd8
    };
    localparam int TAPS_PER_PHASE = TAPS / N_PAR;   // 6

    // ---------- 可综合多相 FIR (仿真/默认) ----------
    // 注: 综合优化时定义 USE_XILINX_FIR_IP 改用 Xilinx FIR Compiler IP
    // (此处手写版本 DSP 用量大, 适合仿真)

    // 输入寄存
    logic signed [IN_W-1:0] in_r [N_CH-1:0];
    logic v_in;
    always_ff @(posedge clk) begin
        if (rst) begin
            for (int c = 0; c < N_CH; c++) in_r[c] <= '0;
            v_in <= 1'b0;
        end else begin
            for (int c = 0; c < N_CH; c++) in_r[c] <= in_data[c];
            v_in <= in_valid;
        end
    end

    // 每通道移位寄存器 (6 样本)
    logic signed [IN_W-1:0] shift_reg [N_CH-1:0][TAPS_PER_PHASE-1:0];
    always_ff @(posedge clk) begin
        if (rst) begin
            for (int c = 0; c < N_CH; c++)
                for (int t = 0; t < TAPS_PER_PHASE; t++)
                    shift_reg[c][t] <= '0;
        end else if (v_in) begin
            for (int c = 0; c < N_CH; c++) begin
                shift_reg[c][0] <= in_r[c];
                for (int t = 1; t < TAPS_PER_PHASE; t++)
                    shift_reg[c][t] <= shift_reg[c][t-1];
            end
        end
    end

    // ---------- 流水 MAC: 6 抽头乘加, 3 级流水 (时序友好) ----------
    //   Stage A: 6 个并行乘法 (各 1 个 DSP, 寄存)
    //   Stage B: 两两相加 (p0+p1)(p2+p3)(p4+p5), 寄存
    //   Stage C: 三输入求和, 得 mac_out
    // 每级仅 1 次乘法或 1~2 级加法, 300MHz 可收敛
    localparam int P_W = IN_W + COEF_W;              // 34 (乘积位宽)
    localparam int ACC_W = IN_W + COEF_W + $clog2(TAPS_PER_PHASE);  // 37
    logic signed [P_W-1:0]   prod    [N_CH-1:0][N_PAR-1:0][TAPS_PER_PHASE-1:0];
    logic signed [P_W:0]     pair01  [N_CH-1:0][N_PAR-1:0];
    logic signed [P_W:0]     pair23  [N_CH-1:0][N_PAR-1:0];
    logic signed [P_W:0]     pair45  [N_CH-1:0][N_PAR-1:0];
    logic signed [ACC_W-1:0] mac_out [N_CH-1:0][N_PAR-1:0];
    logic v_prod, v_pair, v_mac;

    // Stage A: 6 个并行乘积
    always_ff @(posedge clk) begin
        if (rst) begin
            for (int c = 0; c < N_CH; c++)
                for (int p = 0; p < N_PAR; p++)
                    for (int j = 0; j < TAPS_PER_PHASE; j++)
                        prod[c][p][j] <= '0;
            v_prod <= 1'b0;
        end else begin
            for (int c = 0; c < N_CH; c++)
                for (int p = 0; p < N_PAR; p++)
                    for (int j = 0; j < TAPS_PER_PHASE; j++)
                        prod[c][p][j] <= shift_reg[c][j] * COEFF[p + N_PAR*j];
            v_prod <= v_in;
        end
    end

    // Stage B: 两两相加
    always_ff @(posedge clk) begin
        if (rst) begin
            for (int c = 0; c < N_CH; c++)
                for (int p = 0; p < N_PAR; p++) begin
                    pair01[c][p] <= '0;
                    pair23[c][p] <= '0;
                    pair45[c][p] <= '0;
                end
            v_pair <= 1'b0;
        end else begin
            for (int c = 0; c < N_CH; c++)
                for (int p = 0; p < N_PAR; p++) begin
                    pair01[c][p] <= {prod[c][p][0][P_W-1], prod[c][p][0]} + {prod[c][p][1][P_W-1], prod[c][p][1]};
                    pair23[c][p] <= {prod[c][p][2][P_W-1], prod[c][p][2]} + {prod[c][p][3][P_W-1], prod[c][p][3]};
                    pair45[c][p] <= {prod[c][p][4][P_W-1], prod[c][p][4]} + {prod[c][p][5][P_W-1], prod[c][p][5]};
                end
            v_pair <= v_prod;
        end
    end

    // Stage C: 三输入求和拆两级, 每级仅 1 个 37bit 加法 (消除 2 级加法链)
    //   C1: sum12 = pair01 + pair23 (并寄存 pair45 延迟对齐)
    //   C2: mac_out = sum12 + pair45_d1
    logic signed [P_W:0]   pair45_d1 [N_CH-1:0][N_PAR-1:0];
    logic signed [ACC_W-1:0] sum12    [N_CH-1:0][N_PAR-1:0];
    logic v_sum12;
    always_ff @(posedge clk) begin
        if (rst) begin
            for (int c = 0; c < N_CH; c++)
                for (int p = 0; p < N_PAR; p++) begin
                    sum12[c][p]     <= '0;
                    pair45_d1[c][p] <= '0;
                end
            v_sum12 <= 1'b0;
        end else begin
            for (int c = 0; c < N_CH; c++)
                for (int p = 0; p < N_PAR; p++) begin
                    sum12[c][p] <= {{(ACC_W-P_W-1){pair01[c][p][P_W]}}, pair01[c][p]}
                                 + {{(ACC_W-P_W-1){pair23[c][p][P_W]}}, pair23[c][p]};
                    pair45_d1[c][p] <= pair45[c][p];
                end
            v_sum12 <= v_pair;
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            for (int c = 0; c < N_CH; c++)
                for (int p = 0; p < N_PAR; p++)
                    mac_out[c][p] <= '0;
            v_mac <= 1'b0;
        end else begin
            for (int c = 0; c < N_CH; c++)
                for (int p = 0; p < N_PAR; p++)
                    mac_out[c][p] <= sum12[c][p] + {{(ACC_W-P_W-1){pair45_d1[c][p][P_W]}}, pair45_d1[c][p]};
            v_mac <= v_sum12;
        end
    end

    // 输出寄存 + 舍入截位到 OUT_W
    // mac_out 是 37bit (s37,15: 18bit输入×16bit系数=34bit乘积 + 3bit累加, 15位小数)
    // 流程: (acc + 2^14) >>> 15 → 23bit → 饱和到 18bit
    localparam int SHIFT = COEF_W - 1;   // 15 (s16,15 系数, 除以 32768)
    localparam int POST_W = ACC_W - SHIFT + 1;  // 23 (舍入后整数位宽)
    function automatic logic signed [OUT_W-1:0] sat_fir(input logic signed [POST_W-1:0] v);
        logic signed [POST_W-1:0] vmax, vmin;
        vmax = (1 << (OUT_W-1)) - 1;     // 2^17 - 1
        vmin = -(1 << (OUT_W-1));        // -2^17
        if (v > vmax)       return vmax[OUT_W-1:0];
        else if (v < vmin)  return vmin[OUT_W-1:0];
        else                return v[OUT_W-1:0];
    endfunction

    always_ff @(posedge clk) begin
        if (rst) begin
            for (int c = 0; c < N_CH; c++)
                for (int p = 0; p < N_PAR; p++)
                    out_data[c][p] <= '0;
            out_valid <= 1'b0;
        end else begin
            for (int c = 0; c < N_CH; c++) begin
                for (int p = 0; p < N_PAR; p++) begin
                    // 四舍五入: (acc + 2^14) >>> 15
                    automatic logic signed [ACC_W:0] biased;        // 38bit
                    automatic logic signed [POST_W-1:0] shifted;    // 23bit
                    biased  = {mac_out[c][p][ACC_W-1], mac_out[c][p]} + (1 <<< (SHIFT-1));
                    shifted = signed'(biased >>> SHIFT);
                    out_data[c][p] <= sat_fir(shifted);
                end
            end
            out_valid <= v_mac;
        end
    end

    // TODO (综合优化): 定义 USE_XILINX_FIR_IP 后, 替换上方为 Xilinx FIR Compiler 例化
    // IP 配置: Interpolation=8, 8通道, 48抽头对称, AXI-Stream, 8并行输出
    // 资源: ~24 DSP/IP (对称+多相+多通道时分), vs 手写 384 DSP/IQ

endmodule : interp_fir_8x_wrap

`endif // INTERP_FIR_8X_WRAP_SV
