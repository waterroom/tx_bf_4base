// =============================================================================
// cmult_3dsp.sv  --  3-DSP pipelined complex multiplier (fully separated)
// =============================================================================
// (a_re + j*a_im) * (b_re + j*b_im) = (a_re*b_re - a_im*b_im) + j*(a_re*b_im + a_im*b_re)
//
// 3-DSP algorithm:
//   P0 = a_re * b_re
//   P1 = a_im * b_im
//   P2 = (a_re + a_im) * (b_re + b_im)
//   Real = P0 - P1
//   Imag = P2 - P0 - P1
//
// Pipeline (each stage has only 1 operation type):
//   Cycle 0: Input register
//   Cycle 1: Addition (a+b, c+d) — 需要 A_W+1 / B_W+1 位防溢出
//   Cycle 2: Multiplication (3 DSP)
//   Cycle 3: First subtraction (P0-P1, P2-P0)
//   Cycle 4: Second subtraction ((P2-P0)-P1)
//   Cycle 5: Round bias + shift  ((x + 2^14) >>> 15)
//   Cycle 6: Saturate + output register
//
// 位宽说明：
//   P_W   = A_W + B_W          (P0, P1 的位宽)
//   P2_W  = (A_W+1) + (B_W+1)  (P2 的位宽 = P_W+2)
//   IW    = P_W + 2            (内部统一位宽，覆盖 P2 路径)
// =============================================================================

`ifndef CMULT_3DSP_SV
`define CMULT_3DSP_SV

module cmult_3dsp #(
    parameter int unsigned A_W   = 18,
    parameter int unsigned B_W   = 16,
    parameter int unsigned OUT_W = 18
)(
    input  logic                      clk,
    input  logic                      rst,
    input  logic                      valid_in,
    input  logic signed [A_W-1:0]    a_re, a_im,
    input  logic signed [B_W-1:0]    b_re, b_im,
    output logic signed [OUT_W-1:0]  o_re, o_im,
    output logic                      valid_out
);

    localparam int unsigned P_W  = A_W + B_W;       // P0/P1 位宽
    localparam int unsigned P2_W = P_W + 2;         // P2 位宽 (含 sum 扩展)
    localparam int unsigned IW   = P_W + 2;         // 内部统一位宽

    // ======== Cycle 0: Input register ========
    logic signed [A_W-1:0] a_re_r, a_im_r;
    logic signed [B_W-1:0] b_re_r, b_im_r;
    logic                  v0;

    always_ff @(posedge clk) begin
        if (rst) begin
            a_re_r <= '0; a_im_r <= '0; b_re_r <= '0; b_im_r <= '0; v0 <= 1'b0;
        end else begin
            a_re_r <= a_re; a_im_r <= a_im; b_re_r <= b_re; b_im_r <= b_im; v0 <= valid_in;
        end
    end

    // ======== Cycle 1: Addition (扩展 1 位防溢出) ========
    logic signed [A_W:0]   a_sum_r;                 // A_W+1 位
    logic signed [B_W:0]   b_sum_r;                 // B_W+1 位
    logic signed [A_W-1:0] a_re_rr, a_im_rr;
    logic signed [B_W-1:0] b_re_rr, b_im_rr;
    logic                  v1;

    always_ff @(posedge clk) begin
        if (rst) begin
            a_sum_r <= '0; b_sum_r <= '0;
            a_re_rr <= '0; a_im_rr <= '0; b_re_rr <= '0; b_im_rr <= '0; v1 <= 1'b0;
        end else begin
            a_sum_r <= a_re_r + a_im_r;             // (A_W+1)-bit sum
            b_sum_r <= b_re_r + b_im_r;             // (B_W+1)-bit sum
            a_re_rr <= a_re_r; a_im_rr <= a_im_r;  // delay align
            b_re_rr <= b_re_r; b_im_rr <= b_im_r;
            v1 <= v0;
        end
    end

    // ======== Cycle 2: Multiplication (3 DSP) ========
    (* use_dsp = "yes" *) logic signed [P_W-1:0]  p0, p1;   // A_W × B_W
    (* use_dsp = "yes" *) logic signed [P2_W-1:0] p2;        // (A_W+1) × (B_W+1)
    logic                  v2;

    always_ff @(posedge clk) begin
        if (rst) begin p0 <= '0; p1 <= '0; p2 <= '0; v2 <= 1'b0; end
        else begin
            p0 <= a_re_rr * b_re_rr;                // DSP1: a*c
            p1 <= a_im_rr * b_im_rr;                // DSP2: b*d
            p2 <= a_sum_r * b_sum_r;                // DSP3: (a+b)*(c+d)
            v2 <= v1;
        end
    end

    // ======== Cycle 3: First subtraction ========
    // 统一扩展到 IW 位再做减法
    logic signed [IW-1:0] real_r, temp_r;
    logic signed [P_W-1:0] p1_r;
    logic                  v3;

    always_ff @(posedge clk) begin
        if (rst) begin real_r <= '0; temp_r <= '0; p1_r <= '0; v3 <= 1'b0; end
        else begin
            real_r <= {{(IW-P_W){p0[P_W-1]}}, p0} - {{(IW-P_W){p1[P_W-1]}}, p1};  // P0 - P1
            temp_r <= {{(IW-P2_W){p2[P2_W-1]}}, p2} - {{(IW-P_W){p0[P_W-1]}}, p0}; // P2 - P0
            p1_r   <= p1;
            v3 <= v2;
        end
    end

    // ======== Cycle 4: Second subtraction ========
    logic signed [IW-1:0] real_out_r, imag_r;
    logic                  v4;

    always_ff @(posedge clk) begin
        if (rst) begin real_out_r <= '0; imag_r <= '0; v4 <= 1'b0; end
        else begin
            real_out_r <= real_r;
            imag_r     <= temp_r - {{(IW-P_W){p1_r[P_W-1]}}, p1_r};  // (P2-P0) - P1
            v4 <= v3;
        end
    end

    // ======== Cycle 5: Round bias + shift ((x + 2^14) >>> 15) ========
    // 匹配 MATLAB round(x/32767)：加 2^14 偏置后右移 15 位
    logic signed [IW:0] rounded_re, rounded_im;     // +1 位防 bias 溢出
    logic               v5;

    always_ff @(posedge clk) begin
        if (rst) begin rounded_re <= '0; rounded_im <= '0; v5 <= 1'b0; end
        else begin
            rounded_re <= {real_out_r[IW-1], real_out_r} + (1 <<< 14);
            rounded_im <= {imag_r[IW-1], imag_r} + (1 <<< 14);
            v5 <= v4;
        end
    end

    // ======== Cycle 6: Saturate + output register ========
    function automatic logic signed [OUT_W-1:0] sat(input logic signed [IW:0] v);
        logic signed [IW:0] shifted;
        begin
            shifted = signed'(v >>> 15);            // 右移 15 位
            if (shifted >  $signed({1'b0, {(OUT_W-1){1'b1}}})) return {1'b0, {(OUT_W-1){1'b1}}};
            if (shifted < -$signed({1'b0, {(OUT_W-1){1'b1}}})) return {1'b1, {(OUT_W-1){1'b0}}};
            return shifted[OUT_W-1:0];
        end
    endfunction

    always_ff @(posedge clk) begin
        if (rst) begin o_re <= '0; o_im <= '0; valid_out <= 1'b0; end
        else begin o_re <= sat(rounded_re); o_im <= sat(rounded_im); valid_out <= v5; end
    end

endmodule

`endif // CMULT_3DSP_SV
