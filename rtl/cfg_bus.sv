// =============================================================================
// cfg_bus.sv  --  APB 配置总线分发器
// =============================================================================
// APB 从机, 解码地址并分发配置给 4 个 beam_duc:
//   - 每波束: delay_val[8], weight_re[8], weight_im[8], phase_inc, phase_offset
//   - FIR 系数: 串行加载 (APB 写 fir_sel_ch/fir_coef_addr/fir_coef_data + load 脉冲)
//
// 地址映射 (32bit APB, 字地址):
//   基址 + beam*0x40:
//     0x00-0x07: delay_val[0..7]    (16bit, 低16位有效)
//     0x08-0x0F: weight_re[0..7]    (16bit)
//     0x10-0x17: weight_im[0..7]    (16bit)
//     0x18: phase_inc               (32bit)
//     0x19: phase_offset            (32bit)
//   0x20: FIR 系数加载口 (写: {fir_sel_ch[7:4], fir_coef_addr[3:0], fir_coef_data[15:0]})
//         beam 由地址基址决定, fir_sel_ch 为波束内通道号(0..7)
//
// 注: 简化版, 实际项目可扩展为 AXI-Lite + DMA 批量加载
// =============================================================================

`ifndef CFG_BUS_SV
`define CFG_BUS_SV

import tx_bf_pkg::*;

module cfg_bus #(
    parameter int unsigned N_BEAM_P = N_BEAM,    // 4
    parameter int unsigned N_CH_P   = N_ELEM     // 8
)(
    input  logic                        clk,
    input  logic                        rst,
    // APB 从机接口
    input  logic                        apb_psel,
    input  logic                        apb_penable,
    input  logic                        apb_pwrite,
    input  logic [15:0]                 apb_paddr,   // 字地址
    input  logic [31:0]                 apb_pwdata,
    output logic                        apb_pready,
    output logic [31:0]                 apb_prdata,
    output logic                        apb_pslverr,
    // 分发给 4 个 beam_duc 的配置
    output logic [$clog2(MAX_DELAY+1)-1:0] cfg_delay_val [N_BEAM_P-1:0][N_CH_P-1:0],
    output logic signed [COEF_W-1:0]   cfg_weight_re [N_BEAM_P-1:0][N_CH_P-1:0],
    output logic signed [COEF_W-1:0]   cfg_weight_im [N_BEAM_P-1:0][N_CH_P-1:0],
    output logic [DDS_PHASE_W-1:0]     cfg_phase_inc [N_BEAM_P-1:0],
    output logic [DDS_PHASE_W-1:0]     cfg_phase_offset [N_BEAM_P-1:0],
    // FIR 系数串行加载 (分发到对应波束)
    output logic                        cfg_fir_load [N_BEAM_P-1:0],
    output logic [$clog2(N_CH_P)-1:0]  cfg_fir_sel_ch,
    output logic [$clog2(TAPS)-1:0]   cfg_fir_coef_addr,
    output logic signed [COEF_W-1:0]   cfg_fir_coef_data,
    // 复数权重串行加载 (写 weight_re/im 寄存器时产生 load 脉冲, 配合
    // cfg_weight_re/im 数组选中通道的值, 由上层串行写入 tx_bf_core)
    output logic                        cfg_weight_load [N_BEAM_P-1:0],
    output logic [$clog2(N_CH_P)-1:0]  cfg_weight_sel_ch
);

    // ---------- 寄存器阵列 ----------
    logic [15:0] delay_reg   [N_BEAM_P-1:0][N_CH_P-1:0];
    logic [15:0] wre_reg     [N_BEAM_P-1:0][N_CH_P-1:0];
    logic [15:0] wim_reg     [N_BEAM_P-1:0][N_CH_P-1:0];
    logic [31:0] pinc_reg    [N_BEAM_P-1:0];
    logic [31:0] poff_reg    [N_BEAM_P-1:0];

    // APB 解码
    logic [3:0]  beam_idx;       // 波束索引 (地址高位)
    logic [5:0]  reg_idx;        // 波束内寄存器索引 (地址低 6 位)
    logic        is_fir_port;    // FIR 系数加载口
    logic        apb_write;
    assign beam_idx  = apb_paddr[10:6];  // 波束: 地址 [10:6], 每 beam 0x40 字
    assign reg_idx   = apb_paddr[5:0];
    assign is_fir_port = (reg_idx == 6'h20);
    assign apb_write  = apb_psel & apb_penable & apb_pwrite;

    // ---------- 写逻辑 ----------
    always_ff @(posedge clk) begin
        if (rst) begin
            for (int b = 0; b < N_BEAM_P; b++) begin
                for (int c = 0; c < N_CH_P; c++) begin
                    delay_reg[b][c] <= '0;
                    wre_reg[b][c]   <= '0;
                    wim_reg[b][c]   <= '0;
                end
                pinc_reg[b] <= '0;
                poff_reg[b] <= '0;
            end
        end else if (apb_write && beam_idx < N_BEAM_P) begin
            if (reg_idx < N_CH_P)
                delay_reg[beam_idx][reg_idx] <= apb_pwdata[15:0];
            else if (reg_idx >= 6'h08 && reg_idx < 6'h08 + N_CH_P)
                wre_reg[beam_idx][reg_idx - 6'h08] <= apb_pwdata[15:0];
            else if (reg_idx >= 6'h10 && reg_idx < 6'h10 + N_CH_P)
                wim_reg[beam_idx][reg_idx - 6'h10] <= apb_pwdata[15:0];
            else if (reg_idx == 6'h18)
                pinc_reg[beam_idx] <= apb_pwdata;
            else if (reg_idx == 6'h19)
                poff_reg[beam_idx] <= apb_pwdata;
        end
    end

    // ---------- FIR 系数加载口 ----------
    // 写 0x20 时: pwdata = {fir_sel_ch[7:4](忽略), fir_coef_addr[3:0], fir_coef_data[15:0]}
    //   实际: fir_sel_ch = pwdata[19:16], fir_coef_addr = pwdata[15:12], fir_coef_data = pwdata[11:0]? 
    //   简化: fir_sel_ch=pwdata[23:16], fir_coef_addr=pwdata[15:12], fir_coef_data=pwdata[11:0]不对
    //   重新定义: pwdata = {16'b0, fir_sel_ch[3:0], fir_coef_addr[3:0], fir_coef_data[15:0]}
    //   即 fir_sel_ch = pwdata[19:16], addr = pwdata[15:12]... 不对, 数据16bit
    //   定义: pwdata[31:16]=fir_coef_data, pwdata[15:12]=fir_coef_addr, pwdata[11:8]=fir_sel_ch
    assign cfg_fir_sel_ch    = apb_pwdata[11:8];
    assign cfg_fir_coef_addr = apb_pwdata[15:12];
    assign cfg_fir_coef_data = apb_pwdata[31:16];

    // FIR load 脉冲: 写 0x20 时对应波束产生 1 拍 load
    always_ff @(posedge clk) begin
        if (rst) begin
            for (int b = 0; b < N_BEAM_P; b++) cfg_fir_load[b] <= 1'b0;
        end else begin
            for (int b = 0; b < N_BEAM_P; b++)
                cfg_fir_load[b] <= apb_write & is_fir_port & (beam_idx == b[N_BEAM_P-1:0]);
        end
    end

    // ---------- 复数权重加载口 ----------
    // 写 weight_re[c] (0x08+c) 或 weight_im[c] (0x10+c) 时, 对应波束产生 1 拍 load 脉冲。
    // 寄存器已同步更新 (同一拍写, 下一拍组合输出新值), load 脉冲也在写后一拍产生,
    // 上层在 load 有效时用 cfg_weight_re/im[beam][sel_ch] 选中通道的值加载 tx_bf_core。
    logic is_weight_port;
    assign is_weight_port = (reg_idx >= 6'h08 && reg_idx < 6'h08 + N_CH_P) ||
                            (reg_idx >= 6'h10 && reg_idx < 6'h10 + N_CH_P);

    always_ff @(posedge clk) begin
        if (rst) begin
            for (int b = 0; b < N_BEAM_P; b++) cfg_weight_load[b] <= 1'b0;
        end else begin
            for (int b = 0; b < N_BEAM_P; b++)
                cfg_weight_load[b] <= apb_write & is_weight_port & (beam_idx == b[N_BEAM_P-1:0]);
        end
    end
    // 被写通道号: 由地址低 3 位给出 (0x08+c 或 0x10+c)
    assign cfg_weight_sel_ch = reg_idx[2:0];

    // ---------- 输出分发 ----------
    always_comb begin
        for (int b = 0; b < N_BEAM_P; b++) begin
            for (int c = 0; c < N_CH_P; c++) begin
                cfg_delay_val[b][c] = delay_reg[b][c];
                cfg_weight_re[b][c] = wre_reg[b][c];
                cfg_weight_im[b][c] = wim_reg[b][c];
            end
            cfg_phase_inc[b]    = pinc_reg[b];
            cfg_phase_offset[b] = poff_reg[b];
        end
    end

    // ---------- APB 读 + ready ----------
    always_ff @(posedge clk) begin
        if (rst) begin
            apb_pready  <= 1'b0;
            apb_prdata  <= '0;
            apb_pslverr <= 1'b0;
        end else begin
            apb_pready  <= apb_psel & apb_penable;   // 1 wait cycle
            apb_pslverr <= 1'b0;
            // 读数据 (简化: 仅读 delay_reg[0][0])
            if (apb_psel & apb_penable & ~apb_pwrite & beam_idx < N_BEAM_P) begin
                if (reg_idx < N_CH_P)
                    apb_prdata <= {16'b0, delay_reg[beam_idx][reg_idx]};
                else
                    apb_prdata <= '0;
            end
        end
    end

endmodule : cfg_bus

`endif // CFG_BUS_SV
