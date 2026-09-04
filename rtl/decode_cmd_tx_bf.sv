`timescale 1ns/1ps

// =============================================================================
// decode_cmd_tx_bf.sv  --  64b 并行报文配置解码器 (适配 tx_bf_4base)
// =============================================================================
// Standard 64b packet protocol (CDC FIFO + 11-state FSM + frame)
// 适配:
//   - 2D 寄存器: delay/weight/FIR 按 beam×ch 索引 (idx=beam*16+ch, 0..63)
//   - FIR 系数: 数据内嵌 tap_addr (data[19:16]), 立即加载 (不经 apply)
//   - 权重: 立即加载 (不经 apply)
//   - delay/phase_inc/phase_offset: apply 提交 (Function_id=0xDABF_000B)
//   - 新增 phase_offset (0x6706), tx_bf_trunc (0x6704, DAC 截位右移量)
//   - phase_inc/offset 每波束独立 (0x6705/06 + beam)
//
// 报文格式: 64b 并行, 帧头 0x7E8118E7, 帧尾 0x8F9009F8
// 寄存器映射: 见 doc/da_data_gen_interface.md
// =============================================================================

`ifndef DECODE_CMD_TX_BF_SV
`define DECODE_CMD_TX_BF_SV

import tx_bf_pkg::*;

module decode_cmd_tx_bf #(
    parameter int unsigned CMD_DATA_LEN = 64,
    parameter int unsigned N_BEAM_P     = N_BEAM,     // 4
    parameter int unsigned N_CH_P       = N_ELEM,     // 8
    parameter int unsigned MAX_DELAY_P  = MAX_DELAY,  // 64
    parameter int unsigned TAPS_P       = TAPS,       // 16
    parameter int unsigned COEF_W_P     = COEF_W,     // 16
    parameter int unsigned DDS_PHASE_W_P= DDS_PHASE_W, // 32
    // 本片地址: 报文 Dest_id 匹配才解析 (两片 ZU48DR 各设不同值)
    parameter int unsigned CHIP_ID = 0                 // 片号 (0=片0, 1=片1): 地址拆片
)(
    input  logic                                              da_clk,
    input  logic                                              rst_da_clk,
    input  logic                                              cmd_clk,
    input  logic                                              rst_cmd_clk,
    input  logic [CMD_DATA_LEN-1:0]                           cmd_data,
    input  logic                                              cmd_data_valid,

    // 每波束×通道整数延时 (apply 提交)
    output logic [$clog2(MAX_DELAY_P+1)-1:0]                  delay_val    [N_BEAM_P-1:0][N_CH_P-1:0],
    // DDS 频率字/初始相位 (apply 提交)
    output logic [DDS_PHASE_W_P-1:0]                          phase_inc    [N_BEAM_P-1:0],
    output logic [DDS_PHASE_W_P-1:0]                          phase_offset [N_BEAM_P-1:0],
    // FIR 系数串行加载 (立即)
    output logic                                              fir_coef_load [N_BEAM_P-1:0],
    output logic [$clog2(N_CH_P)-1:0]                         fir_sel_ch,
    output logic [$clog2(TAPS_P)-1:0]                         fir_coef_addr,
    output logic signed [COEF_W_P-1:0]                        fir_coef_data,
    // 复数权重串行加载 (立即)
    output logic                                              weight_load  [N_BEAM_P-1:0],
    output logic [$clog2(N_CH_P)-1:0]                         weight_sel_ch,
    output logic signed [COEF_W_P-1:0]                        weight_re,
    output logic signed [COEF_W_P-1:0]                        weight_im,
    // apply 脉冲 (报文 Function_id=0xDABF_000B 命中时 1 拍)
    output logic                                              cfg_apply_pulse,
    // DAC 截位右移量 (0x6704, 默认 4 = SUM_OUT_W-DAC_W, 立即生效)
    output logic [3:0]                                        tx_bf_trunc
);

    genvar i;
    localparam int IDX_W = $clog2(N_BEAM_P * N_CH_P);  // idx 位宽 (5bit for 32)

    // ========================================================================
    // 1. CDC FIFO (cmd_clk → da_clk)
    // ========================================================================
    wire [63:0]    da_data;
    wire           da_data_valid;
    wire           fifo_empty;

    xpm_fifo_async #(
        .CDC_SYNC_STAGES(2),
        .DOUT_RESET_VALUE("0"),
        .ECC_MODE("no_ecc"),
        .FIFO_MEMORY_TYPE("auto"),
        .FIFO_READ_LATENCY(1),
        .FIFO_WRITE_DEPTH(512),
        .FULL_RESET_VALUE(0),
        .PROG_EMPTY_THRESH(10),
        .PROG_FULL_THRESH(10),
        .RD_DATA_COUNT_WIDTH(1),
        .READ_DATA_WIDTH(64),
        .READ_MODE("std"),
        .RELATED_CLOCKS(0),
        .USE_ADV_FEATURES("1707"),
        .WAKEUP_TIME(0),
        .WRITE_DATA_WIDTH(CMD_DATA_LEN),
        .WR_DATA_COUNT_WIDTH(1)
    ) xpm_fifo_async_inst (
        .almost_empty(),
        .almost_full(),
        .data_valid(da_data_valid),
        .dbiterr(),
        .dout(da_data),
        .empty(fifo_empty),
        .full(),
        .overflow(),
        .prog_empty(),
        .prog_full(),
        .rd_data_count(),
        .rd_rst_busy(),
        .sbiterr(),
        .underflow(),
        .wr_ack(),
        .wr_data_count(),
        .wr_rst_busy(),
        .din(cmd_data),
        .injectdbiterr(),
        .injectsbiterr(),
        .rd_clk(da_clk),
        .rd_en(!fifo_empty),
        .rst(rst_cmd_clk),
        .sleep(),
        .wr_clk(cmd_clk),
        .wr_en(cmd_data_valid)
    );

    // ========================================================================
    // 2. 8 级流水寄存器 (时序对齐)
    // ========================================================================
    reg [63:0]   da_data_reg       [1:8];
    reg [00:0]   da_data_valid_reg [1:8];
    always_ff @(posedge da_clk) begin
        da_data_reg[1]       <= da_data;
        da_data_valid_reg[1] <= da_data_valid;
    end
    generate
        for (i = 1; i <= 7; i = i + 1) begin : g_pipe
            always_ff @(posedge da_clk) begin
                da_data_reg[i+1]       <= da_data_reg[i];
                da_data_valid_reg[i+1] <= da_data_valid_reg[i];
            end
        end
    endgenerate

    // ========================================================================
    // 3. 帧头/帧尾检测
    //    用 da_data_reg[2] 组合比较 (与 da_data_valid_reg[2] 同拍, 消除错拍):
    //    早期实现从 da_data(0级) 寄存 1 拍, 与 reg[2](2级) 错开一拍,
    //    FIFO 连续输出时帧头判断的是下一字 → FSM 卡死
    // ========================================================================

    // ========================================================================
    // 4. 11 状态 FSM
    // ========================================================================
    localparam IDLE                = 5'd0;
    localparam PACKET_HEAD         = 5'd1;
    localparam PACKET_FUNCTION     = 5'd2;
    localparam PACKET_TIME         = 5'd3;
    localparam PACKET_Amount       = 5'd4;
    localparam PACKET_DATA_LEN     = 5'd5;
    localparam PACKET_VERSION      = 5'd6;
    localparam MESSAGE_HEAD        = 5'd7;
    localparam MESSAGE_HEAD2       = 5'd8;
    localparam MESSAGE_CONTENT     = 5'd9;
    localparam PACKET_CHEKSUM      = 5'd10;

    reg [4:0]   main_st = IDLE;
    reg [31:0]  Function_id;
    reg         main_st_is_MESSAGE_CONTENT;
    reg         main_st_is_PACKET_CHEKSUM;

    always_ff @(posedge da_clk) begin
        if (rst_da_clk) begin
            main_st <= IDLE;
            main_st_is_MESSAGE_CONTENT <= 0;
            main_st_is_PACKET_CHEKSUM  <= 0;
            Function_id <= '0;   // 修复: 复位初始化, 否则 (X==0xDABF000B)=X, apply 门 X
        end else begin
            case (main_st)
                IDLE: begin
                    main_st <= PACKET_HEAD;
                    main_st_is_MESSAGE_CONTENT <= 0;
                    main_st_is_PACKET_CHEKSUM  <= 0;
                end
                PACKET_HEAD: begin
                    main_st_is_MESSAGE_CONTENT <= 0;
                    main_st_is_PACKET_CHEKSUM  <= 0;
                    if (da_data_valid_reg[2] && (da_data_reg[2][63:32] == 32'h7E8118E7))
                        main_st <= PACKET_FUNCTION;
                end
                PACKET_FUNCTION: begin
                    if (da_data_valid_reg[2]) begin
                        Function_id <= da_data_reg[2][31:0];
                        main_st <= PACKET_TIME;
                    end
                end
                PACKET_TIME: begin
                    if (da_data_valid_reg[2])
                        main_st <= PACKET_Amount;
                end
                PACKET_Amount: begin
                    if (da_data_valid_reg[2])
                        main_st <= PACKET_DATA_LEN;
                end
                PACKET_DATA_LEN: begin
                    if (da_data_valid_reg[2])
                        main_st <= PACKET_VERSION;
                end
                PACKET_VERSION: begin
                    if (da_data_valid_reg[2]) begin
                        main_st <= MESSAGE_CONTENT;
                        main_st_is_MESSAGE_CONTENT <= 1;
                    end
                end
                MESSAGE_CONTENT: begin
                    if (da_data_valid_reg[2]) begin
                        if (da_data_reg[2][31:00] == 32'h8F9009F8) begin
                            main_st <= PACKET_CHEKSUM;
                            main_st_is_MESSAGE_CONTENT <= 0;
                            main_st_is_PACKET_CHEKSUM  <= 1;
                        end
                    end
                end
                PACKET_CHEKSUM: begin
                    main_st_is_PACKET_CHEKSUM <= 0;
                    main_st <= IDLE;
                end
                default: main_st <= IDLE;
            endcase
        end
    end

    // ========================================================================
    // 5. Function_id == 0xDABF_000B (apply 门)
    // ========================================================================
    reg Function_id_is_DABF_000B;
    always_ff @(posedge da_clk) begin
        if (rst_da_clk)
            Function_id_is_DABF_000B <= 0;
        else
            Function_id_is_DABF_000B <= (Function_id == 32'hDABF_000B) ? 1 : 0;
    end

    // ========================================================================
    // 6. 寄存器解析 (MESSAGE_CONTENT 状态, da_data_reg[2])
    //    地址码 = da_data_reg[2][63:32], 数据 = da_data_reg[2][31:0]
    //    16 元全局编址: idx = beam×16 + ch (beam∈0..3, ch∈0..15, idx∈0..63)
    //      idx[5:4]=beam, idx[3]=片号 (匹配 CHIP_ID), idx[2:0]=本片通道
    //    DDS 频率 (0x6705/0x6706) 不解片: 两片解到同一频率
    // ========================================================================

    // 地址码匹配: 取高 16 位做基址判断, 低 16 位做 idx
    wire [31:0] msg_addr = da_data_reg[2][63:32];
    wire [15:0] msg_base = msg_addr[31:16];
    wire [15:0] msg_idx  = msg_addr[15:0];
    wire is_0x6701 = (msg_base == 16'h6701);
    wire is_0x6702 = (msg_base == 16'h6702);
    wire is_0x6703 = (msg_base == 16'h6703);
    wire is_0x6704 = (msg_base == 16'h6704);
    wire is_0x6705 = (msg_base == 16'h6705);
    wire is_0x6706 = (msg_base == 16'h6706);
    // 地址拆片: 本片才处理 (片0: ch∈0..7, 片1: ch∈8..15)
    wire [1:0]  beam_sel = msg_idx[5:4];
    wire        chip_sel = msg_idx[3];
    wire [$clog2(N_CH_P)-1:0] ch_sel = msg_idx[2:0];
    wire        match_chip = (chip_sel == CHIP_ID[0]);

    // ---- 6a. delay_val (暂存 → apply 提交) ----
    logic [$clog2(MAX_DELAY_P+1)-1:0] delay_val_temp [N_BEAM_P-1:0][N_CH_P-1:0];
    always_ff @(posedge da_clk) begin
        if (rst_da_clk) begin
            for (int b = 0; b < N_BEAM_P; b++)
                for (int c = 0; c < N_CH_P; c++)
                    delay_val_temp[b][c] <= '0;
        end else if (da_data_valid_reg[2] && main_st_is_MESSAGE_CONTENT && Function_id_is_DABF_000B && is_0x6701 && match_chip) begin
            for (int b = 0; b < N_BEAM_P; b++)
                if (beam_sel == b)
                    delay_val_temp[b][ch_sel] <= da_data_reg[2][$clog2(MAX_DELAY_P+1)-1:0];
        end
    end
    // apply 提交 (Function_id==0xDABF_000B 门控即提交, 不判帧尾状态)
    always_ff @(posedge da_clk) begin
        if (rst_da_clk) begin
            for (int b = 0; b < N_BEAM_P; b++)
                for (int c = 0; c < N_CH_P; c++)
                    delay_val[b][c] <= '0;
        end else if (Function_id_is_DABF_000B) begin   // Function_id 门控即提交, 不判帧尾
            for (int b = 0; b < N_BEAM_P; b++)
                for (int c = 0; c < N_CH_P; c++)
                    delay_val[b][c] <= delay_val_temp[b][c];
        end
    end

    // ---- 6b. FIR 系数 (立即加载, 数据内嵌 tap_addr) ----
    // data[19:16]=tap_addr, [15:0]=coef, idx=beam*16+ch (全局 16 元)
    always_ff @(posedge da_clk) begin
        if (rst_da_clk) begin
            for (int b = 0; b < N_BEAM_P; b++) fir_coef_load[b] <= 0;
            fir_sel_ch    <= 0;
            fir_coef_addr <= 0;
            fir_coef_data <= 0;
        end else begin
            // 默认清零
            for (int b = 0; b < N_BEAM_P; b++) fir_coef_load[b] <= 0;
            // 命中 0x6702 时立即加载
            if (da_data_valid_reg[2] && main_st_is_MESSAGE_CONTENT && Function_id_is_DABF_000B && is_0x6702 && match_chip) begin
                for (int b = 0; b < N_BEAM_P; b++) begin
                    if (beam_sel == b) begin
                        fir_coef_load[b] <= 1;
                        fir_sel_ch    <= ch_sel;
                        fir_coef_addr <= da_data_reg[2][19:16];
                        fir_coef_data <= da_data_reg[2][15:0];
                    end
                end
            end
        end
    end

    // ---- 6c. 复数权重 (立即加载) ----
    // data[31:16]=im, [15:0]=re, idx=beam*16+ch (全局 16 元)
    always_ff @(posedge da_clk) begin
        if (rst_da_clk) begin
            for (int b = 0; b < N_BEAM_P; b++) weight_load[b] <= 0;
            weight_sel_ch <= 0;
            weight_re     <= 0;
            weight_im     <= 0;
        end else begin
            for (int b = 0; b < N_BEAM_P; b++) weight_load[b] <= 0;
            if (da_data_valid_reg[2] && main_st_is_MESSAGE_CONTENT && Function_id_is_DABF_000B && is_0x6703 && match_chip) begin
                for (int b = 0; b < N_BEAM_P; b++) begin
                    if (beam_sel == b) begin
                        weight_load[b]  <= 1;
                        weight_sel_ch   <= ch_sel;
                        weight_re       <= da_data_reg[2][15:0];
                        weight_im       <= da_data_reg[2][31:16];
                    end
                end
            end
        end
    end

    // ---- 6d. phase_inc / phase_offset (暂存 → apply 提交) ----
    //    不解片: 两片 ZU48DR 解到相同 DDS 频率 (16 元波束共用频率)
    logic [DDS_PHASE_W_P-1:0] phase_inc_temp    [N_BEAM_P-1:0];
    logic [DDS_PHASE_W_P-1:0] phase_offset_temp [N_BEAM_P-1:0];
    always_ff @(posedge da_clk) begin
        if (rst_da_clk) begin
            for (int b = 0; b < N_BEAM_P; b++) begin
                phase_inc_temp[b]    <= '0;
                phase_offset_temp[b] <= '0;
            end
        end else if (da_data_valid_reg[2] && main_st_is_MESSAGE_CONTENT && Function_id_is_DABF_000B) begin
            for (int b = 0; b < N_BEAM_P; b++) begin
                if (is_0x6705 && msg_idx == b)
                    phase_inc_temp[b] <= da_data_reg[2][31:0];
                if (is_0x6706 && msg_idx == b)
                    phase_offset_temp[b] <= da_data_reg[2][31:0];
            end
        end
    end
    // apply 提交
    // apply 提交 (Function_id==0xDABF_000B 门控即提交, 不判帧尾状态)
    always_ff @(posedge da_clk) begin
        if (rst_da_clk) begin
            for (int b = 0; b < N_BEAM_P; b++) begin
                phase_inc[b]    <= '0;
                phase_offset[b] <= '0;
            end
        end else if (Function_id_is_DABF_000B) begin   // Function_id 门控即提交, 不判帧尾
            for (int b = 0; b < N_BEAM_P; b++) begin
                phase_inc[b]    <= phase_inc_temp[b];
                phase_offset[b] <= phase_offset_temp[b];
            end
        end
    end

    // ---- 6e. tx_bf_trunc (tx_bf_core 输出截位右移量, 0x6704, 立即生效) ----
    always_ff @(posedge da_clk) begin
        if (rst_da_clk)
            tx_bf_trunc <= 4'd0;   // 默认无右移 (DBF 输出直通)
        else if (da_data_valid_reg[2] && main_st_is_MESSAGE_CONTENT && Function_id_is_DABF_000B && is_0x6704)
            tx_bf_trunc <= da_data_reg[2][3:0];
    end

    // ---- 6f. apply 脉冲 (Function_id 匹配上升沿 1 拍, 不判帧尾) ----
    reg Function_id_is_DABF_000B_r;
    always_ff @(posedge da_clk) begin
        if (rst_da_clk) begin
            Function_id_is_DABF_000B_r <= 0;
            cfg_apply_pulse <= 0;
        end else begin
            Function_id_is_DABF_000B_r <= Function_id_is_DABF_000B;
            cfg_apply_pulse <= Function_id_is_DABF_000B & ~Function_id_is_DABF_000B_r;
        end
    end

endmodule : decode_cmd_tx_bf

`endif // DECODE_CMD_TX_BF_SV
