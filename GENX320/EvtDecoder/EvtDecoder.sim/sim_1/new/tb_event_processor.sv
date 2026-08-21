`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tb_event_processor.sv
// EventProcessor 單元測試,自帶 scoreboard(queue-based),不倚賴人眼看波形。
// 展開演算法在這裡獨立重算(由低到高逐 bit 掃),不是抄 DUT 的 priority encoder RTL。
//
// 時序規則:所有驅動 DUT 輸入、讀取 DUT 輸出的動作,一律透過 tick() 對齊到
// 「posedge 之後 1ns」這個安全取樣點,不直接用裸的 @(posedge clk)。
// 原因:裸 @(posedge clk) 之後立刻用 blocking assignment 改變 s_data/s_valid,
// 會跟 DUT 自己那顆 always_ff 在同一個 edge 上競爭(哪個先被排程不保證),
// 同一顆訊號在同一個 timestep 內可能被讀到新值也可能讀到舊值。tick() 內的
// #1 讓當拍所有 NBA 更新都已經生效、穩定下來,才進行下一步,徹底避開這個問題。
//////////////////////////////////////////////////////////////////////////////////

module tb_event_processor;

	localparam integer TDATA_W = 64;

	logic clk = 0;
	logic rstn = 0;

	logic s_valid = 0;
	logic s_ready;
	logic [TDATA_W-1:0] s_data = '0;

	logic m_valid;
	logic [TDATA_W-1:0] m_data;
	logic [(TDATA_W/8)-1:0] m_strb;
	logic m_last;
	logic m_ready = 1;

	logic cfg_enable = 1;
	logic cfg_enable_pattern = 0;
	logic [15:0] cfg_tlast_timeout = 16'hFFFF;
	logic cfg_tlast_timeout_enable = 1;

	EventProcessor #(
		.C_S_AXIS_TDATA_WIDTH(TDATA_W),
		.C_M_AXIS_TDATA_WIDTH(TDATA_W)
	) dut (
		.AXIS_ACLK(clk),
		.AXIS_ARESETN(rstn),
		.S_AXIS_TREADY(s_ready),
		.S_AXIS_TDATA(s_data),
		.S_AXIS_TSTRB('1),
		.S_AXIS_TLAST(1'b0),
		.S_AXIS_TVALID(s_valid),
		.M_AXIS_TVALID(m_valid),
		.M_AXIS_TDATA(m_data),
		.M_AXIS_TSTRB(m_strb),
		.M_AXIS_TLAST(m_last),
		.M_AXIS_TREADY(m_ready),
		.cfg_enable(cfg_enable),
		.cfg_enable_pattern(cfg_enable_pattern),
		.cfg_tlast_timeout(cfg_tlast_timeout),
		.cfg_tlast_timeout_enable(cfg_tlast_timeout_enable)
	);

	always #5 clk = ~clk;

	// 唯一的時序同步點:posedge 過後 1ns,所有本拍的暫存器更新都已生效
	task automatic tick();
		@(posedge clk);
		#1;
	endtask

	// ---------------- scoreboard ----------------
	typedef struct packed {
		logic [10:0] x;
		logic [10:0] y;
		logic        typ;
		logic [27:0] time_high;
		logic [5:0]  time_lo;
	} exp_evt_t;

	exp_evt_t exp_q[$];
	int error_count = 0;
	int checked_count = 0;

	// 軟體端獨立追蹤的參考狀態(不是抄 DUT 的暫存器)
	logic [27:0] ref_time_high = '0;
	logic        ref_time_valid = 1'b0;

	task automatic push_td(input logic [3:0] typ, input logic [5:0] tlo,
	                        input logic [10:0] x, input logic [10:0] y,
	                        input logic [31:0] mask);
		exp_evt_t e;
		if (!ref_time_valid) return; // 還沒收過 TIME_HIGH,這筆整個丟棄
		for (int i = 0; i < 32; i++) begin
			if (mask[i]) begin
				e.x = x + i[10:0];
				e.y = y;
				e.typ = typ[0];
				e.time_high = ref_time_high;
				e.time_lo = tlo;
				exp_q.push_back(e);
			end
		end
	endtask

	// ---------------- driver ----------------
	// 呼叫時機規定:呼叫這個 task 前,必須已經站在某次 tick() 之後的安全點上
	// (也就是上一個動作是 tick() 或另一個 send_word),不能接在裸 @(posedge clk) 後面。
	task automatic send_word(input logic [TDATA_W-1:0] data);
		bit accepted;
		s_data  = data;
		s_valid = 1'b1;
		accepted = 1'b0;
		while (!accepted) begin
			// 在還沒跨過這個 edge 之前先取樣 s_ready,這才是「這個 edge 會不會成立握手」
			// 的依據——tick() 跨過 edge 之後 s_ready 隨時可能因為別的原因(比如已經
			// 進 EXPAND 忙別的事)變 0,不能拿 tick() 之後的 s_ready 來判斷這一輪握手
			// 有沒有成立。
			accepted = s_ready;
			tick();
		end
		s_valid = 1'b0;
	endtask

	task automatic send_time_high(input logic [27:0] th);
		logic [TDATA_W-1:0] w;
		w = {4'h8, th, 32'd0};
		send_word(w);
		ref_time_high  = th;
		ref_time_valid = 1'b1;
	endtask

	task automatic send_td(input logic [3:0] typ, input logic [5:0] tlo,
	                        input logic [10:0] x, input logic [10:0] y,
	                        input logic [31:0] mask);
		logic [TDATA_W-1:0] w;
		w = {typ, tlo, x, y, mask};
		push_td(typ, tlo, x, y, mask);
		send_word(w);
	endtask

	// ---------------- 隨機化的 driver:上游送資料前故意隨機空幾拍 ----------------
	// 前面 send_word 都是「一有資料就馬上送」,master 行為固定死板,永遠不會提前
	// 出現空拍。這組專門給 Test 8 用,證明就算上游偶爾慢半拍、不是每次都立刻把
	// TVALID 準備好,DUT 也不會因此出錯——跟 send_word 分開,是為了不去動到既有
	// 測試(尤其 Test 6 特別要測「完全沒有空拍的背靠背」這個精確情境)的既有行為。
	task automatic send_word_gap(input logic [TDATA_W-1:0] data);
		bit accepted;
		int pre_gap;
		pre_gap = $urandom_range(0, 4);
		repeat (pre_gap) tick();
		s_data  = data;
		s_valid = 1'b1;
		accepted = 1'b0;
		while (!accepted) begin
			accepted = s_ready;
			tick();
		end
		s_valid = 1'b0;
	endtask

	task automatic send_time_high_gap(input logic [27:0] th);
		logic [TDATA_W-1:0] w;
		w = {4'h8, th, 32'd0};
		send_word_gap(w);
		ref_time_high  = th;
		ref_time_valid = 1'b1;
	endtask

	task automatic send_td_gap(input logic [3:0] typ, input logic [5:0] tlo,
	                            input logic [10:0] x, input logic [10:0] y,
	                            input logic [31:0] mask);
		logic [TDATA_W-1:0] w;
		w = {typ, tlo, x, y, mask};
		push_td(typ, tlo, x, y, mask);
		send_word_gap(w);
	endtask

	int tlast_high_count = 0;
	int tlast_low_count = 0;

	// ---------------- monitor / checker(跟 tick() 用同一個 1ns 安全點取樣)----------------
	always @(posedge clk) begin
		#1;
		// pattern 模式的輸出不是這個 scoreboard 管的範圍(Test 9 自己另外檢查),
		// 不排除的話,pattern 模式每一筆都會被這裡誤判成「不在預期內的事件」。
		if (rstn && m_valid && m_ready && !cfg_enable_pattern) begin
			exp_evt_t e;
			logic [TDATA_W-1:0] exp_data;
			checked_count++;
			if (exp_q.size() == 0) begin
				$error("[%0t] 收到未預期的事件,但 scoreboard queue 是空的: data=%h", $time, m_data);
				error_count++;
			end else begin
				e = exp_q.pop_front();
				exp_data = {e.x, e.y, e.typ, e.time_high, e.time_lo};
				if (m_data !== exp_data) begin
					$error("[%0t] 事件內容不對: got=%h expect=%h", $time, m_data, exp_data);
					error_count++;
				end
			end
			if (m_last) tlast_high_count++;
			else tlast_low_count++;
		end
	end

	// ---------------- backpressure 產生器(NBA 驅動,不受這個競爭問題影響)----------------
	bit bp_enable = 0;
	always @(posedge clk) begin
		if (bp_enable) m_ready <= $urandom_range(0, 1);
		else m_ready <= 1'b1;
	end

	// ---------------- reset ----------------
	task automatic do_reset();
		rstn = 0;
		s_valid = 0;
		bp_enable = 0;
		ref_time_high = '0;
		ref_time_valid = 1'b0;
		exp_q.delete();
		repeat (5) tick();
		rstn = 1;
		tick();
	endtask

	task automatic wait_drain();
		int guard;
		guard = 0;
		while (exp_q.size() != 0 && guard < 2000) begin
			tick();
			guard++;
		end
		if (exp_q.size() != 0) begin
			$error("wait_drain 逾時,queue 還剩 %0d 筆", exp_q.size());
			error_count++;
		end
	endtask

	task automatic check_tlast_all(input bit expect_high, input int n);
		int start_hi, start_lo, got;
		start_hi = tlast_high_count;
		start_lo = tlast_low_count;
		wait_drain();
		got = expect_high ? (tlast_high_count - start_hi) : (tlast_low_count - start_lo);
		if (got != n) begin
			$error("預期 %0d 筆 tlast=%0d,實際次數=%0d", n, expect_high, got);
			error_count++;
		end
	endtask

	// ---------------- 主測試流程 ----------------
	initial begin
		int before_cnt;
		int i;
		logic [3:0]  r_typ;
		logic [5:0]  r_tlo;
		logic [10:0] r_x, r_y;
		logic [31:0] r_mask;

		// Test 9 用
		logic [10:0] got_ctr;
		logic [10:0] pat_prev_ctr;
		logic pat_have_prev_ctr;
		int pat_tlast_count;
		int pat_beat_count;
		int pat_stability_violations;
		logic pat_prev_valid_stall;
		logic pat_any_stall_seen;
		logic [TDATA_W-1:0] pat_prev_data;
		logic pat_prev_last;

		do_reset();

		// --- Test 1: TIME_HIGH 本身不吐事件,且正確帶出時間 ---
		send_time_high(28'h5);
		repeat (3) tick();
		if (m_valid) begin
			$error("TIME_HIGH 本身不該吐出事件");
			error_count++;
		end
		send_td(4'h0, 6'h1, 11'd10, 11'd20, 32'h1);
		wait_drain();

		// --- Test 2: reset 後第一筆 TD(time_valid=0)被丟棄 ---
		do_reset();
		before_cnt = checked_count;
		send_td(4'h0, 6'h1, 11'd1, 11'd1, 32'h3);
		repeat (20) tick();
		if (checked_count != before_cnt) begin
			$error("reset 後、收到 TIME_HIGH 之前的 TD 不該有任何事件被送出");
			error_count++;
		end
		send_time_high(28'h1);
		send_td(4'h1, 6'h2, 11'd5, 11'd5, 32'h1);
		wait_drain();

		// --- Test 3: 單 bit mask + 隨機 backpressure ---
		bp_enable = 1;
		send_td(4'h0, 6'h3, 11'd100, 11'd50, 32'h00000020);
		wait_drain();

		// --- Test 4: 多 bit mask + 隨機 backpressure ---
		send_td(4'h1, 6'h4, 11'd200, 11'd60, 32'h00001105);
		wait_drain();

		// --- Test 5: 32-bit 全滿 mask ---
		send_td(4'h0, 6'h5, 11'd300, 11'd70, 32'hFFFFFFFF);
		wait_drain();

		// --- Test 6: 背靠背封包不互相污染 ---
		bp_enable = 0;
		send_td(4'h0, 6'h6, 11'd1, 11'd1, 32'h1);
		send_td(4'h1, 6'h7, 11'd2, 11'd2, 32'h2);
		wait_drain();

		// --- Test 7a: tlast timeout=0,每筆都掛 tlast ---
		cfg_tlast_timeout = 16'h0;
		send_td(4'h0, 6'h0, 11'd9, 11'd9, 32'h5); // 2 bits
		check_tlast_all(1'b1, 2);

		// --- Test 7b: tlast timeout=極大值,不會掛 tlast ---
		cfg_tlast_timeout = 16'hFFFF;
		send_td(4'h1, 6'h0, 11'd9, 11'd9, 32'h5); // 2 bits
		check_tlast_all(1'b0, 2);

		// --- Test 7c: cfg_tlast_timeout_enable=0 時,即使 timeout=0 也不該掛 tlast
		// (驗證 enable 位元是獨立開關,不是只看 timeout 數值) ---
		cfg_tlast_timeout_enable = 1'b0;
		cfg_tlast_timeout = 16'h0;
		send_td(4'h0, 6'h1, 11'd9, 11'd9, 32'h5); // 2 bits
		check_tlast_all(1'b0, 2);
		cfg_tlast_timeout_enable = 1'b1;
		cfg_tlast_timeout = 16'hFFFF;

		// --- Test 8: 大量隨機事件,上游送資料前隨機空拍 + 下游隨機 backpressure 同時開著 ---
		// 這是專門回應「master 行為是不是被定死」的測試:位址/type/mask 隨機、
		// 上游準備資料的時間隨機、下游收資料的節奏也隨機,同時交錯著跑,
		// 不是像前面那樣每種情境各自獨立、乾乾淨淨地測一次。
		cfg_tlast_timeout = 16'hFFFF;
		bp_enable = 1;
		send_time_high_gap(28'h100);
		for (i = 0; i < 100; i++) begin
			r_typ  = $urandom_range(0, 1) ? 4'h1 : 4'h0;
			r_tlo  = $urandom_range(0, 63);
			r_x    = $urandom_range(0, 1500);
			r_y    = $urandom_range(0, 1500);
			r_mask = $urandom();
			send_td_gap(r_typ, r_tlo, r_x, r_y, r_mask);
		end
		bp_enable = 0;
		wait_drain();

		// --- Test 9: enable_pattern 模式 ---
		// 1) tlast 應該每 2048 筆「真的被接受」的事件掛一次(pattern_ctr_q 回捲點)
		// 2) AXI4-Stream 穩定性規則:TVALID=1 但 TREADY=0(還沒被接受)的那一拍,
		//    下一拍如果還是沒被接受、或剛好被接受,tdata/tlast 都不能跟上一拍不一樣
		//    ——這條專門盯 evtdec_pattern_no_dma_transfer.md #15 修過的那個 bug
		//    (曾經把 TREADY 錯放進 tlast 的判斷式,導致卡住等待時 tlast 忽高忽低)。
		// 拆兩段:9a 不開 backpressure(TREADY 恆 1),吞吐量固定,可以精確算出總筆數
		// 該看到幾次 tlast;9b 才開隨機 backpressure,專門逼出停頓,測穩定性。
		do_reset();
		cfg_enable_pattern = 1'b1;
		pat_tlast_count = 0;
		pat_beat_count = 0;
		pat_stability_violations = 0;
		pat_prev_valid_stall = 1'b0;
		pat_have_prev_ctr = 1'b0;

		// --- Test 9a: 不開 backpressure,固定跑 4096 拍 = 精確 2 個回捲週期 ---
		bp_enable = 1'b0;
		for (i = 0; i < 4096; i++) begin
			tick();

			if (m_valid && m_ready) begin
				got_ctr = m_data[56:46];

				if ((got_ctr == 11'h7FF) != m_last) begin
					$error("[%0t] tlast 跟 pattern counter 對不上: counter=%0d tlast=%b", $time, got_ctr, m_last);
					error_count++;
				end
				if (m_last) pat_tlast_count++;

				if (pat_have_prev_ctr && got_ctr !== (pat_prev_ctr + 11'd1)) begin
					$error("[%0t] pattern counter 不連續: 上一筆=%0d 這一筆=%0d", $time, pat_prev_ctr, got_ctr);
					error_count++;
				end
				pat_prev_ctr = got_ctr;
				pat_have_prev_ctr = 1'b1;

				pat_beat_count++;
			end
		end

		if (pat_beat_count != 4096) begin
			$error("Test 9a: 沒開 backpressure、TREADY 恆 1,4096 拍應該接受剛好 4096 筆,實際 %0d 筆", pat_beat_count);
			error_count++;
		end
		if (pat_tlast_count != 2) begin
			$error("Test 9a: 4096 筆應該精確對到 2 個 2048 回捲週期、掛 2 次 tlast,實際 %0d 次", pat_tlast_count);
			error_count++;
		end
		$display("Test 9a(無 backpressure): 接受 %0d 筆、tlast 出現 %0d 次", pat_beat_count, pat_tlast_count);

		// --- Test 9b: 開隨機 backpressure,專門測穩定性規則,不追求覆蓋完整週期 ---
		bp_enable = 1'b1;
		pat_prev_valid_stall = 1'b0;
		pat_any_stall_seen = 1'b0;
		for (i = 0; i < 3000; i++) begin
			tick();

			if (pat_prev_valid_stall) begin
				if (m_data !== pat_prev_data || m_last !== pat_prev_last) begin
					$error("[%0t] pattern 模式在 backpressure 期間 tdata/tlast 改變了,違反 AXI4-Stream 穩定性規則(got data=%h last=%b, 上一拍 data=%h last=%b)",
						$time, m_data, m_last, pat_prev_data, pat_prev_last);
					pat_stability_violations++;
				end
			end
			pat_prev_valid_stall = m_valid && !m_ready;
			if (pat_prev_valid_stall) pat_any_stall_seen = 1'b1;
			pat_prev_data = m_data;
			pat_prev_last = m_last;

			if (m_valid && m_ready) begin
				got_ctr = m_data[56:46];
				if ((got_ctr == 11'h7FF) != m_last) begin
					$error("[%0t] tlast 跟 pattern counter 對不上: counter=%0d tlast=%b", $time, got_ctr, m_last);
					error_count++;
				end
				if (got_ctr !== (pat_prev_ctr + 11'd1)) begin
					$error("[%0t] pattern counter 不連續: 上一筆=%0d 這一筆=%0d", $time, pat_prev_ctr, got_ctr);
					error_count++;
				end
				pat_prev_ctr = got_ctr;
			end
		end
		if (!pat_any_stall_seen) begin
			// bp_enable=1 卻整段完全沒出現過一次停頓,代表這段測試沒有真的測到穩定性
			// 規則要驗的情境,值得留意(但不當成失敗,隨機數値本來就有機率性)
			$display("Test 9b 提醒: 3000 拍隨機 backpressure 期間沒有觀察到任何停頓,穩定性檢查這次沒被真的觸發到");
		end

		error_count += pat_stability_violations;
		$display("Test 9b(隨機 backpressure): 穩定性違規 %0d 次", pat_stability_violations);

		// 收尾:先把還卡著的最後一筆放行(TREADY 恆 1),不要在 pattern 模式還有
		// 未完成 transfer 卡在半路時就切斷 cfg_enable_pattern——那本身就是另一種
		// 協定違規,不是這個測試想驗證的東西,會汙染後面的收尾檢查。m_ready 本身是
		// 「下一拍才生效」的暫存輸出,關掉 bp_enable 那一拍不保證馬上變 1,多留幾拍
		// 確保真的穩定下來、卡住的那筆(如果有)確實被接受掉。
		bp_enable = 1'b0;
		repeat (3) tick();
		// tick() 收尾點(edge 之後 #1)跟全域 monitor 對同一個 edge 的檢查是同一個模擬
		// 時間點,兩個 process 誰先跑不保證——這裡多留 #2 錯開,monitor 對這個 edge
		// 的檢查一定已經跑完(還看得到 cfg_enable_pattern=1),才輪到這裡切掉它,
		// 不會有競態讓 monitor 誤判成 pattern 模式已經關閉。
		#2;
		cfg_enable_pattern = 1'b0;

		repeat (10) tick();

		if (exp_q.size() != 0) begin
			$error("測試結束時 queue 還有 %0d 筆沒被收到", exp_q.size());
			error_count++;
		end

		if (error_count == 0)
			$display("=== ALL PASS (%0d events checked) ===", checked_count);
		else
			$display("=== FAIL: %0d errors, %0d events checked ===", error_count, checked_count);

		$finish;
	end

endmodule
