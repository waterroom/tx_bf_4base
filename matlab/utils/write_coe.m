function write_coe(coeffs, fname, coef_w)
%WRITE_COE 将 FIR 系数写入 Xilinx COE 文件
%   write_coe(coeffs, fname, coef_w)
%   输入:
%     coeffs  - 系数向量 (行或列, 整数或浮点)
%     fname   - 输出 .coe 文件路径
%     coef_w  - 系数位宽 (默认 16, 有符号)
%
%   输出格式 (Xilinx FIR Compiler 兼容):
%     Radix = 16;
%     Coefficient Width = 16;
%     CoefData = v0, v1, ..., vn;

    if nargin < 3, coef_w = 16; end
    coeffs = coeffs(:).';
    n = length(coeffs);

    % 量化到有符号整数 (若输入为浮点)
    if ~isinteger(coeffs)
        max_val = 2^(coef_w - 1) - 1;
        min_val = -2^(coef_w - 1);
        q = round(coeffs * max_val);
        q = max(min(q, max_val), min_val);
        coeffs = q;
    end

    fid = fopen(fname, 'w');
    if fid < 0
        error('write_coe: 无法打开文件 %s', fname);
    end
    fprintf(fid, 'Radix = 16;\n');
    fprintf(fid, 'Coefficient Width = %d;\n', coef_w);
    fprintf(fid, 'CoefData = ');
    for k = 1:n
        fprintf(fid, '%d', coeffs(k));
        if k < n, fprintf(fid, ', '); end
    end
    fprintf(fid, ';\n');
    fclose(fid);
    fprintf('write_coe: 已写入 %s (%d 个系数, %d bit 有符号)\n', fname, n, coef_w);
end
