function [y, group_delay] = ttd_delay(x, int_d, frac_d, taps)
%TTD_DELAY 真时延时 (TTD): 整数延时 + 分数延时 FIR
%   [y, group_delay] = ttd_delay(x, int_d, frac_d, taps)
%   输入:
%     x      - 输入信号 (列向量, 复数或实数)
%     int_d  - 整数延时 (>=0 的整数)
%     frac_d - 分数延时 ([0,1) 范围)
%     taps   - 分数延时 FIR 抽头数 (默认 16)
%   输出:
%     y            - 延时后信号 (与 x 等长, 前端补零)
%     group_delay  - 总群延时 (样本数) = int_d + (taps-1)/2 + frac_d
%
%   实现说明:
%     整数延时: 移位寄存器, 输出延后 int_d 拍
%     分数延时: 16 抽头加窗 sinc FIR, 基群延时 (taps-1)/2 + frac_d
%     与参考仓库 int_delay.sv + frac_delay_fir.sv 行为一致
%     注: 参考 RTL 中 int_delay 额外 +2 拍 (sel 寄存+输出寄存), 本浮点模型
%         仅建模算法延时, 寄存器拍数在 FPGA 对比时由 valid 对齐处理

    if nargin < 4, taps = 16; end
    x = x(:);
    N = length(x);

    % 1. 整数延时: 前补 int_d 个零
    y_int = [zeros(int_d, 1); x];
    if length(y_int) > N, y_int = y_int(1:N); end      % 截断到等长
    if length(y_int) < N, y_int = [y_int; zeros(N-length(y_int),1)]; end

    % 2. 分数延时 FIR
    h = gen_frac_delay_coeffs(frac_d, taps);
    y = filter(h, 1, y_int);

    % 总群延时 (用于对齐参考)
    group_delay = int_d + (taps - 1) / 2 + frac_d;
end
