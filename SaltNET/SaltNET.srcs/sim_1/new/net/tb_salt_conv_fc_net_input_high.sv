`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: tb_salt_conv_fc_net_input_high
// Description:
//   整個網路 SaltConvFCNet,情況:上游一直有事件(conv1 收得下就送下一筆),輸入用最快的速度餵。
//   比對都在 tb_salt_conv_fc_net_common.svh。
//   層與層之間被擋只會來自下一層自己處理不完(下一層的 FIFO 滿,或轉接模組的暫存器送不進 SaltFC 的 FIFO)。
//////////////////////////////////////////////////////////////////////////////////

module tb_salt_conv_fc_net_input_high;

	`include "tb_salt_conv_fc_net_common.svh"

	function automatic void reset_driver();
	endfunction

	function automatic bit input_starts_now();
		return 1'b1;
	endfunction

endmodule
