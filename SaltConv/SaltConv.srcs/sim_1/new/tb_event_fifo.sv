`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tb_event_fifo.sv
// EventFIFO 功能驗證。
// 用 SystemVerilog queue 當參考模型(ref_q),每次真的發生 push/pop 才同步更新,
// 逐筆比對 DUT 吐出來的 rd_data 是否跟參考模型一致。
//////////////////////////////////////////////////////////////////////////////////

module tb_event_fifo;

	localparam integer DATA_WIDTH = 8;
	localparam integer DEPTH      = 16;

	logic clk = 0;
	logic rst_n = 0;

	logic wr_valid = 0;
	logic wr_ready;
	logic [DATA_WIDTH-1:0] wr_data = '0;

	logic rd_valid;
	logic rd_ready = 0;
	logic [DATA_WIDTH-1:0] rd_data;

	EventFIFO #(
		.DATA_WIDTH(DATA_WIDTH),
		.DEPTH(DEPTH)
	) dut (
		.clk(clk),
		.rst_n(rst_n),
		.wr_valid(wr_valid),
		.wr_ready(wr_ready),
		.wr_data(wr_data),
		.rd_valid(rd_valid),
		.rd_ready(rd_ready),
		.rd_data(rd_data)
	);

	always #5 clk = ~clk;

	// ------------------------------------------------------------------
	// 參考模型與統計
	// ------------------------------------------------------------------
	logic [DATA_WIDTH-1:0] ref_q[$];
	logic [DATA_WIDTH-1:0] data_ctr = '0;

	int check_count = 0;
	int error_count = 0;

	function automatic logic [DATA_WIDTH-1:0] next_data();
		next_data = data_ctr;
		data_ctr  = data_ctr + 1'b1;
	endfunction

	// ------------------------------------------------------------------
	// 驅動/取樣核心:negedge 驅動輸入,posedge 之後 #1 取樣輸出。
	// pre_* 在 negedge(這次 edge 真正發生前)取樣,用來判斷這次 edge 是否
	// 真的發生 push/pop,不受「哪個 process 先跑」影響。
	// ------------------------------------------------------------------
	task automatic step(
		input logic                  i_wr_valid,
		input logic [DATA_WIDTH-1:0] i_wr_data,
		input logic                  i_rd_ready
	);
		logic pre_wr_ready, pre_rd_valid;
		logic [DATA_WIDTH-1:0] pre_rd_data;
		logic did_push, did_pop;
		logic [DATA_WIDTH-1:0] expected_data;

		@(negedge clk);
		pre_wr_ready = wr_ready;
		pre_rd_valid = rd_valid;
		pre_rd_data  = rd_data;

		wr_valid = i_wr_valid;
		wr_data  = i_wr_data;
		rd_ready = i_rd_ready;

		@(posedge clk);
		#1;

		did_push = i_wr_valid && pre_wr_ready;
		did_pop  = i_rd_ready && pre_rd_valid;

		if (did_push) begin
			ref_q.push_back(i_wr_data);
		end

		if (did_pop) begin
			check_count++;
			if (ref_q.size() == 0) begin
				error_count++;
				$error("[%0t] pop 發生但 ref_q 是空的", $time);
			end else begin
				expected_data = ref_q.pop_front();
				if (pre_rd_data !== expected_data) begin
					error_count++;
					$error("[%0t] rd_data 不符: expect=%0d actual=%0d", $time, expected_data, pre_rd_data);
				end
			end
		end
	endtask

	task automatic check_flags(input string ctx, input logic exp_wr_ready, input logic exp_rd_valid);
		check_count++;
		if (wr_ready !== exp_wr_ready) begin
			error_count++;
			$error("[%0t] %s: wr_ready 不符 expect=%0d actual=%0d", $time, ctx, exp_wr_ready, wr_ready);
		end

		check_count++;
		if (rd_valid !== exp_rd_valid) begin
			error_count++;
			$error("[%0t] %s: rd_valid 不符 expect=%0d actual=%0d", $time, ctx, exp_rd_valid, rd_valid);
		end
	endtask

	task automatic check_size(input string ctx, input int exp_size);
		check_count++;
		if (ref_q.size() != exp_size) begin
			error_count++;
			$error("[%0t] %s: ref_q size 不符 expect=%0d actual=%0d", $time, ctx, exp_size, ref_q.size());
		end
	endtask

	// ------------------------------------------------------------------
	// 常用序列:填到/清到指定筆數(呼叫端要保證 target 在 [0, DEPTH] 範圍內
	// 且過程中不會撞到對向邊界)。
	// ------------------------------------------------------------------
	task automatic push_n(input int n);
		for (int i = 0; i < n; i++) begin
			step(1'b1, next_data(), 1'b0);
		end
	endtask

	task automatic pop_n(input int n);
		for (int i = 0; i < n; i++) begin
			step(1'b0, '0, 1'b1);
		end
	endtask

	task automatic fill_to(input int target);
		int cur;
		cur = ref_q.size();
		if (target > cur) push_n(target - cur);
		else if (target < cur) pop_n(cur - target);
	endtask

	task automatic do_reset();
		rst_n    = 0;
		wr_valid = 0;
		rd_ready = 0;
		wr_data  = '0;
		repeat (2) @(negedge clk);
		rst_n = 1;
		@(posedge clk);
		#1;
	endtask

	task automatic random_stress(input int n_cycles);
		for (int i = 0; i < n_cycles; i++) begin
			step($urandom_range(0, 1), $urandom_range(0, (1 << DATA_WIDTH) - 1), $urandom_range(0, 1));
		end
	endtask

	// ------------------------------------------------------------------
	// 測試主體
	// ------------------------------------------------------------------
	initial begin
		$timeformat(-9, 0, " ns", 10);

		// Stage 0: reset 後初始狀態
		$display("=== Stage 0: reset 後初始狀態 ===");
		do_reset();
		check_flags("Stage0", 1'b1, 1'b0);

		// Stage 1: 基本單筆 push+pop
		$display("=== Stage 1: 基本單筆 push+pop ===");
		step(1'b1, next_data(), 1'b0);
		check_flags("Stage1 push 後", 1'b1, 1'b1);
		step(1'b0, '0, 1'b1);
		check_flags("Stage1 pop 後", 1'b1, 1'b0);

		// Stage 2: write 追 read,連續 push 到 full
		$display("=== Stage 2: write 追 read,push 到 full ===");
		fill_to(DEPTH);
		check_flags("Stage2 填滿後", 1'b0, 1'b1);

		// Stage 3a: full 時只 write,應被擋
		$display("=== Stage 3a: full 時只 write ===");
		step(1'b1, next_data(), 1'b0);
		check_flags("Stage3a", 1'b0, 1'b1);
		check_size("Stage3a", DEPTH);

		// Stage 3b: full 時只 read,應正常且解除 full
		$display("=== Stage 3b: full 時只 read ===");
		step(1'b0, '0, 1'b1);
		check_flags("Stage3b", 1'b1, 1'b1);

		// Stage 3c: 補回到 full,再測 full 時同時 read+write
		$display("=== Stage 3c: full 時同時 read+write ===");
		fill_to(DEPTH);
		check_flags("Stage3c 補滿後", 1'b0, 1'b1);
		step(1'b1, next_data(), 1'b1);
		check_flags("Stage3c 同時後", 1'b1, 1'b1);

		// Stage 4: read 追 write,清到 empty
		$display("=== Stage 4: read 追 write,pop 到 empty ===");
		fill_to(0);
		check_flags("Stage4 清空後", 1'b1, 1'b0);

		// Stage 5a: empty 時只 read,應被擋
		$display("=== Stage 5a: empty 時只 read ===");
		step(1'b0, '0, 1'b1);
		check_flags("Stage5a", 1'b1, 1'b0);

		// Stage 5b: empty 時只 write,應正常且解除 empty
		$display("=== Stage 5b: empty 時只 write ===");
		step(1'b1, next_data(), 1'b0);
		check_flags("Stage5b", 1'b1, 1'b1);

		// Stage 5c: 清回到 empty,再測 empty 時同時 read+write
		$display("=== Stage 5c: empty 時同時 read+write ===");
		fill_to(0);
		check_flags("Stage5c 清空後", 1'b1, 1'b0);
		step(1'b1, next_data(), 1'b1);
		check_flags("Stage5c 同時後", 1'b1, 1'b1);

		// Stage 6: 繞圈(wrap-around),交替次數遠超過 DEPTH
		$display("=== Stage 6: wrap-around ===");
		for (int i = 0; i < DEPTH * 3; i++) begin
			push_n(1);
			pop_n(1);
		end

		// Stage 7: 每拍同時 push+pop(滿載吞吐)
		$display("=== Stage 7: 每拍同時 push+pop ===");
		fill_to(DEPTH / 2);
		for (int i = 0; i < DEPTH * 4; i++) begin
			step(1'b1, next_data(), 1'b1);
			check_flags("Stage7", 1'b1, 1'b1);
		end

		// Stage 8: 隨機化交握壓力測試
		$display("=== Stage 8: 隨機化交握壓力測試 ===");
		random_stress(500);

		// 收尾:清空 FIFO,回到已知狀態
		fill_to(0);

		if (error_count == 0)
			$display("=== ALL PASS: check_count=%0d, error_count=0 ===", check_count);
		else
			$display("=== FAIL: check_count=%0d, error_count=%0d ===", check_count, error_count);

		$finish;
	end

endmodule
