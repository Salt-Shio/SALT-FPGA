`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: tb_fc_membrane_register_back_to_back
// Description:
//   FCMembraneRegister,情況:每拍都送一列,列跟列、事件跟事件之間都不空拍。
//   最快的情況:下一筆事件的第 0 列緊接在最後一列後面,update_done 那一拍同時在寫下一筆事件的第 0 列,
//   那一拍 membranes 還要是上一筆事件完整的值。比對都在 tb_fc_membrane_register_common.svh。
//////////////////////////////////////////////////////////////////////////////////

module tb_fc_membrane_register_back_to_back;

	`include "tb_fc_membrane_register_common.svh"

	function automatic int idle_cycles_before_row();
		return 0;
	endfunction

endmodule
