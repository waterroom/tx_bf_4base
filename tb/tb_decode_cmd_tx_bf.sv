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
    logic rst_bf = 0;                    // 两片同步门 (phase 提交需 rst_bf 上升沿)
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
        .rst_bf(rst_bf),
        .delay_val(delay_val), .phase_inc(phase_inc), .phase_offset(phase_offset),
        .fir_coef_load(fir_coef_load), .fir_sel_ch(fir_sel_ch),
        .fir_coef_addr(fir_coef_addr), .fir_coef_data(fir_coef_data),
        .weight_load(weight_load), .weight_sel_ch(weight_sel_ch),
        .weight_re(weight_re), .weight_im(weight_im),
        .cfg_apply_pulse(cfg_apply_pulse)
    );

    // ---------- load 脉冲采样 (1 拍脉冲需捕获, 电平检查会错过) ----------
    logic fir_load_seen    [N_BEAM-1:0];
    logic weight_load_seen [N_BEAM-1:0];
    logic [$clog2(N_ELEM)-1:0] fir_sel_ch_cap, weight_sel_ch_cap;
    logic [$clog2(TAPS)-1:0]   fir_addr_cap;
    logic signed [COEF_W-1:0]  fir_data_cap, weight_re_cap, weight_im_cap;
    // unpacked array 归约需用循环 (| 不适用)
    logic any_fir_load, any_weight_load;
    always_comb begin
        any_fir_load = 1'b0;
        for (int b = 0; b < N_BEAM; b++) any_fir_load = any_fir_load | fir_coef_load[b];
        any_weight_load = 1'b0;
        for (int b = 0; b < N_BEAM; b++) any_weight_load = any_weight_load | weight_load[b];
    end
    always_ff @(posedge da_clk) begin
        for (int b = 0; b < N_BEAM; b++) begin
            if (fir_coef_load[b])   fir_load_seen[b]   <= 1;
            if (weight_load[b])     weight_load_seen[b] <= 1;
        end
        if (any_fir_load) begin
            fir_sel_ch_cap <= fir_sel_ch;
            fir_addr_cap   <= fir_coef_addr;
            fir_data_cap   <= fir_coef_data;
        end
        if (any_weight_load) begin
            weight_sel_ch_cap <= weight_sel_ch;
            weight_re_cap     <= weight_re;
            weight_im_cap     <= weight_im;
        end
    end
    // load 事件计数器 (区分"触发了但 sel_ch 相同"与"未触发")
    int fir_load_cnt = 0, weight_load_cnt = 0;
    always_ff @(posedge da_clk) begin
        if (any_fir_load)    fir_load_cnt    <= fir_load_cnt + 1;
        if (any_weight_load) weight_load_cnt <= weight_load_cnt + 1;
    end

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
        // 等待 xpm_fifo_async 复位释放 (wr_rst_busy/rd_rst_busy 需数个时钟),
        // 否则第一个报文的前几字会被 FIFO 丢弃 (帧头丢失 → FSM 不识别)
        repeat(500) @(posedge da_clk);

        // ===== 用例 1: FIR 系数加载 (beam0/ch0/tap7=0x7FFF) =====
        $display("=== 用例 1: FIR 系数加载 ===");
        content_q = {};
        // data[19:16]=tap=7, data[15:0]=coef=0x7FFF → data = 0x0007_7FFF
        content_q.push_back({32'h6702_0000, 32'h0007_7FFF}); // addr=0x6702+0, tap=7
        send_packet(32'h0A0C_000B, content_q);
        // 等待 CDC + 流水 + 脉冲采样
        repeat(30) @(posedge da_clk);
        if (!fir_load_seen[0] || fir_sel_ch_cap !== 0 || fir_addr_cap !== 7 || fir_data_cap !== 16'h7FFF) begin
            $display("  FAIL: load_seen[0]=%b sel_ch=%0d addr=%0d data=%h", fir_load_seen[0], fir_sel_ch_cap, fir_addr_cap, fir_data_cap);
            errors++;
        end else $display("  PASS");
        repeat(5) @(posedge da_clk);

        // ===== 用例 2: 权重加载 (beam2/ch5, re=0x4000, im=0x8000) =====
        $display("=== 用例 2: 权重加载 ===");
        content_q = {};
        content_q.push_back({32'h6703_0025, 32'h8000_4000}); // idx=2*16+5=37=0x25, data={im=0x8000, re=0x4000}
        send_packet(32'h0A0C_000B, content_q);
        repeat(30) @(posedge da_clk);
        if (!weight_load_seen[2] || weight_sel_ch_cap !== 5 || weight_re_cap !== 16'h4000 || weight_im_cap !== 16'h8000) begin
            $display("  FAIL: load_seen[2]=%b sel_ch=%0d re=%h im=%h", weight_load_seen[2], weight_sel_ch_cap, weight_re_cap, weight_im_cap);
            errors++;
        end else $display("  PASS");
        repeat(5) @(posedge da_clk);

        // ===== 用例 3: delay + phase apply 提交 =====
        $display("=== 用例 3: delay + phase apply 提交 ===");
        content_q = {};
        content_q.push_back({32'h6701_0000, 32'h0000_000A}); // delay[0][0]=10
        content_q.push_back({32'h6701_0037, 32'h0000_0014}); // delay[3][7]=20 (idx=3*16+7=55=0x37)
        content_q.push_back({32'h6705_0000, 32'h1234_5678}); // phase_inc[0]
        content_q.push_back({32'h6706_0001, 32'hABCD_EF01}); // phase_offset[1]
        send_packet(32'h0A0C_000B, content_q);  // apply 报文 (delay 帧尾即提交)
        // phase 需 rst_bf 上升沿提交 (两片同步门): 模拟主控拉高 rst_bf
        repeat(10) @(posedge da_clk);
        rst_bf = 1;
        repeat(20) @(posedge da_clk);
        rst_bf = 0;
        repeat(30) @(posedge da_clk);
        if (delay_val[0][0] !== 10 || phase_inc[0] !== 32'h12345678 || phase_offset[1] !== 32'hABCDEF01) begin
            $display("  FAIL: delay[0][0]=%0d phase_inc[0]=%h phase_offset[1]=%h", delay_val[0][0], phase_inc[0], phase_offset[1]);
            errors++;
        end else $display("  PASS");

        // ===== 用例 4: 非 apply 报文不提交 delay/phase, 且不触发任何寄存器写入 =====
        $display("=== 用例 4: 非 apply 报文不提交 ===");
        content_q = {};
        content_q.push_back({32'h6701_0000, 32'h0000_0063}); // delay[0][0]=99 (应不暂存/提交)
        content_q.push_back({32'h6702_0000, 32'h0007_7FFF}); // FIR 应不加载 (非 apply)
        content_q.push_back({32'h6703_0025, 32'h8000_4000}); // weight 应不加载 (非 apply)
        content_q.push_back({32'h6705_0000, 32'hFFFF_FFFF}); // phase 应不暂存
        send_packet(32'h0000_0000, content_q);  // 非 apply
        repeat(40) @(posedge da_clk);
        if (delay_val[0][0] !== 10) begin  // 应仍为 10 (用例 3 的值)
            $display("  FAIL: delay[0][0]=%0d (应保持 10)", delay_val[0][0]);
            errors++;
        end
        // FIR/weight load 计数应不变 (用例1: 1, 用例2: 1)
        if (fir_load_cnt !== 1 || weight_load_cnt !== 1) begin
            $display("  FAIL: 非 apply 报文触发了 FIR/weight load (fir=%0d weight=%0d, 应 1/1)", fir_load_cnt, weight_load_cnt);
            errors++;
        end
        // phase/delay 暂存不应被污染: 发"空 apply"提交当前 temp,
        // 若非 apply 曾污染 temp, 提交后 delay/phase 会变成污染值
        content_q = {};
        send_packet(32'h0A0C_000B, content_q);  // 空 apply: 只触发提交, 无新数据
        repeat(10) @(posedge da_clk);
        rst_bf = 1;
        repeat(20) @(posedge da_clk);
        rst_bf = 0;
        repeat(10) @(posedge da_clk);
        if (phase_inc[0] !== 32'h12345678) begin  // 应仍为用例 3 的值
            $display("  FAIL: phase_inc[0]=%h (非 apply 污染了暂存)", phase_inc[0]);
            errors++;
        end
        if (delay_val[0][0] !== 10) begin  // 空 apply 提交后应仍为 10
            $display("  FAIL: delay[0][0]=%0d (非 apply 污染了暂存)", delay_val[0][0]);
            errors++;
        end
        if (delay_val[0][0] === 10 && fir_load_cnt === 1 && weight_load_cnt === 1 && phase_inc[0] === 32'h12345678)
            $display("  PASS");

        // ===== 用例 5: 片 1 (ch∈8..15) 条目应被忽略 (CHIP_ID=0) =====
        $display("=== 用例 5: 片 1 条目忽略 ===");
        content_q = {};
        content_q.push_back({32'h6702_000F, 32'h0007_7FFF}); // idx=15: beam0/ch15(片1) → 忽略
        content_q.push_back({32'h6703_000F, 32'h8000_4000}); // idx=15: 片1 → 忽略
        content_q.push_back({32'h6701_000F, 32'h0000_0063}); // delay beam0/ch15(片1) → 忽略
        send_packet(32'h0A0C_000B, content_q);  // apply
        repeat(30) @(posedge da_clk);
        // 不应产生新 load (sel_ch 应保持前值: fir=0, weight=5); delay[0][7] 应保持 0
        if (fir_sel_ch_cap !== 0 || weight_sel_ch_cap !== 5 || delay_val[0][7] !== 0) begin
            $display("  FAIL: 片1 条目被处理 (fir_sel_ch=%0d weight_sel_ch=%0d delay[0][7]=%0d)", fir_sel_ch_cap, weight_sel_ch_cap, delay_val[0][7]);
            errors++;
        end else $display("  PASS");
        repeat(5) @(posedge da_clk);

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
