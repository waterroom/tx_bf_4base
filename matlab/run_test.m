% RUN_TEST 快速测试全链路模型 (小 N, 验证无错 + 基本统计)
addpath('utils');
fprintf('=== 运行 tx_bf_duc_model(256) ===\n');
N = 256;
[dac, info] = tx_bf_duc_model(N);

fprintf('dac.i  size: [%s]  (期望 8 × %d)\n', num2str(size(dac.i)), N*8);
fprintf('dac.q  size: [%s]\n', num2str(size(dac.q)));
fprintf('dac.i_8p size: [%s]  (期望 8 × %d × 8)\n', num2str(size(dac.i_8p)), N);

% 基本统计
fprintf('\n--- 输出统计 ---\n');
fprintf('dac.i  范围: [%.4f, %.4f]  均值 %.4f\n', min(dac.i(:)), max(dac.i(:)), mean(dac.i(:)));
fprintf('dac.q  范围: [%.4f, %.4f]  均值 %.4f\n', min(dac.q(:)), max(dac.q(:)), mean(dac.q(:)));

% 检查 8 并行重塑一致性 (展平后逐元素比较)
dac_i_reshaped = reshape(permute(dac.i_8p,[1,3,2]), 8, []);   % 8×2048
err = max(abs(dac.i(:) - dac_i_reshaped(:)));
fprintf('8并行重塑一致性误差: %.2e (应≈0)\n', err);

% 频谱快速检查: 阵元0 的 4 个 LO 频率处应有能量
sig0 = dac.i(1,:) + 1j*dac.q(1,:);
S0 = abs(fft(sig0));
Nh = N*8;
fprintf('\n--- 频谱峰检查 (阵元0) ---\n');
for b = 1:length(info.cfg.f_LO)
    bin = round(info.cfg.f_LO(b)/info.Fs_high*Nh)+1;
    fprintf('  LO%d=%.0fMHz: 谱峰 %.2f dB\n', b, info.cfg.f_LO(b)/1e6, 20*log10(S0(bin)/Nh+eps));
end
fprintf('\n=== 测试完成 ===\n');
