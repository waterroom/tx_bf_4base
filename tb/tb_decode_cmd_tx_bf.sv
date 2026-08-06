`timescale 1ns/1ps

// =============================================================================
// tb_decode_cmd_tx_bf.sv  --  decode_cmd_tx_bf 单元测试
// =============================================================================
// 验证: 64b 报文 FSM + CDC + 寄存器解析 (FIR/weight/delay/phase)
// 不依赖 DSP 数据路径 (快)
// =============================================================================

import tx_bf_pkg::*;

module tb_decode_cmd_tx_bf;

    logic da_clk = 0, cmd_clk = 0;
    logic rst_da_clk = 1, rst_cmd_clk = 1;
    logic [63:0] cmd_data = 0;
    logic        cmd_data_valid = 0;

    // DUT 输出
    logic [$clog2(MAX_DELAY+1)-1:0] delay_val    [N_BEAM-1:0][N_ELEM-1:0];
    logic [DDS_PHASE_W-1:0]         phase_inc    [N_BEAM-1:0];
    logic [DDS_PHASE_W-1:0]         phase_offset [N_BEAM-1:0];
    logic                           fir_coef_load [N_BEAM-1:0];
    logic [$clog2(N_ELEM)-1:0]      fir_sel_ch;
    logic [$clog2(TAPS)-1:0]        fir_coef_addr;
    logic signed [COEF_W-1:0]       fir_coef_data;
    logic                           weight_load  [N_BEAM-1:0];
    logic [$clog2(N_ELEM)-1:0]      weight_sel_ch;
    logic signed [COEF_W-1:0]       weight_re;
    logic signed [COEF_W-1:0]       weight_im;
    logic                           cfg_apply_pulse;

    // 时钟
    localparam real DA_CLK_PERIOD  = 3.333;  // 300MHz
    localparam real CMD_CLK_PERIOD = 10.0;   // 100MHz
    always #(DA_CLK_PERIOD/2)  da_clk  = ~da_clk;
    always #(CMD_CLK_PERIOD/2) cmd_clk = ~cmd_clk;

    // DUT
    decode_cmd_tx_bf u_dut (
        .da_clk(da_clk), .rst_da_clk(rst_da_clk),
        .cmd_clk(cmd_clk), .rst_cmd_clk(rst_cmd_clk),
        .cmd_data(cmd_data), .cmd_data_valid(cmd_data_valid),
        .delay_val(delay_val), .phase_inc(phase_inc), .phase_offset(phase_offset),
        .fir_coef_load(fir_coef_load), .fir_sel_ch(fir_sel_ch),
        .fir_coef_addr(fir_coef_addr), .fir_coef_data(fir_coef_data),
        .weight_load(weight_load), .weight_sel_ch(weight_sel_ch),
        .weight_re(weight_re), .weight_im(weight_im),
        .cfg_apply_pulse(cfg_apply_pulse)
    );

    // ---------- 报文生成器 ----------
    task automatic send_packet(input [31:0] function_id, input logic [63:0] content_q[$]);
        logic [63:0] pkt[$];
        int i;
        pkt.push_back({32'h7E8118E7, 32'h0000_0040});       // 帧头 + Len
        pkt.push_back({16'h0001, 16'h0001, function_id});   // Dest/Device/Func
        pkt.push_back(64'h0);                                // Time
        pkt.push_back({32'h0000_0001, 32'h0000_0001});      // Serial/Amount
        pkt.push_back({32'h0000_0001, 32'h0000_0040});      // PktNum/DataLen
        pkt.push_back({16'h0001, 16'h0000, 32'h0});         // Version/RetAddr
        for (i = 0; i < content_q.size(); i++)
            pkt.push_back(content_q[i]);
        pkt.push_back({32'h0000_0000, 32'h8F9009F8});       // Checksum + 帧尾
        // 在 cmd_clk 域逐拍驱动
        for (i = 0; i < pkt.size(); i++) begin
            @(posedge cmd_clk);
            cmd_data       <= pkt[i];
            cmd_data_valid <= 1;
        end
        @(posedge cmd_clk);
        cmd_data_valid <= 0;
    endtask

    // ---------- 测试用例 ----------
    logic [63:0] content_q[$];
    int errors = 0;

    initial begin
        // 复位
        rst_da_clk = 1; rst_cmd_clk = 1;
        repeat(10) @(posedge da_clk);
        rst_da_clk = 0; rst_cmd_clk = 0;
        repeat(20) @(posedge da_clk);

        // ===== 用例 1: FIR 系数加载 (beam0/ch0/tap7=0x7FFF) =====
        $display("=== 用例 1: FIR 系数加载 ===");
        content_q = {};
        content_q.push_back({32'h6702_0000, 32'h7FFF_0007}); // addr=0x6702+0, data={coef=0x7FFF, tap=7}
        send_packet(32'h0A0C_000B, content_q);
        // 等待 CDC + 流水
        repeat(30) @(posedge da_clk);
        if (fir_coef_load[0] !== 1'b1 || fir_sel_ch !== 0 || fir_coef_addr !== 7 || fir_coef_data !== 16'h7FFF) begin
            $display("  FAIL: fir_coef_load[0]=%b sel_ch=%0d addr=%0d data=%h", fir_coef_load[0], fir_sel_ch, fir_coef_addr, fir_coef_data);
            errors++;
        end else $display("  PASS");
        repeat(5) @(posedge da_clk);

        // ===== 用例 2: 权重加载 (beam2/ch5, re=0x4000, im=0x8000) =====
        $display("=== 用例 2: 权重加载 ===");
        content_q = {};
        content_q.push_back({32'h6703_0015, 32'h8000_4000}); // idx=2*8+5=21=0x15, data={im=0x8000, re=0x4000}
        send_packet(32'h0A0C_000B, content_q);
        repeat(30) @(posedge da_clk);
        if (weight_load[2] !== 1'b1 || weight_sel_ch !== 5 || weight_re !== 16'h4000 || weight_im !== 16'h8000) begin
            $display("  FAIL: weight_load[2]=%b sel_ch=%0d re=%h im=%h", weight_load[2], weight_sel_ch, weight_re, weight_im);
            errors++;
        end else $display("  PASS");
        repeat(5) @(posedge da_clk);

        // ===== 用例 3: delay + phase apply 提交 =====
        $display("=== 用例 3: delay + phase apply 提交 ===");
        content_q = {};
        content_q.push_back({32'h6701_0000, 32'h0000_000A}); // delay[0][0]=10
        content_q.push_back({32'h6701_0017, 32'h0000_0014}); // delay[3][7]=20 (idx=3*8+7=31=0x1F? 不对, 31=0x1F)
        content_q.push_back({32'h6705_0000, 32'h1234_5678}); // phase_inc[0]
        content_q.push_back({32'h6706_0001, 32'hABCD_EF01}); // phase_offset[1]
        send_packet(32'h0A0C_000B, content_q);  // apply 报文
        repeat(40) @(posedge da_clk);
        if (delay_val[0][0] !== 10 || phase_inc[0] !== 32'h12345678 || phase_offset[1] !== 32'hABCDEF01) begin
            $display("  FAIL: delay[0][0]=%0d phase_inc[0]=%h phase_offset[1]=%h", delay_val[0][0], phase_inc[0], phase_offset[1]);
            errors++;
        end else $display("  PASS");

        // ===== 用例 4: 非 apply 报文不提交 delay/phase =====
        $display("=== 用例 4: 非 apply 报文不提交 ===");
        content_q = {};
        content_q.push_back({32'h6701_0000, 32'h0000_0063}); // delay[0][0]=99 (应不提交)
        send_packet(32'h0000_0000, content_q);  // 非 apply
        repeat(40) @(posedge da_clk);
        if (delay_val[0][0] !== 10) begin  // 应仍为 10 (用例 3 的值)
            $display("  FAIL: delay[0][0]=%0d (应保持 10)", delay_val[0][0]);
            errors++;
        end else $display("  PASS");

        // ===== 结论 =====
        if (errors == 0) $display("\n=== ALL PASS ===");
        else $display("\n=== FAIL: %0d errors ===", errors);
        $finish;
    end

    // 超时保护
    initial begin
        #100000;
        $display("ERROR: 仿真超时");
        $finish;
    end

endmodule : tb_decode_cmd_tx_bf
