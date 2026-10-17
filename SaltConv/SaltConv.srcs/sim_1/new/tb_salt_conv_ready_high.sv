`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: tb_salt_conv_ready_high
// Description:
//   整層 SaltConv,情況:下游一直收(out_ready 一直是 1)、上游一直有事件。
//   除了共用的比對(tb_salt_conv_common.svh),另外比拍數:第一個 o_c 算的那一拍到最後一個 o_c 送完那一拍,
//   要等於答案(Σ max(1, k);OC = 1 時 Σ max(2, k)),確認管線化一個 o_c 最少 1 拍、中途沒有空拍。
//   涵蓋要求:FIFO 滿擋住上游(上游一直送,一筆事件至少 2 拍)、清除期間上游送事件;
//   下游從不擋,其他涵蓋項目碰不到。
//////////////////////////////////////////////////////////////////////////////////

module tb_salt_conv_ready_high;

	localparam bit CHECK_CYCLE_COUNT = 1'b1;

	`include "tb_salt_conv_common.svh"

	function automatic void reset_driver();
	endfunction

	function automatic bit drive_out_ready(int cycle);
		return 1'b1;
	endfunction

	function automatic bit input_starts_now();
		return 1'b1;
	endfunction

	function automatic void input_taken();
	endfunction

	function automatic bit coverage_wanted(int item);
		return item == COVER_UPSTREAM_BLOCKED
		    || item == COVER_VALID_DURING_CLEARING;
	endfunction

endmodule
