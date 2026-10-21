`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: tb_salt_conv_net_ready_burst
// Description:
//   兩層串接 SaltConvNet,情況:下游長時間不收、長時間收交替(out_ready 連續 0、連續 1 各 1~BURST_MAX 拍,
//   長的超過 FIFO 深度);上游每拍 7 成機率開始送下一筆,不停下來等。
//   比對都在 tb_salt_conv_net_common.svh。
//   下游長時間不收時,conv2 的 FIFO 塞滿擋住 conv1,conv1 的 FIFO 再塞滿擋住上游,兩層一起停;
//   下游開始收之後,兩層塞滿的事件一筆接一筆處理。
//////////////////////////////////////////////////////////////////////////////////

module tb_salt_conv_net_ready_burst;

	localparam integer BURST_MAX = 80;   // out_ready 連續 0 或連續 1 的最長拍數

	`include "tb_salt_conv_net_common.svh"

	int burst_left;   // out_ready 這一段還剩幾拍
	bit burst_level;

	function automatic void reset_driver();
		burst_left  = 0;
		burst_level = 1'b1;
	endfunction

	function automatic bit drive_out_ready(int cycle);
		if (burst_left == 0) begin
			burst_level = ~burst_level;
			burst_left  = $urandom_range(1, BURST_MAX);
		end
		burst_left--;
		return burst_level;
	endfunction

	function automatic bit input_starts_now();
		return $urandom_range(0, 9) < 7;
	endfunction

endmodule
