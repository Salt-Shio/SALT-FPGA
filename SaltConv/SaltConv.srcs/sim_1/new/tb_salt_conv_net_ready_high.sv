`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: tb_salt_conv_net_ready_high
// Description:
//   兩層串接 SaltConvNet,情況:下游一直收(out_ready 一直是 1)、上游一直有事件(conv1 收得下就送下一筆)。
//   比對都在 tb_salt_conv_net_common.svh。
//   量延遲用這一支:軟體端隨時在收、輸入用最快的速度餵,log 的 latency 行是最壞情況的「輸入送完之後還要等幾拍」。
//   conv1 被擋只會來自 conv2 自己處理不完(conv2 的 FIFO 滿)。
//////////////////////////////////////////////////////////////////////////////////

module tb_salt_conv_net_ready_high;

	`include "tb_salt_conv_net_common.svh"

	function automatic void reset_driver();
	endfunction

	function automatic bit drive_out_ready(int cycle);
		return 1'b1;
	endfunction

	function automatic bit input_starts_now();
		return 1'b1;
	endfunction

endmodule
