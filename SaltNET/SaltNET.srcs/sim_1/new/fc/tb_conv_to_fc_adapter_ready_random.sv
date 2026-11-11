`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: tb_conv_to_fc_adapter_ready_random
// Description:
//   ConvToFCAdapter,情況:上游每拍一半機率送下一筆、下游每拍一半機率收。
//   下游不收而暫存器有一筆時,in_ready 要是 0,上游那筆維持到收下為止,暫存器那筆不能被蓋掉、值不能變;
//   順序、不掉不重複都靠 tb_conv_to_fc_adapter_common.svh 的清單比對。
//////////////////////////////////////////////////////////////////////////////////

module tb_conv_to_fc_adapter_ready_random;

	`include "tb_conv_to_fc_adapter_common.svh"

	function automatic bit upstream_sends();
		return $urandom_range(0, 1) == 1;
	endfunction

	function automatic bit downstream_ready();
		return $urandom_range(0, 1) == 1;
	endfunction

endmodule
