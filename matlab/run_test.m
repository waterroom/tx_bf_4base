% RUN_TEST 快速冒烟测试: 检查模型无错 + 打印基本统计
%   注: 这是"无错+基本量"检查, 不是正确性证明。
%   真正正确性证据在频谱图/时域图, 跑 verify_model_figs 生成:
%     matlab/figs/model_spectrum.png
%     matlab/figs/model_waveform.png
%     matlab/figs/model_8p.png
% 用 mfilename 定位 utils, 避免依赖 CWD
mdir = fileparts(mfilename('fullpath'));
addpath(fullfile(mdir, 'utils'));
fprintf('=== 运行 tx_bf_duc_model(256) ===\n');
N = 256;
[dac, info] = tx_bf_duc_model(N);

fprintf('dac.i    size: [%s]  (期望 8 x %d)\n', num2str(size(dac.i)),    N*8);
fprintf('dac.q    size: [%s]\n', num2str(size(dac.q)));
fprintf('dac.i_8p size: [%s]  (期望 8 x %d x 8)\n', num2str(size(dac.i_8p)), N);

fprintf('\n--- 输出统计 ---\n');
fprintf('dac.i  范围: [%.4f, %.4f]  均值 %.4f\n', min(dac.i(:)), max(dac.i(:)), mean(dac.i(:)));
fprintf('dac.q  范围: [%.4f, %.4f]  均值 %.4f\n', min(dac.q(:)), max(dac.q(:)), mean(dac.q(:)));

% 8 并行表示 vs 串行表示: 仅"两种摆布等价" (不是正确性证明)
% 正确性证据 (频谱/波形) 见 verify_model_figs.m 生成的 PNG 图
dac_i_flat = reshape(permute(dac.i_8p,[1,3,2]), 8, []);
fprintf('8 并行重塑一致性: %.2e (仅表示一致性, 不证明正确)\n', ...
    max(abs(dac.i(:) - dac_i_flat(:))));

% 频谱峰搜索: 4 波束在 (f_LO+f_bb) 处, >1.2GHz 混叠 (2.4GHz 复采样奈奎斯特 ±1.2GHz)
cfg = info.cfg;
sig0 = dac.i(1,:) + 1j*dac.q(1,:);
sig0 = sig0 - mean(sig0);
Nfft = N*8;
S0   = abs(fftshift(fft(sig0 .* hann(Nfft).')));
f0   = ((0:Nfft-1) - Nfft/2) / Nfft * info.Fs_high;
fprintf('\n--- 阵元0 频谱峰 (搜索窗口 ±50MHz) ---\n');
for b = 1:length(cfg.f_LO)
    f_exp = cfg.f_LO(b) + cfg.bb_freq(b);
    if f_exp > info.Fs_high/2, f_exp = f_exp - info.Fs_high; end   % 混叠
    mask  = abs(f0 - f_exp) < 50e6;
    f0_m = f0(mask); S0_m = S0(mask);
    [~, idx] = max(S0_m);
    fpk = f0_m(idx);   % 先 mask 再取标量 (避免 f0(boolean_array) 行为歧义)
    fprintf('  beam%d: 预期 %7.1f MHz | 实测 %7.1f MHz | 偏差 %+5.1f MHz\n', ...
        b, f_exp/1e6, fpk/1e6, (fpk - f_exp)/1e6);
end
fprintf('\n(建议跑 verify_model_figs 看频谱/时域图作为正确性证据)\n');
fprintf('=== 测试完成 ===\n');
