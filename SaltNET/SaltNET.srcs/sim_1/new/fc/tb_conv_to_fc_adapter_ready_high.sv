`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: tb_conv_to_fc_adapter_ready_high
// Description:
//   ConvToFCAdapter,情況:上游每拍都送、下游一直收。
//   最快的情況:每拍收一筆、送一筆,每筆剛好晚 1 拍;暫存器裡有一筆時下游同一拍收走,in_ready 要一直是 1。
//   比對都在 tb_conv_to_fc_adapter_common.svh(out_valid = 清單不空、in_ready = 清單空或下游收)。
//////////////////////////////////////////////////////////////////////////////////

module tb_conv_to_fc_adapter_ready_high;

	`include "tb_conv_to_fc_adapter_common.svh"

	function automatic bit upstream_sends();
		return 1'b1;
	endfunction

	function automatic bit downstream_ready();
		return 1'b1;
	endfunction

endmodule
