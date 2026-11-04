`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: tb_salt_fc_ready_high
// Description:
//   整層 SaltFC(會 fire),情況:下游一直收(out_ready 一直是 1)、上游一直有事件。
//   除了共用的比對(tb_salt_fc_common.svh),另外比拍數:第一列算的那一拍到最後一列送完那一拍,
//   要等於答案(每列 max(1, k),加上不重疊、讀寫衝突要等的步數,見 gen_salt_fc_ref.py),
//   確認 fire 多的列停住的拍數剛好、中途沒有空拍。
//   涵蓋要求:FIFO 滿擋住上游(上游一直送)、清除期間上游送事件;下游從不擋,其他涵蓋項目碰不到。
//////////////////////////////////////////////////////////////////////////////////

module tb_salt_fc_ready_high;

	localparam bit CHECK_CYCLE_COUNT = 1'b1;

	`include "tb_salt_fc_common.svh"

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
