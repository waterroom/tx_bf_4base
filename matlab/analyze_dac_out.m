% ANALYZE_DAC_OUT 分析 FPGA 仿真输出的 DAC 频谱 (验证 4 波束 4 频率)
% 读 sim_out/dac_out_8p.log (8 并行 I/Q, 2.4GHz 等效)
clear; clc;

fid = fopen('sim_out/dac_out_8p.log', 'r');
fgetl(fid);   % 跳过标题行
raw = textscan(fid, '%d %d');
fclose(fid);
I = raw{1}; Q = raw{2};
N = length(I);
fprintf('样本数: %d (2.4GHz 域)\n', N);
fprintf('I 范围: [%d, %d], Q 范围: [%d, %d]\n', min(I), max(I), min(Q), max(Q));

% 复数信号 + 去直流 + 加窗
sig = complex(double(I), double(Q));
sig = sig - mean(sig);
win = hann(N);
S = fftshift(fft(sig .* win));
Fs = 2.4e9;
f_axis = ((0:N-1) - N/2) / N * Fs;   % 正确频轴 (fftshift 后 DC 在 N/2 处)
mag = abs(S) / (N/2);

% 检查 4 个 LO 频率峰 (含 >1.2GHz 的混叠位置)
% 2.4GHz 复采样奈奎斯特 ±1.2GHz, >1.2GHz 的频率混叠:
%   f_aliased = f_LO - Fs (若 f_LO > Fs/2)
f_LO = [200e6, 900e6, 1500e6, 2200e6];
fprintf('\n=== 频谱峰检查 (阵元0) ===\n');
for k = 1:length(f_LO)
    f_check = f_LO(k);
    if f_check > Fs/2, f_check = f_check - Fs; end   % 混叠位置
    mask = abs(f_axis - f_check) < 100e6;   % 搜索窗口 ±100MHz (信号在 f_LO±基带内)
    if any(mask)
        [pk, idx] = max(mag(mask));
        fpk = f_axis(mask);
        fprintf('  LO=%d MHz (检 %.0f MHz): 峰 %.1f dB @ %.1f MHz\n', ...
            f_LO(k)/1e6, f_check/1e6, 20*log10(pk+eps), fpk(idx)/1e6);
    else
        fprintf('  LO=%d MHz: 无数据\n', f_LO(k)/1e6);
    end
end

% 噪声底
noise_mask = true(size(f_axis));
for k = 1:length(f_LO)
    noise_mask = noise_mask & ~(abs(f_axis - f_LO(k)) < 50e6);
end
noise = median(mag(noise_mask));
fprintf('  噪声底: %.1f dB\n', 20*log10(noise+eps));

% 频谱图
figure('Name','FPGA 仿真 DAC 输出频谱','Position',[100 100 900 400]);
plot(f_axis/1e6, 20*log10(mag+eps), 'b'); grid on;
hold on;
for k = 1:length(f_LO)
    xline(f_LO(k)/1e6, 'r--');
end
xlabel('频率 (MHz)'); ylabel('幅度 (dB)');
title('FPGA 仿真 DAC 输出频谱 (4 波束 4 频率)');
xlim([-1200 1200]); ylim([-120 10]);
fprintf('\n=== 分析完成 ===\n');
