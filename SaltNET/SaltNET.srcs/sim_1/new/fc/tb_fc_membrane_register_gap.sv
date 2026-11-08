`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: tb_fc_membrane_register_gap
// Description:
//   FCMembraneRegister,情況:每列之前有一半機率空 1~3 拍(同一筆事件的列之間、事件跟事件之間都會空),
//   空的拍子 membrane_valid=0、其他輸入送亂數:不能寫進去,也不能拉 update_done。
//   比對都在 tb_fc_membrane_register_common.svh。
//////////////////////////////////////////////////////////////////////////////////

module tb_fc_membrane_register_gap;

	`include "tb_fc_membrane_register_common.svh"

	function automatic int idle_cycles_before_row();
		if ($urandom_range(0, 1) == 0) return 0;
		return $urandom_range(1, 3);
	endfunction

endmodule
