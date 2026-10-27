`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: DecayLookup
// Description:
//   由這筆事件的時間 t 跟上一次更新的時間 t_last 算出衰減碼 A(Conv.md、FC.md 第 3 節 ①),純組合邏輯。
//     Δt = t - t_last:Δt=0 不衰減(A=1.0);1 <= Δt <= Δt_max 查衰減表 A[Δt];Δt > Δt_max 時 A=0。
//   輸出 decay_code 接 NeuronUpdate 的同名 port。
//     conv 每顆神經元有自己的 t_last,每個 bank 一份,跟 NeuronUpdate 一對一。
//     FC 整層共用 t_last,一列只要 1 份,n_col 份 NeuronUpdate 共用它的 decay_code。
//   Δt 用 TIME_WIDTH 位元無號減法:event_time < last_time 只會在時間戳記繞回時發生,
//   繞回怎麼處理還沒定,這時 Δt 是 mod 2^TIME_WIDTH 的值。
//   衰減表用 $readmemh 從 DECAY_FILE 載入,檔案格式見 Conv.md 第 3 節 ① 的「檔案格式」;
//   每一份 DecayLookup 各有一份,讀取是組合邏輯。
//////////////////////////////////////////////////////////////////////////////////

module DecayLookup #(
	parameter integer TIME_WIDTH        = 16,   // 單位:整數 ms
	parameter integer DECAY_FRAC_WIDTH  = 6,    // f_a,衰減碼小數位元
	parameter integer DECAY_TABLE_DEPTH = 75,   // Δt_max,衰減表深度

	// 不寫型別:Vivado 不支援 SystemVerilog string 型別參數,也不支援空字串參數(UG901)
	parameter DECAY_FILE = "decay.mem"   // 衰減表,位址 Δt-1,每字 DECAY_FRAC_WIDTH bits 無號
)(
	input  logic [TIME_WIDTH-1:0]     last_time,    // t_last
	input  logic [TIME_WIDTH-1:0]     event_time,   // t
	output logic [DECAY_FRAC_WIDTH:0] decay_code    // A[Δt],多 1 位放得下 Δt=0 的 1.0
);

	// 一律用 LUT,讀取是組合邏輯,conv 同一拍 M x M 份各查各的位址
	(* rom_style = "distributed" *) logic [DECAY_FRAC_WIDTH-1:0] decay_table [0:DECAY_TABLE_DEPTH-1];

	initial begin
		$readmemh(DECAY_FILE, decay_table);
	end

	/* reviewer:
		1. 是否有考慮透過 DECAY_TABLE_DEPTH 來判斷 delta_time 的位寬 ? 因為 delta_time 太大根本沒用
	*/
	logic [TIME_WIDTH-1:0] delta_time;
	logic                  is_same_time;   // Δt=0,不衰減

	assign delta_time   = event_time - last_time;
	assign is_same_time = (delta_time == '0);

	always_comb begin
		// Δt=0 時 A=1.0(2^f_a),NeuronUpdate ② 乘完捨回剛好是 V̂,乘法後面不用再選;Δt > Δt_max 時 A=0
		if (is_same_time) begin
			decay_code = {1'b1, {DECAY_FRAC_WIDTH{1'b0}}};
		end else if (delta_time > DECAY_TABLE_DEPTH) begin
			decay_code = '0;
		end else begin
			decay_code = {1'b0, decay_table[delta_time - 1'b1]};
		end
	end

endmodule
