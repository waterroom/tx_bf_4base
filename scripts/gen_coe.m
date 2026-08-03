% GEN_COE 将 8 倍内插 FIR 系数从 .h (C 数组) 转换为 Xilinx .coe 文件
%   用法: 在 MATLAB 中运行 gen_coe
%   输入: ../rtl/fdacoefs_fir_300Mto2400M_88Mpass.h
%   输出: ../ip/coef/fir_300Mto2400M_88Mpass.coe
%
%   .coe 格式供 Xilinx FIR Compiler 构建时加载 (运行时不重载, 省 BRAM)

addpath('utils');

% 路径 (相对于 matlab/ 目录)
h_file  = '../rtl/fdacoefs_fir_300Mto2400M_88Mpass.h';
coe_dir = '../ip/coef';
coe_file = fullfile(coe_dir, 'fir_300Mto2400M_88Mpass.coe');

% 确保输出目录存在
if ~exist(coe_dir, 'dir'), mkdir(coe_dir); end

% 读取 .h 文件中的 int16 系数数组 B[48]
txt = fileread(h_file);
% 提取 "B[48] = { ... }" 中的数值
tok = regexp(txt, 'B\[48\]\s*=\s*\{([^}]*)\}', 'tokens', 'once');
if isempty(tok)
    error('gen_coe: 未在 %s 中找到 B[48] 数组', h_file);
end
coeffs = sscanf(tok, '%d');     % 解析为整数列向量
coeffs = coeffs(:).';

fprintf('gen_coe: 读取 %d 个系数 from %s\n', length(coeffs), h_file);
fprintf('  首尾: [%d, %d, ..., %d, %d]\n', coeffs(1), coeffs(2), coeffs(end-1), coeffs(end));

% 写 .coe 文件 (16bit 有符号, Xilinx FIR Compiler 格式)
write_coe(coeffs, coe_file, 16);

% 验证: 对称性检查 (Type2 线性相位)
sym_err = max(abs(coeffs - fliplr(coeffs)));
fprintf('  对称性误差: %d (Type2 应为 0)\n', sym_err);
