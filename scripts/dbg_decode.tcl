# dbg_decode.tcl — 命令行调试 tb_decode_cmd_tx_bf (XPM + glbl)
set proj_root "C:/workbuddy_chat/tx_bf_4base"
cd $proj_root
set glbl [file join $env(RDI_DATADIR) "verilog" "src" "glbl.v"]
puts "=== 编译 (rtl + tb + glbl) ==="
exec xvlog -sv -i rtl [file join $proj_root rtl tx_bf_pkg.sv] [file join $proj_root rtl decode_cmd_tx_bf.sv] [file join $proj_root tb tb_decode_cmd_tx_bf.sv]
exec xvlog $glbl
puts "=== 精化 ==="
exec xelab -debug typical -L xpm tb_decode_cmd_tx_bf glbl -s tb_decode
puts "=== 仿真 ==="
set sim_res [exec xsim tb_decode -runall]
puts $sim_res
puts "=== 完成 ==="
