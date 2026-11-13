`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: tb_salt_conv_fc_net_input_random
// Description:
//   整個網路 SaltConvFCNet,情況:上游每拍 7 成機率開始送下一筆,輸入有空檔。
//   比對都在 tb_salt_conv_fc_net_common.svh。
//   輸入忽快忽慢,各層的 FIFO 忽滿忽空,層與層之間的 ready 一下 0 一下 1。
//////////////////////////////////////////////////////////////////////////////////

module tb_salt_conv_fc_net_input_random;

	`include "tb_salt_conv_fc_net_common.svh"

	function automatic void reset_driver();
	endfunction

	function automatic bit input_starts_now();
		return $urandom_range(0, 9) < 7;
	endfunction

endmodule
