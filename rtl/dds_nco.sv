// =============================================================================
// dds_nco.sv  --  可综合 NCO (相位累加器 + 1/4 波正弦 LUT, 8 并行输出)
// =============================================================================
// 产生 8 并行 cos/sin, 等效 2.4GHz 采样率 (每拍 8 个连续相位)。
// 32bit 相位累加器 → 截断高 16bit → 2bit 象限 + 10bit 查表 → 16bit cos/sin。
//
// 可综合性: 相位累加器 (FF) + LUT (推断为 BRAM/分布式RAM, $readmemh 初始化)
//   Vivado 综合支持 $readmemh 初始化 ROM, 仿真综合一致。
//   用户后续可替换为 Xilinx DDS Compiler IP 以节省资源 (接口兼容)。
//
// LUT 文件: scripts/gen_sin_lut.m 生成 ip/coef/sin_quarter.mem
//
// 端口:
//   phase_inc    : 32bit 相位步进 (f_LO = phase_inc / 2^32 * 2.4GHz)
//   phase_offset : 32bit 相位初值
//   cos_8p/sin_8p: 8 并行 16bit cos/sin 输出
//   流水延迟: 2 拍 (累加器 1 + 查表寄存 1)
// =============================================================================

`ifndef DDS_NCO_SV
`define DDS_NCO_SV

import tx_bf_pkg::*;

module dds_nco #(
    parameter int unsigned PHASE_W = DDS_PHASE_W,   // 32
    parameter int unsigned OUT_W    = DDS_OUT_W,    // 16
    parameter int unsigned N_PAR    = INTERP,       // 8
    parameter int unsigned LUT_BITS = 10            // 1/4 波 LUT 地址位宽 (1024 点)
)(
    input  logic                      clk,
    input  logic                      rst,
    input  logic [PHASE_W-1:0]        phase_inc,
    input  logic [PHASE_W-1:0]        phase_offset,
    output logic signed [OUT_W-1:0]   cos_8p [N_PAR-1:0],
    output logic signed [OUT_W-1:0]   sin_8p [N_PAR-1:0]
);

    localparam int LUT_DEPTH = 2**LUT_BITS;         // 1024
    localparam int PHASE_USE = OUT_W;               // 截断到 16bit 查表
    // 象限: bit[15:14], LUT 索引: bit[13:4] (10bit)

    // ---------- 相位累加器 ----------
    logic [PHASE_W-1:0] phase_acc;
    always_ff @(posedge clk) begin
        if (rst) phase_acc <= phase_offset;
        else     phase_acc <= phase_acc + phase_inc;
    end

    // ---------- 1/4 波正弦 LUT (0 ~ π/2, 1024 点, 16bit 有符号) ----------
    // 存储无偏移的 0~π/2 正弦值, 幅度 [-2^15, 2^15-1]
    // 路径: 默认 "sin_quarter.mem" (仿真时文件需在仿真工作目录),
    //       或用 -d SIN_QUARTER_MEM="完整路径" 覆盖 (见 scripts/run_sim.tcl)
`ifndef SIN_QUARTER_MEM
`define SIN_QUARTER_MEM "sin_quarter.mem"
`endif
    logic signed [OUT_W-1:0] sin_lut [0:LUT_DEPTH-1];
    initial begin
        $readmemh(`SIN_QUARTER_MEM, sin_lut);  // Vivado 综合 + 仿真均支持
    end

    // ---------- 8 并行相位计算 + 查表 ----------
    // 当前拍产生 8 个连续相位 (步进 phase_inc), 各自查表
    logic [PHASE_USE-1:0] phase_q [N_PAR-1:0];   // 截断后相位 (16bit)
    always_comb begin
        phase_q[0] = phase_acc[PHASE_W-1 : PHASE_W-PHASE_USE];
        for (int p = 1; p < N_PAR; p++)
            phase_q[p] = phase_q[p-1] + phase_inc[PHASE_W-1 : PHASE_W-PHASE_USE];
    end

    // 象限与索引分解: bit[15:14]=象限, bit[13:4]=LUT 索引
    always_ff @(posedge clk) begin
        if (rst) begin
            for (int p = 0; p < N_PAR; p++) begin
                cos_8p[p] <= '0;
                sin_8p[p] <= '0;
            end
        end else begin
            for (int p = 0; p < N_PAR; p++) begin
                automatic logic [1:0]               quad = phase_q[p][PHASE_USE-1 : PHASE_USE-2];
                automatic logic [LUT_BITS-1:0]      idx  = phase_q[p][PHASE_USE-3 : PHASE_USE-2-LUT_BITS];
                automatic logic [LUT_BITS-1:0]      idx_inv = LUT_DEPTH - 1 - idx;
                automatic logic signed [OUT_W-1:0]  s_q, c_q;  // 当前象限 sin/cos (第一象限值)

                // 1/4 波对称: 第一象限 sin=lut[idx], cos=lut[idx_inv]
                s_q = sin_lut[idx];
                c_q = sin_lut[idx_inv];

                // 按象限还原符号 (标准三角函数象限规则)
                case (quad)
                    2'b00: begin sin_8p[p] <=  s_q;            cos_8p[p] <=  c_q;            end
                    2'b01: begin sin_8p[p] <=  c_q;            cos_8p[p] <= -s_q;            end
                    2'b10: begin sin_8p[p] <= -s_q;            cos_8p[p] <= -c_q;            end
                    2'b11: begin sin_8p[p] <= -c_q;            cos_8p[p] <=  s_q;            end
                endcase
            end
        end
    end

endmodule : dds_nco

`endif // DDS_NCO_SV
