`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: tb_salt_conv_ready_random
// Description:
//   整層 SaltConv,情況:下游每拍隨機收不收(out_ready 每拍 0/1 各一半)、上游每拍 7 成機率開始送下一筆,
//   每筆被收走後有 2 成機率等 SaltConv 整個空下來(沒有 o_c 在做、FIFO 空)再空 0~3 拍才送下一筆。
//   比對都在 tb_salt_conv_common.svh。
//   等空下來之後送的那一筆,做的時候 FIFO 是空的;下游每拍隨機,它最後一個 o_c 的 fire 有一半機會被擋,
//   「事件的最後一個且 FIFO 空」靠這支碰。
//   涵蓋要求:下游不收的五種位置(這組參數碰得到的)、out_valid=0 時下游不收、樣本中途空下來再接事件、
//   清除期間上游送事件。
//////////////////////////////////////////////////////////////////////////////////

module tb_salt_conv_ready_random;

	localparam bit CHECK_CYCLE_COUNT = 1'b0;

	`include "tb_salt_conv_common.svh"

	bit wait_for_idle;   // 等 SaltConv 整個空下來才送下一筆
	int gap_left;        // 空下來之後再空幾拍

	function automatic void reset_driver();
		wait_for_idle = 1'b0;
		gap_left      = 0;
	endfunction

	function automatic bit drive_out_ready(int cycle);
		return 1'($urandom_range(0, 1));
	endfunction

	function automatic bit input_starts_now();
		if (wait_for_idle) begin
			if (dut_idle()) begin
				wait_for_idle = 1'b0;
				gap_left = $urandom_range(0, 3);
			end
			return 1'b0;
		end
		if (gap_left > 0) begin
			gap_left--;
			return 1'b0;
		end
		return $urandom_range(0, 9) < 7;
	endfunction

	function automatic void input_taken();
		if ($urandom_range(0, 9) < 2) wait_for_idle = 1'b1;
	endfunction

	function automatic bit coverage_wanted(int item);
		return item < FIRE_COVER_COUNT
		    || item == COVER_READY_LOW_WITHOUT_VALID
		    || item == COVER_RESUME_FROM_IDLE
		    || item == COVER_VALID_DURING_CLEARING;
	endfunction

endmodule
