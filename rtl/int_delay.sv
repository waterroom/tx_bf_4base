`timescale 1ns/1ps

// =============================================================================
// int_delay.sv  --  Parameterized integer (full-sample) delay line
// =============================================================================
// 用移位寄存器实现整数个采样延迟。延迟值通过 delay_val 端口按通道配置，
// 最大深度由参数 MAX_DEPTH 决定。复数 I/Q 一同移位（共用一条延迟线）。
//
// 特点：
//   - 0 个 DSP（SRL 分段移位 + 二级多路选择，时序友好）
//   - 支持 valid 流水（valid 一同移位，保持帧对齐）
//   - delay_val 实时可变，建议与数据同步更新
//   - 复用为单通道：N=1 时退化为单根延迟线
//   - 输出延时: 行为仿真 delay_val+2 (shift_mem[0][0] 是寄存器);
//     综合成 SRLC32E 后 A=0 时 Q 组合直通 D → 硬件 delay_val+1 (差 1 拍,
//     后仿/上板为准, 需文档化对齐)
// 结构（避免大深度下 1025:1 单片 mux 的边界路径）：
//   存储按每段 32 深分段（SRL32 深度），段内用 sel_r[4:0] 地址读
//   （映射各 SRL 的地址线 Q 输出），段间级联，再用 sel_r 高位做
//   二级 N_SEG 选 1（LUT 树）——组合路径 ≈ 1~1.5 ns @ 300 MHz。
//   综合器自动推断为级联 SRLC32E（已加 srl_style="srl"），
//   延迟语义与单段结构完全一致（sel_r 提前寄存 + 输出寄存）。
// 参数：
//   DATA_W    : I/Q 各自位宽
//   MAX_DEPTH : 最大延迟深度（采样周期数），默认 64，可扩展至 1024;
//              下限 32 (SEG_IDX_W≥1, <32 时零宽 part-select 非法)
// =============================================================================

`ifndef INT_DELAY_SV
`define INT_DELAY_SV

module int_delay #(
    parameter int unsigned DATA_W    = 16,
    parameter int unsigned MAX_DEPTH  = 64
) (
    input  logic                          clk,
    input  logic                          rst,          // 高有效
    input  logic                          valid_in,
    input  logic signed [DATA_W-1:0]     in_re,
    input  logic signed [DATA_W-1:0]     in_im,
    input  logic [$clog2(MAX_DEPTH+1)-1:0] delay_val,   // 0..MAX_DEPTH
    output logic signed [DATA_W-1:0]     out_re,
    output logic signed [DATA_W-1:0]     out_im,
    output logic                          valid_out
);

    // -------------- 基础位宽 --------------
    localparam int unsigned STG_W = 2 * DATA_W;              // I/Q 打包位宽
    localparam int unsigned SEL_W = $clog2(MAX_DEPTH+1);     // 抽头选择位宽

    // -------------- SRL 分段参数 --------------
    // 每段 32 深（SRL32 深度），段内用 sel_r[4:0] 地址读，
    // 段间级联（段 j 的 [0] 收段 j-1 的 [31]，映射 SRL 的 Q31→D 级联）。
    localparam int unsigned SEG_BITS  = 5;
    localparam int unsigned SEG_LEN   = 1 << SEG_BITS;              // 32
    localparam int unsigned N_SEG     = (MAX_DEPTH + SEG_LEN) / SEG_LEN;
    localparam int unsigned SEG_IDX_W = SEL_W - SEG_BITS;

    // 分段移位寄存器：段 0 收当前输入，段内右移，段间级联
    // 注意：不复位，综合器推断为级联 SRLC32E（srl_style），省 FF；
    //       MAX_DEPTH=1024 时共 N_SEG=33 段 × 32 bit ≈ 1089 LUT/通道
    (* srl_style = "srl" *) logic [STG_W-1:0] shift_mem [0:N_SEG-1][0:SEG_LEN-1];
    (* srl_style = "srl" *) logic             valid_mem [0:N_SEG-1][0:SEG_LEN-1];

    always_ff @(posedge clk) begin
        shift_mem[0][0] <= {in_im, in_re};
        valid_mem[0][0] <= valid_in;
        for (int j = 0; j < N_SEG; j++) begin
            for (int i = 1; i < SEG_LEN; i++) begin
                shift_mem[j][i] <= shift_mem[j][i-1];
                valid_mem[j][i] <= valid_mem[j][i-1];
            end
            if (j > 0) begin
                shift_mem[j][0] <= shift_mem[j-1][SEG_LEN-1];
                valid_mem[j][0] <= valid_mem[j-1][SEG_LEN-1];
            end
        end
    end

    // -------------- 选择输出 --------------
    // sel_r 提前一拍寄存（选通提前，时序友好）；delay_val 超限时钳制到 MAX_DEPTH
    // 注意: 必须有复位 (sel_r 无复位时 X 传播到 SRL 数组索引, xsim 报 add_1 越界)
    logic [SEL_W-1:0] sel_r;
    always_ff @(posedge clk) begin
        if (rst)
            sel_r <= '0;
        else
            sel_r <= (delay_val > MAX_DEPTH) ? MAX_DEPTH[SEL_W-1:0] : delay_val[SEL_W-1:0];
    end

    // 一级选择：每段按段内地址读出一个抽头（各 SRL32 的地址读 Q 输出）
    logic [STG_W-1:0] tap   [0:N_SEG-1];
    logic             tap_v [0:N_SEG-1];
    always_comb begin
        for (int j = 0; j < N_SEG; j++) begin
            tap[j]   = shift_mem[j][sel_r[SEG_BITS-1:0]];
            tap_v[j] = valid_mem[j][sel_r[SEG_BITS-1:0]];
        end
    end

    // 二级选择：按段号 N_SEG 选 1（直接索引 → 综合器做平衡 mux 树;
    // 原 if 链是 33 级优先级 mux, 组合路径长且不保证重平衡）
    // 越界安全: sel_r 已钳制 ≤ MAX_DEPTH, 段号 ≤ MAX_DEPTH>>5 = N_SEG-1
    logic [STG_W-1:0] data_sel;
    logic             valid_sel;
    always_comb begin
        data_sel  = tap[sel_r[SEG_BITS +: SEG_IDX_W]];
        valid_sel = tap_v[sel_r[SEG_BITS +: SEG_IDX_W]];
    end

    // 输出寄存
    always_ff @(posedge clk) begin
        if (rst) begin
            out_re    <= '0;
            out_im    <= '0;
            valid_out <= 1'b0;
        end else begin
            out_re    <= data_sel[DATA_W-1:0];
            out_im    <= data_sel[2*DATA_W-1:DATA_W];
            valid_out <= valid_sel;
        end
    end

endmodule : int_delay

`endif // INT_DELAY_SV