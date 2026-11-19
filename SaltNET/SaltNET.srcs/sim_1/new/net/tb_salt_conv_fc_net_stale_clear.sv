`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: tb_salt_conv_fc_net_stale_clear
// Description:
//   整個網路 SaltConvFCNet,情況:一條很長、中間不 reset 的輸入,時間戳記真的繞回(docs/SNN/Todo「時間處理 → T3」)。
//   參數組 TIME_WIDTH 縮小(2^TIME_WIDTH ms 繞回)、STALE_CLEAR = 1;串流的組成見
//   scripts/net/gen_salt_conv_fc_net_stale_clear_ref.py 檔頭,裡面刻意放了沒有掃描就會算錯的神經元。
//   上游照事件時間送:上一筆被收下之後,至少再過「時間差 × CYCLES_PER_MS」拍才送下一筆(時間差 0 的連續送)。
//     不能 conv1 收得下就送:稀疏的事件(串流裡隔 50 ms 一筆)會一口氣塞進 FIFO,「現在」比 conv2 還沒處理的事件早上千 ms,
//     超過掃描的前提(門檻 − Δt_max,TIME_WIDTH = 11 時 949 ms),答案不保證。實際系統事件時間 1 ms 就是 1 ms(20 萬拍)。
//     也不能用一條固定的時間表:密集的段落處理比時間表慢,時間表一路落後,到稀疏的段落每筆都逾期,又會一口氣塞進去。
//     密集的段落每 ms 約 15 筆、conv1 一筆約 20 拍,比 CYCLES_PER_MS 慢,所以照樣有各層互相擋住的情況。
//   比對都在 tb_salt_conv_fc_net_common.svh(含每拍檢查上面那個前提);答案的時間是 mod 2^TIME_WIDTH,
//   串流結束時的狀態照答案的 clear_rule 允許被掃描清成全 0。
//   反向測試:STALE_CLEAR = 0 要 FAIL。
//////////////////////////////////////////////////////////////////////////////////

module tb_salt_conv_fc_net_stale_clear;

	// 答案:test 樣本接成的一條長串流(scripts/net/gen_salt_conv_fc_net_stale_clear_ref.py)
	localparam string REFERENCE_NAME      = "salt_conv_fc_net_stale_clear";
	localparam bit    CLEAR_RULE_IN_STATE = 1'b1;

	`include "tb_salt_conv_fc_net_common.svh"

	localparam integer CYCLES_PER_MS = 100;   // 事件時間 1 ms 至少隔幾拍

	int scheduled_index;   // scheduled_cycle 算的是第幾筆
	int scheduled_cycle;   // 第 scheduled_index 筆最早在第幾拍送

	function automatic void reset_driver();
		scheduled_index = -1;
		scheduled_cycle = 0;
	endfunction

	// 第一次問到第 event_index 筆,就是上一筆剛被收下的下一拍:從這一拍起等「時間差 × CYCLES_PER_MS」拍。
	// 時間差用 mod 2^TIME_WIDTH 算(答案的時間已經 mod 過;相鄰兩筆隔不到 2^TIME_WIDTH)
	function automatic bit input_starts_now(int cycle, int event_index);
		if (event_index != scheduled_index) begin
			int time_gap = (event_index == 0) ? 0
			             : TIME_WIDTH'(expected_in_t[event_index] - expected_in_t[event_index - 1]);
			scheduled_index = event_index;
			scheduled_cycle = cycle + time_gap * CYCLES_PER_MS;
		end
		return cycle >= scheduled_cycle;
	endfunction

endmodule
