@echo off
REM ============================================================
REM  run_all.bat - 一键完成: Vivado 行为仿真 + MATLAB 频谱验证
REM
REM  用法:
REM    双击本文件, 或在 cmd/PowerShell 中: scripts\run_all.bat
REM    自动化环境加参数跳过暂停: scripts\run_all.bat -nopause
REM
REM  流程:
REM    [1/2] vivado -mode batch -source scripts/run_sim.tcl
REM           (编译 pkg + TB -> xelab -> xsim, 输出 sim_out/dac_out_8p.log)
REM    [2/2] matlab -batch analyze_dac_out
REM           (FFT 频谱验证 4 波束峰: 210/930/-850/-130 MHz)
REM
REM  判据: 4 个波束峰实测频率与预期偏差 <1MHz, 峰高 >40dB
REM ============================================================
setlocal
cd /d "%~dp0.."

echo [1/2] 运行 Vivado 2022.1 行为仿真 ...
"C:\Xilinx\Vivado\2022.1\bin\vivado.bat" -mode batch -source scripts/run_sim.tcl
if errorlevel 1 (
    echo.
    echo [FAIL] 仿真失败, 请查看上方日志 (编译/精化错误见 xvlog.log xelab.log)
    if /i not "%~1"=="-nopause" pause
    exit /b 1
)

echo.
echo [2/2] MATLAB 频谱验证 (analyze_dac_out) ...
"C:\Program Files\Polyspace\R2021a\bin\matlab.exe" -batch "addpath(genpath('matlab')); analyze_dac_out"
if errorlevel 1 (
    echo.
    echo [FAIL] MATLAB 分析失败 (若闪退见 doc/fpga_sim_guide.md FAQ)
    if /i not "%~1"=="-nopause" pause
    exit /b 1
)

echo.
echo ============================================================
echo  完成! 判据: 4 波束峰应在 210 / 930 / -850 / -130 MHz
echo  (偏差 <1MHz 为通过; 1500/2200MHz 混叠到负频率是正常的)
echo  更详细的正确性图见 matlab\figs\ (跑 verify_model_figs 生成)
echo ============================================================
if /i not "%~1"=="-nopause" pause
endlocal
