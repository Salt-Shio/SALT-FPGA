`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: tb_salt_conv_ready_burst
// Description:
//   整層 SaltConv,情況:下游長時間不收、長時間收交替(out_ready 連續 0、連續 1 各 1~BURST_MAX 拍,
//   長的超過 FIFO 深度);上游每拍 7 成機率開始送下一筆,不停下來等。
//   下游長時間不收時 FIFO 會塞滿,擋住上游;下游開始收之後,塞滿的事件一筆接一筆處理。
//   比對都在 tb_salt_conv_common.svh。
//   涵蓋要求:下游不收時是算的那一拍、這個 o_c 還剩 2 個以上、o_c 的最後一個、事件的最後一個且 FIFO 有下一筆
//   (這組參數碰得到的),out_valid=0 時下游不收,FIFO 滿擋住上游,清除期間上游送事件。
//   不要求「事件的最後一個且 FIFO 空」、「樣本中途空下來再接事件」:上游不停,FIFO 很少空;
//   這兩項由 tb_salt_conv_ready_random 要求。
//////////////////////////////////////////////////////////////////////////////////

module tb_salt_conv_ready_burst;

	localparam bit CHECK_CYCLE_COUNT = 1'b0;
	localparam integer BURST_MAX = 80;   // out_ready 連續 0 或連續 1 的最長拍數

	`include "tb_salt_conv_common.svh"

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

	function automatic void input_taken();
	endfunction

	function automatic bit coverage_wanted(int item);
		return item == COVER_STALL_ON_COMPUTE_CYCLE
		    || item == COVER_STALL_WITH_MORE_LEFT
		    || item == COVER_STALL_LAST_OF_OC
		    || item == COVER_STALL_LAST_OF_EVENT_NEXT_QUEUED
		    || item == COVER_READY_LOW_WITHOUT_VALID
		    || item == COVER_UPSTREAM_BLOCKED
		    || item == COVER_VALID_DURING_CLEARING;
	endfunction

endmodule
