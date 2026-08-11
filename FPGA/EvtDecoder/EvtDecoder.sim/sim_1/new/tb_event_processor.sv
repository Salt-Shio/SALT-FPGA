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
		if (rstn && m_valid && m_ready) begin
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
