function h = gen_frac_delay_coeffs(frac_d, taps)
%GEN_FRAC_DELAY_COEFFS 生成 16 抽头分数延时 FIR 系数
%   h = gen_frac_delay_coeffs(frac_d, taps)
%   输入:
%     frac_d - 分数延时 (0 <= frac_d < 1)
%     taps   - 抽头数 (默认 16，与参考仓库一致)
%   输出:
%     h      - 1×taps 行向量，FIR 系数 (浮点)
%
%   设计方法: 加窗 sinc (Hamming 窗)，与参考仓库 MATLAB 模型一致
%   16 抽头 FIR 基群延时 = (taps-1)/2 = 7.5 个样本，加上 frac_d 构成总延时
%   系数量化到 16bit 有符号由调用方完成 (见 quantize_coeffs)

    if nargin < 2, taps = 16; end
    if frac_d < 0 || frac_d >= 1
        error('gen_frac_delay_coeffs: 分数延时 frac_d 必须在 [0,1) 范围内, 当前 = %g', frac_d);
    end

    % 基群延时 + 分数延时
    delay = (taps - 1) / 2 + frac_d;
    n = 0:taps-1;
    % 理想分数延时冲击响应: sinc(n - delay)
    h = sinc((n - delay)');
    % Hamming 窗加权，压低旁瓣
    h = h .* hamming(taps);
    % 归一化使直流增益为 1
    h = h / sum(h);

    % 转行向量
    h = h.';
end
