% ANALYZE_DAC_OUT 分析 FPGA 仿真输出的 DAC 频谱 (验证 4 波束 4 频率)
% 读 sim_out/dac_out_8p.log (8 并行 I/Q, 2.4GHz 等效)
%
% 用法:
%   analyze_dac_out          默认: GUI 桌面时画频谱图, 无桌面时仅打印文本
%   analyze_dac_out(0)       强制不画图 (终端/CI 环境推荐)
%   analyze_dac_out(1)       强制画图
%
% 注意: 若在受限终端 (如 git-bash 沙箱) 用 matlab -batch 运行闪退,
%   是 MATLAB Intel OpenMP 启动检测 CPU 失败所致, 与本脚本无关.
%   请改用 scripts/run_analyze.bat 或在 MATLAB GUI 中直接运行.
function analyze_dac_out(plot_flag)
if nargin < 1
    plot_flag = usejava('desktop');   % GUI 桌面默认画图
end

% ---------- 读数据 (分块, 支持大文件) ----------
fpath = 'sim_out/dac_out_8p.log';
fid = fopen(fpath, 'r');
if fid == -1
    error('找不到 %s。请先运行 scripts/run_sim.tcl 完成 Vivado 仿真。', fpath);
end
fgetl(fid);   % 跳过标题行
I = []; Q = [];
CHUNK = 1e6;   % 每块 100 万行
while ~feof(fid)
    raw = textscan(fid, '%d %d', CHUNK);
    if isempty(raw{1}), break; end
    I = [I; raw{1}];
    Q = [Q; raw{2}];
end
fclose(fid);
N = length(I);
fprintf('样本数: %d (2.4GHz 域)\n', N);
if N < 64
    warning('样本数过少 (%d), 频谱分析无意义。', N);
    return;
end
fprintf('I 范围: [%d, %d], Q 范围: [%d, %d]\n', min(I), max(I), min(Q), max(Q));

% ---------- 复数信号 + 去直流 + 加窗 + FFT ----------
% FFT 峰值内存 ~8×N×2 字节, 2^22 点约 130MB, 16G 内存无压力
sig = complex(double(I), double(Q));
sig = sig - mean(sig);
win = hann(N);
S = fftshift(fft(sig .* win));
Fs = 2.4e9;
f_axis = ((0:N-1) - N/2) / N * Fs;   % 正确频轴 (fftshift 后 DC 在 N/2 处)
mag = abs(S) / (N/2);

% ---------- 检查 4 个 LO 频率峰 (含 >1.2GHz 的混叠位置) ----------
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

% ---------- 噪声底 ----------
noise_mask = true(size(f_axis));
for k = 1:length(f_LO)
    noise_mask = noise_mask & ~(abs(f_axis - f_LO(k)) < 50e6);
end
noise = median(mag(noise_mask));
fprintf('  噪声底: %.1f dB\n', 20*log10(noise+eps));

% ---------- 频谱图 (可选) ----------
if plot_flag
    % 若在此处闪退, 是显卡/OpenGL 驱动兼容问题, 用 analyze_dac_out(0) 跳过绘图,
    % 或先在命令行执行 opengl software 强制软件渲染
    figure('Name','FPGA 仿真 DAC 输出频谱','Position',[100 100 900 400]);
    plot(f_axis/1e6, 20*log10(mag+eps), 'b'); grid on;
    hold on;
    for k = 1:length(f_LO)
        xline(f_LO(k)/1e6, 'r--');
    end
    xlabel('频率 (MHz)'); ylabel('幅度 (dB)');
    title('FPGA 仿真 DAC 输出频谱 (4 波束 4 频率)');
    xlim([-1200 1200]); ylim([-120 10]);
else
    fprintf('(无图形桌面或已禁用绘图, 仅输出文本结果)\n');
end
fprintf('\n=== 分析完成 ===\n');
end
