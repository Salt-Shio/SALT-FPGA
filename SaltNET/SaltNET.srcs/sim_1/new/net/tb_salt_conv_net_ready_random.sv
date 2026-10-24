`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: tb_salt_conv_net_ready_random
// Description:
//   兩層串接 SaltConvNet,情況:下游每拍隨機收不收(out_ready 每拍 0/1 各一半)、上游每拍 7 成機率開始送下一筆。
//   比對都在 tb_salt_conv_net_common.svh。
//   conv2 被下游擋住時 conv2 的 FIFO 會塞滿,再擋住 conv1:層與層之間的 ready 一下 0 一下 1。
//////////////////////////////////////////////////////////////////////////////////

module tb_salt_conv_net_ready_random;

	`include "tb_salt_conv_net_common.svh"

	function automatic void reset_driver();
	endfunction

	function automatic bit drive_out_ready(int cycle);
		return 1'($urandom_range(0, 1));
	endfunction

	function automatic bit input_starts_now();
		return $urandom_range(0, 9) < 7;
	endfunction

endmodule
