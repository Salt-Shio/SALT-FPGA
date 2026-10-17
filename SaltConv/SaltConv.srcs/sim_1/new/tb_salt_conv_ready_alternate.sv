`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: tb_salt_conv_ready_alternate
// Description:
//   整層 SaltConv,情況:下游一拍不收、一拍收輪流(out_ready 每拍 0、1 交替)、上游一直有事件。
//   送不出去的 fire 下一拍一定送得出去:「送不出去時資料不變」、「送出後下一拍換下一個」兩條規則一直交替碰到。
//   比對都在 tb_salt_conv_common.svh。
//   涵蓋要求:out_valid=0 時下游不收、FIFO 滿擋住上游(上游一直送,一筆事件至少 2 拍)、清除期間上游送事件。
//   不要求下游不收的五種位置:out_ready 固定交替,fire 落在哪一拍跟參數綁死,有的位置結構上碰不到
//   (例如 OC = 1 一筆事件剛好 2 拍,算的那一拍永遠是 out_ready=1)。這五項由 tb_salt_conv_ready_random、
//   tb_salt_conv_ready_burst 要求。
//////////////////////////////////////////////////////////////////////////////////

module tb_salt_conv_ready_alternate;

	localparam bit CHECK_CYCLE_COUNT = 1'b0;

	`include "tb_salt_conv_common.svh"

	function automatic void reset_driver();
	endfunction

	function automatic bit drive_out_ready(int cycle);
		return cycle[0];
	endfunction

	function automatic bit input_starts_now();
		return 1'b1;
	endfunction

	function automatic void input_taken();
	endfunction

	function automatic bit coverage_wanted(int item);
		return item == COVER_READY_LOW_WITHOUT_VALID
		    || item == COVER_UPSTREAM_BLOCKED
		    || item == COVER_VALID_DURING_CLEARING;
	endfunction

endmodule
