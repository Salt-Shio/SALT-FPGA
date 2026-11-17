`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tb_microsecond_to_millisecond.sv
// MicrosecondToMillisecond 功能驗證:上下游都隨機交握時,每一筆送進去的事件都照順序出來,
// 時間等於 floor(t_us / 1000) 的低 TIME_WIDTH 位、payload 跟送進去的相同。
//   答案在這裡算:訓練端的 µs 換 ms 寫在讀 N-MNIST 檔的函式裡(data/src/nmnist.py,23 位元),
//   沒有能單獨叫的函式;用 64 位元整數除法 t_us / 1000。
//   輸入:邊界值、1000 的倍數前後一格、34 位元隨機值。
//   上游每拍 7 成機率開始送,送了就保持到被收;下游每拍 7 成機率收。
//   payload 每筆隨機,PAYLOAD_WIDTH 最多 32。
//
//   檔案照流程由上往下排:
//     1 DUT、時脈
//     2 輸入清單、答案
//     3 一拍:下降緣給值 → 上升緣前檢查 → 上升緣後判斷收送
//     4 測試主體:reset → 照清單送 → 收完剩下的 → 總結行
//////////////////////////////////////////////////////////////////////////////////

module tb_microsecond_to_millisecond;

	parameter integer TIME_WIDTH     = 16;
	parameter integer PAYLOAD_WIDTH  = 23;
	parameter integer PRODUCT_STAGES = 3;

	localparam integer IN_TIME_WIDTH = 34;
	localparam integer ENTRY_WIDTH   = TIME_WIDTH + PAYLOAD_WIDTH;   // 答案佇列一筆 {ms, payload}

	// ===============================================================
	// 1 DUT、時脈
	// ===============================================================
	logic clk   = 0;
	logic rst_n = 0;

	logic                     in_valid   = 0;
	logic                     in_ready;
	logic [IN_TIME_WIDTH-1:0] in_time_us = '0;
	logic [PAYLOAD_WIDTH-1:0] in_payload = '0;
	logic                     out_valid;
	logic                     out_ready  = 0;
	logic [TIME_WIDTH-1:0]    out_time;
	logic [PAYLOAD_WIDTH-1:0] out_payload;

	MicrosecondToMillisecond #(
		.TIME_WIDTH    (TIME_WIDTH),
		.PAYLOAD_WIDTH (PAYLOAD_WIDTH),
		.PRODUCT_STAGES(PRODUCT_STAGES)
	) dut (
		.clk        (clk),
		.rst_n      (rst_n),
		.in_valid   (in_valid),
		.in_ready   (in_ready),
		.in_time_us (in_time_us),
		.in_payload (in_payload),
		.out_valid  (out_valid),
		.out_ready  (out_ready),
		.out_time   (out_time),
		.out_payload(out_payload)
	);

	always #5 clk = ~clk;

	// ===============================================================
	// 2 輸入清單、答案
	// ===============================================================
	localparam longint unsigned MAX_TIME_US = (64'd1 << IN_TIME_WIDTH) - 1;   // 17179869183
	localparam longint unsigned MAX_K       = MAX_TIME_US / 1000;              // 最大的 1000 倍數是 MAX_K*1000

	logic [IN_TIME_WIDTH-1:0] inputs [$];

	function automatic logic [TIME_WIDTH-1:0] expected_time(input logic [IN_TIME_WIDTH-1:0] time_us);
		longint unsigned full_time;
		full_time = time_us;
		return TIME_WIDTH'(full_time / 1000);
	endfunction

	function automatic logic [IN_TIME_WIDTH-1:0] random_time();
		return {2'($urandom_range(0, 3)), 32'($urandom())};
	endfunction

	task automatic build_inputs();
		longint unsigned k;
		// 邊界:0 附近、第一個 1000、ms 低 16 位繞回(65536 ms)前後、34 位元最大值、最大的 1000 倍數前後
		longint unsigned boundaries [] = '{
			0, 1, 7, 8, 9, 999, 1000, 1001, 1999, 2000,
			65535999, 65536000, 65536001,
			MAX_K * 1000 - 1, MAX_K * 1000, MAX_K * 1000 + 1,
			MAX_TIME_US - 1, MAX_TIME_US
		};
		foreach (boundaries[i]) begin
			inputs.push_back(IN_TIME_WIDTH'(boundaries[i]));
		end
		// 1000 的倍數前後一格:商在這裡跳,常數取錯最容易在這裡錯
		for (int i = 0; i < 2000; i++) begin
			k = (i == 0) ? MAX_K : longint'($urandom_range(1, 32'(MAX_K)));
			inputs.push_back(IN_TIME_WIDTH'(k * 1000 - 1));
			inputs.push_back(IN_TIME_WIDTH'(k * 1000));
			inputs.push_back(IN_TIME_WIDTH'(k * 1000 + 1));
		end
		// 34 位元隨機
		for (int i = 0; i < 10000; i++) begin
			inputs.push_back(random_time());
		end
	endtask

	logic [ENTRY_WIDTH-1:0] expected_q [$];   // 收進去、還沒出來的 {ms, payload}

	int check_count = 0;
	int error_count = 0;
	int cycle       = 0;

	// ===============================================================
	// 3 一拍
	// ===============================================================
	// 上一拍 out_valid=1 卻沒被收:這一拍 out_valid 要還是 1、資料不變(握手規則)
	logic                     last_out_held    = 0;
	logic [TIME_WIDTH-1:0]    last_out_time    = '0;
	logic [PAYLOAD_WIDTH-1:0] last_out_payload = '0;

	task automatic step(
		input  logic                     drive_valid,
		input  logic [IN_TIME_WIDTH-1:0] drive_time,
		input  logic [PAYLOAD_WIDTH-1:0] drive_payload,
		input  logic                     drive_ready,
		output logic                     accepted
	);
		logic                     pre_in_ready;
		logic                     pre_out_valid;
		logic [TIME_WIDTH-1:0]    pre_out_time;
		logic [PAYLOAD_WIDTH-1:0] pre_out_payload;
		logic [ENTRY_WIDTH-1:0]   expected_entry;

		// 下降緣給值;in_ready 會跟著 out_ready 變,等 #1 組合邏輯穩定才讀
		@(negedge clk);
		in_valid   = drive_valid;
		in_time_us = drive_time;
		in_payload = drive_payload;
		out_ready  = drive_ready;
		#1;
		pre_in_ready    = in_ready;
		pre_out_valid   = out_valid;
		pre_out_time    = out_time;
		pre_out_payload = out_payload;

		// 上升緣前檢查
		if (last_out_held) begin
			check_count++;
			if (pre_out_valid !== 1'b1 || pre_out_time !== last_out_time || pre_out_payload !== last_out_payload) begin
				error_count++;
				$error("cycle %0d: 上一拍沒被收的輸出變了: expect valid=1 ms=%0d payload=%0h, actual valid=%0b ms=%0d payload=%0h",
				       cycle, last_out_time, last_out_payload, pre_out_valid, pre_out_time, pre_out_payload);
			end
		end
		// 下游收的拍子上游一定收得下(每拍收一筆)
		if (drive_ready) begin
			check_count++;
			if (pre_in_ready !== 1'b1) begin
				error_count++;
				$error("cycle %0d: out_ready=1 但 in_ready=%0b", cycle, pre_in_ready);
			end
		end

		// 上升緣後判斷這一拍收送了什麼
		@(posedge clk);
		#1;
		cycle++;

		accepted = drive_valid && pre_in_ready;
		if (accepted) begin
			expected_q.push_back({expected_time(drive_time), drive_payload});
		end

		if (drive_ready && pre_out_valid) begin
			check_count++;
			if (expected_q.size() == 0) begin
				error_count++;
				$error("cycle %0d: 送出 ms=%0d payload=%0h,但沒有收進去還沒出來的事件", cycle, pre_out_time, pre_out_payload);
			end else begin
				expected_entry = expected_q.pop_front();
				if ({pre_out_time, pre_out_payload} !== expected_entry) begin
					error_count++;
					$error("cycle %0d: 輸出不符: expect ms=%0d payload=%0h, actual ms=%0d payload=%0h", cycle,
					       expected_entry[ENTRY_WIDTH-1 -: TIME_WIDTH], expected_entry[PAYLOAD_WIDTH-1:0],
					       pre_out_time, pre_out_payload);
				end
			end
		end

		last_out_held    = pre_out_valid && !drive_ready;
		last_out_time    = pre_out_time;
		last_out_payload = pre_out_payload;
	endtask

	// ===============================================================
	// 4 測試主體
	// ===============================================================
	initial begin
		logic                     accepted;
		logic                     presenting;   // 這筆已經開始送(送了就保持到被收)
		logic [PAYLOAD_WIDTH-1:0] payload;
		int                       drain_cycles;

		build_inputs();

		// reset
		rst_n = 0;
		repeat (2) @(negedge clk);
		rst_n = 1;

		// 照清單送,上下游隨機交握
		foreach (inputs[i]) begin
			payload    = PAYLOAD_WIDTH'($urandom());
			presenting = 1'b0;
			accepted   = 1'b0;
			while (!accepted) begin
				if (!presenting) begin
					presenting = ($urandom_range(0, 9) < 7);
				end
				step(presenting, inputs[i], payload, ($urandom_range(0, 9) < 7), accepted);
			end
		end

		// 收完剩下的:下游一直收,最多管線深度加幾拍
		drain_cycles = 0;
		while (expected_q.size() > 0 && drain_cycles < PRODUCT_STAGES + 10) begin
			step(1'b0, '0, '0, 1'b1, accepted);
			drain_cycles++;
		end
		check_count++;
		if (expected_q.size() != 0 || out_valid !== 1'b0) begin
			error_count++;
			$error("收完之後還有 %0d 筆沒出來,out_valid=%0b", expected_q.size(), out_valid);
		end

		// 總結行:參數 NAME=value 開頭,ALL PASS / FAIL 結尾(run_tb_microsecond_to_millisecond.tcl 照這個格式找)
		$display("TIME_WIDTH=%0d PAYLOAD_WIDTH=%0d PRODUCT_STAGES=%0d: input_count=%0d cycle_count=%0d check_count=%0d error_count=%0d %s",
		         TIME_WIDTH, PAYLOAD_WIDTH, PRODUCT_STAGES, inputs.size(), cycle, check_count, error_count,
		         (error_count == 0) ? "ALL PASS" : "FAIL");

		$finish;
	end

endmodule
