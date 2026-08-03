% ANALYZE_STAGES 综合分析 FPGA 各阶段频率
% 列: bb_i bb_q bf_re bf_im up_i[8] up_q[8] nco_cos nco_sin mix_i[8] mix_q[8]
clear; clc;
d = importdata('sim_out/bb_dump.log');
N = size(d, 1);
fprintf('样本行数: %d\n', N);

% 1. 基带 (300MHz 域, 复数)
bb = complex(d(:,1), d(:,2));
[fb] = peak_freq(bb, 300e6);
fprintf('基带峰: %.2f MHz\n', fb/1e6);

% 2. DBF 输出 (300MHz 域)
bf = complex(d(:,3), d(:,4));
[fb2] = peak_freq(bf, 300e6);
fprintf('DBF输出峰: %.2f MHz\n', fb2/1e6);

% 3. 内插输出 (重构复数, 2.4GHz 域)
up_i = d(:,5:12); up_q = d(:,13:20);
up_c = complex(up_i, up_q);
up_seq = up_c.'; up_seq = up_seq(:);
[fb3] = peak_freq(up_seq, 2.4e9);
fprintf('内插输出峰: %.2f MHz (预期 10)\n', fb3/1e6);

% 4. NCO 并行0 (300MHz 域, 应为 LO/8=25)
nco = complex(d(:,21), d(:,22));
[fb4] = peak_freq(nco, 300e6);
fprintf('NCO并行0峰: %.2f MHz (预期 LO/8=25)\n', fb4/1e6);

% 5. 混频输出 (重构复数, 2.4GHz 域, 应为 LO+10=210)
mix_i = d(:,23:30); mix_q = d(:,31:38);
mix_c = complex(mix_i, mix_q);
mix_seq = mix_c.'; mix_seq = mix_seq(:);
[fb5] = peak_freq(mix_seq, 2.4e9);
fprintf('混频输出峰: %.2f MHz (预期 210)\n', fb5/1e6);

% 6. DAC 输出
fid = fopen('sim_out/dac_out_8p.log','r'); fgetl(fid);
raw = textscan(fid, '%d %d'); fclose(fid);
dac = complex(double(raw{1}), double(raw{2}));
[fb6] = peak_freq(dac, 2.4e9);
fprintf('DAC输出峰: %.2f MHz (预期 210/930/-850/-130)\n', fb6/1e6);

function [fp] = peak_freq(sig, Fs)
    sig = sig(:) - mean(sig);
    S = abs(fftshift(fft(sig)));
    f = ((0:length(sig)-1) - length(sig)/2)/length(sig)*Fs;
    [~, i] = max(S);
    fp = f(i);
end
