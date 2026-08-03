`timescale 1ns/1ps

// =============================================================================
// frac_delay_fir.sv  --  Parameterizable complex (I/Q) fractional-delay FIR
// =============================================================================
// 复数 FIR：对 I/Q 两路同时用同一组实数系数滤波（实现真时延的分数部分）。
// 等价于一个实 FIR 分别作用于 re/im，系数通过外部端口动态加载。
//
// 数据流（每通道 1 个实例）：
//   in_re/in_im ──> [taps-1:0] 复用移位线 ──> 乘法 ──> 加法树 ──> 截位 ──> out_re/out_im
//
// 关键点：
//   - 系数 coef[t] 为实数（16-bit 补码），由外部 BRAM/CSR 端口注入
//   - I/Q 共用同一系数（实 FIR），节省一半 DSP
//   - 系数加载：coef_load/coef_data/coef_addr 离线写入内部寄存器文件
//
// =============================================================================
// 时序/流水线说明（300 MHz 目标）
// -----------------------------------------------------------------------------
// 完整流水线化，移位线之后共 8 级寄存（PIPE_DEPTH=4, USE_INREG=1）：
//   S1: 输入寄存（srin <= sr），松移位线到乘法器的时序
//   S2: 乘法寄存（prod <= srin * coef），DSP M→P 路径
//   S3: 加法树 Level 0（16→8）
//   S4: 加法树 Level 1（8→4）
//   S5: 加法树 Level 2（4→2）
//   S6: 加法树 Level 3（2→1）
//   S7: bias 寄存（+2^14 偏置）
//   S8: sat 寄存（>>>15 + 饱和到 OUT_W）
//
//   数据延迟（移位线之后）= DATA_PIPE_STAGES = 7 + USE_INREG = 8
//   总延迟 = (TAPS-1) + 1(移位线本身) + 8 = TAPS + 8 = 24（TAPS=16）
//
//   valid 链：valid_sr[TAPS-1] → valid_q[0..DATA_PIPE_STAGES-1] → valid_out
//   长度 = DATA_PIPE_STAGES = 8，与数据路径严格对齐。
//
// 参数：
//   TAPS      : FIR 抽头数（默认 16）
//   DATA_W    : 输入 I/Q 位宽
//   COEF_W    : 系数位宽
//   ACC_W     : 累加器位宽（0 = 自动 = DATA_W + COEF_W + clog2(TAPS) + 1）
//   OUT_W     : 输出位宽
//   PIPE_DEPTH: 流水级数（默认 3，最小 3 = S2+S3+S4；>=4 时额外插入 S1 输入寄存）
// =============================================================================

`ifndef FRAC_DELAY_FIR_SV
`define FRAC_DELAY_FIR_SV

module frac_delay_fir #(
    parameter int unsigned TAPS      = 16,
    parameter int unsigned DATA_W    = 16,
    parameter int unsigned COEF_W    = 16,
    parameter int unsigned ACC_W     = 0,                       // 0 = 自动
    parameter int unsigned OUT_W     = 18,
    parameter int unsigned PIPE_DEPTH = 3                       // 流水级数(>=3)
) (
    input  logic                          clk,
    input  logic                          rst,          // 高有效
    input  logic                          valid_in,
    input  logic signed [DATA_W-1:0]     in_re,
    input  logic signed [DATA_W-1:0]     in_im,

    // 系数加载接口（同步串行写入寄存器文件）
    input  logic                          coef_load,    // 高有效写脉冲
    input  logic [$clog2(TAPS)-1:0]      coef_addr,
    input  logic signed [COEF_W-1:0]     coef_data,

    output logic signed [OUT_W-1:0]      out_re,
    output logic signed [OUT_W-1:0]      out_im,
    output logic                          valid_out
);

    // -------------- 位宽自动计算（与原文件保持一致） --------------
    function automatic int unsigned clog2_fn(input int unsigned v);
        int unsigned x = v, r = 0;
        if (v <= 1) return 0;
        while (x > 1) begin x = x >> 1; r = r + 1; end
        if ((1 << r) < v) r = r + 1;
        return r;
    endfunction

    localparam int unsigned ACC_W_LOCAL = (ACC_W == 0) ?
        (DATA_W + COEF_W + clog2_fn(TAPS) + 1) : ACC_W;

    // -------------- 流水级数控制 --------------
    // 实际数据流水（移位线之后）：
    //   [S1 输入寄存(可选)] + S2 乘法寄存 + 加法树4级 + bias + sat = 7 或 8 级
    // PIPE_DEPTH 仅控制是否插入 S1；valid 链必须匹配实际级数
    localparam int unsigned PIPE_LAT  = (PIPE_DEPTH < 3) ? 3 : PIPE_DEPTH;
    localparam int unsigned USE_INREG = (PIPE_LAT >= 4) ? 1 : 0;   // S1 使能
    // 实际数据寄存级数（移位线之后）：mult(1) + tree(4) + bias(1) + sat(1) = 7, +S1 = 8
    localparam int unsigned DATA_PIPE_STAGES = 7 + USE_INREG;

    // -------------- 系数寄存器（动态加载） --------------
    logic signed [COEF_W-1:0] coef [0:TAPS-1];
    always_ff @(posedge clk) begin
        if (rst) begin
            for (int i = 0; i < TAPS; i++) coef[i] <= '0;
        end else if (coef_load) begin
            coef[coef_addr] <= coef_data;
        end
    end

    // -------------- 复用移位寄存器（I/Q 共用抽头延迟线） --------------
    // 用 BRAM-friendly 单端口风格（综合器可推断为分布式 RAM/BRAM）
    logic signed [DATA_W-1:0] sr_re [0:TAPS-1];
    logic signed [DATA_W-1:0] sr_im [0:TAPS-1];
    logic                    valid_sr [0:TAPS-1];

    always_ff @(posedge clk) begin
        if (rst) begin
            for (int i = 0; i < TAPS; i++) begin
                sr_re[i]   <= '0;
                sr_im[i]   <= '0;
                valid_sr[i] <= 1'b0;
            end
        end else begin
            sr_re[0]   <= in_re;
            sr_im[0]   <= in_im;
            valid_sr[0] <= valid_in;
            for (int i = 1; i < TAPS; i++) begin
                sr_re[i]   <= sr_re[i-1];
                sr_im[i]   <= sr_im[i-1];
                valid_sr[i] <= valid_sr[i-1];
            end
        end
    end

    // -------------- Stage 1 (可选): 乘法器输入寄存器 --------------
    // 对移位线抽头做 1 级寄存，进一步松时序；USE_INREG=0 时直通
    logic signed [DATA_W-1:0] srin_re [0:TAPS-1];
    logic signed [DATA_W-1:0] srin_im [0:TAPS-1];

    generate
        if (USE_INREG) begin : g_inreg
            always_ff @(posedge clk) begin
                if (rst) begin
                    for (int i = 0; i < TAPS; i++) begin
                        srin_re[i] <= '0;
                        srin_im[i] <= '0;
                    end
                end else begin
                    for (int i = 0; i < TAPS; i++) begin
                        srin_re[i] <= sr_re[i];
                        srin_im[i] <= sr_im[i];
                    end
                end
            end
        end else begin : g_inreg_bypass
            for (genvar i = 0; i < TAPS; i++) begin : g_byp
                assign srin_re[i] = sr_re[i];
                assign srin_im[i] = sr_im[i];
            end
        end
    endgenerate

    // -------------- 乘法 (TAPS 个实数乘法/路) -- 组合 --------------
    // 乘法器输出在 Stage 2 被寄存，使综合器可把乘法映射到 DSP48 的 M->P 路径
    logic signed [DATA_W+COEF_W-1:0] mul_re [0:TAPS-1];
    logic signed [DATA_W+COEF_W-1:0] mul_im [0:TAPS-1];

    always_comb begin
        for (int i = 0; i < TAPS; i++) begin
            mul_re[i] = srin_re[i] * coef[i];
            mul_im[i] = srin_im[i] * coef[i];
        end
    end

    // -------------- Stage 2 (必需): 乘法结果寄存 --------------
    logic signed [DATA_W+COEF_W-1:0] prod_re_r [0:TAPS-1];
    logic signed [DATA_W+COEF_W-1:0] prod_im_r [0:TAPS-1];

    always_ff @(posedge clk) begin
        if (rst) begin
            for (int i = 0; i < TAPS; i++) begin
                prod_re_r[i] <= '0;
                prod_im_r[i] <= '0;
            end
        end else begin
            for (int i = 0; i < TAPS; i++) begin
                prod_re_r[i] <= mul_re[i];
                prod_im_r[i] <= mul_im[i];
            end
        end
    end

    // -------------- 加法树 (4 级流水, 时序友好) ------------------------------
    // 16→8→4→2→1，每级只有 1 个加法器，单级路径短
    localparam int unsigned PROD_W = DATA_W + COEF_W;
    localparam int unsigned EXTW   = (ACC_W_LOCAL > PROD_W) ? (ACC_W_LOCAL - PROD_W) : 0;

    // Level 0: 16 inputs → 8 sums
    logic signed [ACC_W_LOCAL-1:0] tree_re_0 [0:7];
    logic signed [ACC_W_LOCAL-1:0] tree_im_0 [0:7];
    // Level 1: 8 → 4
    logic signed [ACC_W_LOCAL-1:0] tree_re_1 [0:3];
    logic signed [ACC_W_LOCAL-1:0] tree_im_1 [0:3];
    // Level 2: 4 → 2
    logic signed [ACC_W_LOCAL-1:0] tree_re_2 [0:1];
    logic signed [ACC_W_LOCAL-1:0] tree_im_2 [0:1];
    // Level 3: 2 → 1
    logic signed [ACC_W_LOCAL-1:0] tree_re_3, tree_im_3;

    genvar i;
    generate
        // Level 0: 配对求和
        for (i = 0; i < 8; i++) begin : g_lvl0
            always_ff @(posedge clk) begin
                if (rst) begin
                    tree_re_0[i] <= '0;
                    tree_im_0[i] <= '0;
                end else begin
                    tree_re_0[i] <= {{EXTW{prod_re_r[2*i][PROD_W-1]}}, prod_re_r[2*i]}
                                 + {{EXTW{prod_re_r[2*i+1][PROD_W-1]}}, prod_re_r[2*i+1]};
                    tree_im_0[i] <= {{EXTW{prod_im_r[2*i][PROD_W-1]}}, prod_im_r[2*i]}
                                 + {{EXTW{prod_im_r[2*i+1][PROD_W-1]}}, prod_im_r[2*i+1]};
                end
            end
        end
        // Level 1
        for (i = 0; i < 4; i++) begin : g_lvl1
            always_ff @(posedge clk) begin
                if (rst) begin
                    tree_re_1[i] <= '0;
                    tree_im_1[i] <= '0;
                end else begin
                    tree_re_1[i] <= tree_re_0[2*i] + tree_re_0[2*i+1];
                    tree_im_1[i] <= tree_im_0[2*i] + tree_im_0[2*i+1];
                end
            end
        end
        // Level 2
        for (i = 0; i < 2; i++) begin : g_lvl2
            always_ff @(posedge clk) begin
                if (rst) begin
                    tree_re_2[i] <= '0;
                    tree_im_2[i] <= '0;
                end else begin
                    tree_re_2[i] <= tree_re_1[2*i] + tree_re_1[2*i+1];
                    tree_im_2[i] <= tree_im_1[2*i] + tree_im_1[2*i+1];
                end
            end
        end
        // Level 3
        always_ff @(posedge clk) begin
            if (rst) begin
                tree_re_3 <= '0;
                tree_im_3 <= '0;
            end else begin
                tree_re_3 <= tree_re_2[0] + tree_re_2[1];
                tree_im_3 <= tree_im_2[0] + tree_im_2[1];
            end
        end
    endgenerate

    // tree_re_3 / tree_im_3 即为累加结果

    // -------------- Stage 4a: 偏置 + 寄存（时序友好） ----------------
    logic signed [ACC_W_LOCAL:0] biased_re, biased_im;
    always_ff @(posedge clk) begin
        if (rst) begin
            biased_re <= '0;
            biased_im <= '0;
        end else begin
            biased_re <= {tree_re_3[ACC_W_LOCAL-1], tree_re_3} + (1 <<< 14);  // +2^14 偏置
            biased_im <= {tree_im_3[ACC_W_LOCAL-1], tree_im_3} + (1 <<< 14);
        end
    end

    // -------------- Stage 4b: 移位 + 饱和 + 寄存（时序友好） --------
    function automatic logic signed [OUT_W-1:0] sat(input logic signed [ACC_W_LOCAL:0] v);
        logic signed [ACC_W_LOCAL:0] shifted;
        begin
            shifted = signed'(v >>> 15);  // 右移 15 位（除以 32767）
            // 饱和到 OUT_W 位有符号范围
            if (shifted > $signed({1'b0, {(OUT_W-1){1'b1}}}))
                return {1'b0, {(OUT_W-1){1'b1}}};  // +max
            else if (shifted < -$signed({1'b0, {(OUT_W-1){1'b1}}}))
                return {1'b1, {(OUT_W-1){1'b0}}};  // -min
            else
                return shifted[OUT_W-1:0];
        end
    endfunction

    always_ff @(posedge clk) begin
        if (rst) begin
            out_re <= '0;
            out_im <= '0;
        end else begin
            out_re <= sat(biased_re);
            out_im <= sat(biased_im);
        end
    end

    // -------------- valid 流水寄存器链（与数据路径同级数对齐） --------------
    // 第一级由 valid_sr[TAPS-1] 喂入：标志当前 sr[] 窗口已完整。
    // 之后按 DATA_PIPE_STAGES 级数级联（匹配实际 7/8 级数据流水），末端即 valid_out。
    logic valid_q [0:DATA_PIPE_STAGES-1];

    always_ff @(posedge clk) begin
        if (rst) begin
            for (int i = 0; i < DATA_PIPE_STAGES; i++) valid_q[i] <= 1'b0;
        end else begin
            valid_q[0] <= valid_sr[TAPS-1];
            for (int i = 1; i < DATA_PIPE_STAGES; i++) valid_q[i] <= valid_q[i-1];
        end
    end

    assign valid_out = valid_q[DATA_PIPE_STAGES-1];

endmodule : frac_delay_fir

`endif // FRAC_DELAY_FIR_SV
