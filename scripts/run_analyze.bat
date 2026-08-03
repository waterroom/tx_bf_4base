@echo off
REM ============================================================
REM  一键分析 FPGA 仿真 DAC 输出频谱
REM  避免在受限终端 (git-bash 沙箱等) 直接跑 matlab -batch 时
REM  Intel OpenMP 启动崩溃 (Access Violation, 与本项目脚本无关)
REM
REM  用法: 双击本文件, 或在 cmd/PowerShell 中运行:
REM    scripts\run_analyze.bat
REM ============================================================
setlocal
cd /d "%~dp0.."

echo 正在启动 MATLAB 验证 FPGA 仿真输出 (8 阵元 × 4 波束 + 模型对比)...
echo.

"C:\Program Files\Polyspace\R2021a\bin\matlab.exe" -batch "addpath('matlab'); tx_bf_verify(0)"

echo.
echo 分析完成 (退出码 %ERRORLEVEL%)。
pause
endlocal
