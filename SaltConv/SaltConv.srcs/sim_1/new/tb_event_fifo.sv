`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tb_event_fifo.sv
// EventFIFO 功能驗證。涵蓋:reset 初始狀態、write 追 read(full 正確觸發)、
// read 追 write(empty 正確觸發)、full/empty 時三種操作組合(只 write、只 read、
// 同時)、繞圈(wrap-around)資料完整性、每拍同時 push+pop、隨機化交握壓力測試。
// 用 SV queue 當參考模型,跟 DUT 用同一套 valid&&ready 判斷同步記錄 push/pop,
// 逐筆比對 DUT 吐出來的資料,不只驗證時序,也驗證資料順序跟內容。
//////////////////////////////////////////////////////////////////////////////////

module tb_event_fifo;

	localparam integer DATA_WIDTH = 8;
	localparam integer DEPTH      = 4;

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

	task automatic tick();
		@(posedge clk);
		#1;
	endtask

	int error_count = 0;

	/* ---------------- 參考模型:跟邊界訊號同步判斷 push/pop,逐筆比對 ---------------- */
	logic [DATA_WIDTH-1:0] ref_q[$];
	int checked_count = 0;

	always @(posedge clk) begin
		#1;
		if (rst_n) begin
			if (wr_valid && wr_ready) begin
				ref_q.push_back(wr_data);
			end
			if (rd_valid && rd_ready) begin
				logic [DATA_WIDTH-1:0] exp;
				checked_count++;
				if (ref_q.size() == 0) begin
					$error("[%0t] 收到未預期的 pop: rd_data=%0d,但參考佇列是空的", $time, rd_data);
					error_count++;
				end else begin
					exp = ref_q.pop_front();
					if (rd_data !== exp) begin
						$error("[%0t] 資料不對: got=%0d expect=%0d", $time, rd_data, exp);
						error_count++;
					end
				end
			end
		end
	end

	/* ---------------- 單拍驅動:只維持一拍不等待,用來測「這一拍到底有沒有被接受」 ---------------- */
	task automatic try_push_one_cycle(input logic [DATA_WIDTH-1:0] data, output bit accepted);
		wr_data  = data;
		wr_valid = 1'b1;
		#0;
		accepted = wr_ready;
		tick();
		wr_valid = 1'b0;
	endtask

	task automatic try_pop_one_cycle(output bit accepted, output logic [DATA_WIDTH-1:0] data);
		rd_ready = 1'b1;
		#0;
		accepted = rd_valid;
		data = rd_data;
		tick();
		rd_ready = 1'b0;
	endtask

	/* ---------------- 一般 push/pop:等到真的被接受才返回 ---------------- */
	task automatic push_blocking(input logic [DATA_WIDTH-1:0] data);
		bit accepted;
		wr_data  = data;
		wr_valid = 1'b1;
		accepted = 1'b0;
		while (!accepted) begin
			accepted = wr_ready;
			tick();
		end
		wr_valid = 1'b0;
	endtask

	task automatic pop_blocking(output logic [DATA_WIDTH-1:0] data);
		bit accepted;
		rd_ready = 1'b1;
		accepted = 1'b0;
		while (!accepted) begin
			accepted = rd_valid;
			if (accepted) data = rd_data;
			tick();
		end
		rd_ready = 1'b0;
	endtask

	task automatic do_reset();
		rst_n    = 1'b0;
		wr_valid = 1'b0;
		rd_ready = 1'b0;
		repeat (3) tick();
		rst_n = 1'b1;
		tick();
	endtask

	task automatic check(input bit cond, input string msg);
		if (!cond) begin
			$error("[%0t] %s", $time, msg);
			error_count++;
		end
	endtask

	// 把 FIFO(跟參考佇列)清空,帶逾時保護——真的有 bug 導致清不空時,
	// 要能明確報錯,不能讓整個仿真卡死看不到任何訊息
	task automatic drain_all(input string stage_name);
		int guard;
		guard = 0;
		rd_ready = 1'b1;
		while (ref_q.size() != 0 && guard < 2000) begin
			tick();
			guard++;
		end
		rd_ready = 1'b0;
		check(ref_q.size() == 0, {stage_name, ": drain_all 逾時,資料清不空,懷疑 rd_valid 卡住或資料漏收"});
	endtask

	/* ---------------- 主測試流程 ---------------- */
	initial begin
		bit accepted;
		logic [DATA_WIDTH-1:0] got;
		int i;

		do_reset();

		// Stage 0: reset 後的初始狀態
		check(wr_ready === 1'b1, "Stage0: reset 後 wr_ready 應該是 1(空的,可以收)");
		check(rd_valid === 1'b0, "Stage0: reset 後 rd_valid 應該是 0(空的,沒東西可讀)");

		// Stage 1: 基本單筆 push+pop,資料內容由 scoreboard 自動比對
		push_blocking(8'd1);
		pop_blocking(got);

		// Stage 2: write 追 read,連續 push DEPTH 筆(不 pop),驗證 full 正確觸發
		for (i = 0; i < DEPTH; i++) begin
			push_blocking(8'(100+i));
		end
		check(wr_ready === 1'b0, "Stage2: 連續 push DEPTH 筆後應該 full(wr_ready=0)");

		// Stage 3a: full 時只 write,應該被擋下
		try_push_one_cycle(8'hFF, accepted);
		check(!accepted, "Stage3a: full 時 push 不應該被接受");

		// Stage 3b: full 時只 read,應該正常,pop 一筆後不再 full
		try_pop_one_cycle(accepted, got);
		check(accepted, "Stage3b: full 時 pop 應該正常被接受");
		check(wr_ready === 1'b1, "Stage3b: pop 一筆後,下一拍不應該再 full");

		// 補回一筆,重新填滿到 full,準備測 3c
		push_blocking(8'd200);
		check(wr_ready === 1'b0, "Stage3b後置: 補回一筆後應該重新 full");

		// Stage 3c: full 時同時 read+write:push 被擋、pop 正常,
		//           這一拍只有 pop 真的發生,full 應該從 1 變回 0(走 case 2'b01,不是 2'b11)
		wr_valid = 1'b1; wr_data = 8'hEE;
		rd_ready = 1'b1;
		#0;
		check(wr_ready === 1'b0, "Stage3c: full 時同時 read+write 那一拍,wr_ready 應該還是 0");
		check(rd_valid === 1'b1, "Stage3c: full 時同時 read+write 那一拍,rd_valid 應該是 1(滿了一定有資料)");
		tick();
		wr_valid = 1'b0;
		rd_ready = 1'b0;
		check(wr_ready === 1'b1, "Stage3c: 上一拍只有 pop 真的發生,這一拍不應該再 full");

		// Stage 4: read 追 write,把剩下的資料全部讀完,驗證 empty 正確觸發
		drain_all("Stage4");
		check(rd_valid === 1'b0, "Stage4: 讀到底後應該 empty(rd_valid=0)");

		// Stage 5a: empty 時只 read,應該被擋下
		try_pop_one_cycle(accepted, got);
		check(!accepted, "Stage5a: empty 時 pop 不應該被接受");

		// Stage 5b: empty 時只 write,應該正常,push 一筆後不再 empty
		try_push_one_cycle(8'd201, accepted);
		check(accepted, "Stage5b: empty 時 push 應該正常被接受");
		check(rd_valid === 1'b1, "Stage5b: push 一筆後,下一拍不應該再 empty");

		// 清空,重新回到 empty,準備測 5c
		pop_blocking(got);
		check(rd_valid === 1'b0, "Stage5b後置: 讀完那一筆後應該重新 empty");

		// Stage 5c: empty 時同時 read+write:pop 被擋、push 正常,
		//           這一拍只有 push 真的發生,empty 應該從 1 變回 0(走 case 2'b10,不是 2'b11)
		wr_valid = 1'b1; wr_data = 8'hDD;
		rd_ready = 1'b1;
		#0;
		check(rd_valid === 1'b0, "Stage5c: empty 時同時 read+write 那一拍,rd_valid 應該還是 0");
		check(wr_ready === 1'b1, "Stage5c: empty 時同時 read+write 那一拍,wr_ready 應該是 1(沒滿一定能收)");
		tick();
		wr_valid = 1'b0;
		rd_ready = 1'b0;
		check(rd_valid === 1'b1, "Stage5c: 上一拍只有 push 真的發生,這一拍不應該再 empty");

		// 清空,回到乾淨狀態,準備後面的測試
		pop_blocking(got);

		// Stage 6: 繞圈(wrap-around)資料完整性,push/pop 交替次數遠超過 DEPTH,
		//          讓 w、r 指標繞圈好幾次,全程靠 scoreboard 自動比對資料順序跟內容
		for (i = 0; i < DEPTH * 5; i++) begin
			push_blocking(8'(i));
			pop_blocking(got);
		end

		// Stage 7: 每拍同時 push+pop(滿載吞吐),驗證 case 2'b11(都有)維持 full/empty 不變、
		//          資料順序依然正確
		push_blocking(8'hAA); // 先墊一筆,讓 FIFO 非空也非滿
		wr_valid = 1'b1;
		rd_ready = 1'b1;
		for (i = 0; i < 20; i++) begin
			wr_data = 8'(i);
			tick();
		end
		wr_valid = 1'b0;
		rd_ready = 1'b0;
		// 收尾:把 Stage7 期間還卡在 FIFO 裡、還沒被讀走的資料清乾淨
		drain_all("Stage7後置");

		// Stage 8: 隨機化交握壓力測試,wr_valid、rd_ready 各自隨機 toggle
		for (i = 0; i < 500; i++) begin
			wr_valid = $urandom_range(0, 1);
			wr_data  = 8'($urandom_range(0, 255));
			rd_ready = $urandom_range(0, 1);
			tick();
		end
		wr_valid = 1'b0;
		rd_ready = 1'b0;
		// 收尾:確認 Stage8 期間寫進去、還沒讀完的資料全部排乾淨
		drain_all("Stage8後置");

		if (error_count == 0)
			$display("=== ALL PASS (%0d transfers checked) ===", checked_count);
		else
			$display("=== FAIL: %0d errors, %0d transfers checked ===", error_count, checked_count);

		$finish;
	end

endmodule
