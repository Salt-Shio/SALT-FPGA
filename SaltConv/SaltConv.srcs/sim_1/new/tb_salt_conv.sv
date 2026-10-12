`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: tb_salt_conv
// Description:
//   整層 SaltConv 比對,答案由 scripts/gen_salt_conv_ref.py 用訓練端的整層 forward、逐筆迴圈產生。
//   每筆樣本依序用四種模式各跑一次,中間用 rst_n 重來(清除神經元記憶體):
//     A:out_ready 一直是 1,輸入一直有。另外比拍數:第一個 PROCESS 到最後一個 SENDING 的拍數要等於答案。
//     B:out_ready 每拍隨機,輸入隨機斷。
//     C:out_ready 隨機長度的連續 0、連續 1 交替(長的超過 FIFO 深度);輸入隨機斷,
//        偶爾等 SaltConv 整個空下來(IDLE、FIFO 空)再送,中途回 IDLE。
//     D:out_ready 每拍 0、1 交替,輸入一直有。
//   四種模式都比:輸出事件 (o_c, o_y, o_x, t) 逐筆照順序比;樣本結束時每顆神經元的 (V̂, t_last)
//   直接從 NeuronMemory 的記憶體內容讀出來比。
//   上游照 valid/ready 的規則:in_valid 拉高後資料不變,直到 in_ready=1 收走;清除期間也會拉高 in_valid。
//   每一拍檢查的協定規則:
//     上一拍 out_valid=1、out_ready=0,這一拍 out_valid 要還是 1,(o_c, o_y, o_x, t) 不變。
//     同一拍裡改 out_ready,out_valid 不能跟著變(out_valid 不能用到 out_ready)。
//     清除期間 in_ready=0,FIFO 也沒有收進任何事件。
//     reset 之後 out_valid、in_ready 不是 X。
//   涵蓋率:下面幾種情況各數幾次,要求的項目是 0 次就 FAIL。前四項要不要求由答案檔的 coverage 行決定
//   (這組參數的 fire 分布碰不碰得到),其餘一律要求:
//     stall_with_more_left            下游不收,這個 o_c 還剩 2 個以上
//     stall_last_of_oc                下游不收,是這個 o_c 的最後一個,後面還有 o_c
//     stall_last_of_event_next_queued 下游不收,是這筆事件的最後一個,FIFO 有下一筆
//     stall_last_of_event             下游不收,是這筆事件的最後一個,FIFO 是空的
//     ready_low_without_valid         下游不收,可是 out_valid=0
//     upstream_blocked                上游 in_valid=1 被擋(FIFO 滿)
//     resume_from_idle                樣本中途回 IDLE 之後,事件進來
//     valid_during_clearing           清除期間上游送事件
//   參數用 xelab -generic_top 帶入,答案檔目錄用 xsim -testplusarg REF_DIR=<目錄> 帶入,
//   檔名照參數組出來,規則跟 gen_salt_conv_ref.py 的 ParamSet.stem 相同。
//   只用一個 initial 流程:negedge 驅動輸入、#1 等組合邏輯穩定後取樣,posedge 後 #1 依取樣結果判斷。
//////////////////////////////////////////////////////////////////////////////////

module tb_salt_conv;

	// 預設值是訓練端 conv1 飽和版
	parameter integer X_WIDTH             = 6;
	parameter integer Y_WIDTH             = 6;
	parameter integer IN_CHANNEL_WIDTH    = 1;
	parameter integer IN_CHANNELS         = 2;
	parameter integer OUT_CHANNELS        = 8;
	parameter integer OUT_ROWS            = 17;
	parameter integer OUT_COLS            = 17;
	parameter integer KERNEL_SIZE         = 3;
	parameter integer STRIDE              = 2;
	parameter integer PADDING             = 1;
	parameter integer TIME_WIDTH          = 16;
	parameter integer WEIGHT_WIDTH        = 7;
	parameter integer MEMBRANE_INT_WIDTH  = 9;
	parameter integer MEMBRANE_FRAC_WIDTH = 0;
	parameter integer DECAY_FRAC_WIDTH    = 6;
	parameter integer DECAY_TABLE_DEPTH   = 75;
	parameter bit     ROUND               = 1;
	parameter bit     SATURATE            = 1;
	parameter integer FIFO_DEPTH          = 16;
	parameter WEIGHT_FILE    = "../../../../SaltConv.srcs/sources_1/mem/best_val50_b7_fa6_fv0_round_pc_clip100_saturate_iv9-11-11/conv1_weight.mem";
	parameter THRESHOLD_FILE = "../../../../SaltConv.srcs/sources_1/mem/best_val50_b7_fa6_fv0_round_pc_clip100_saturate_iv9-11-11/conv1_threshold.mem";
	parameter DECAY_FILE     = "../../../../SaltConv.srcs/sources_1/mem/best_val50_b7_fa6_fv0_round_pc_clip100_saturate_iv9-11-11/conv1_decay.mem";

	// 跟 SaltConv、NeuronMemory 的 localparam 同一套公式
	localparam integer MEMBRANE_WIDTH    = MEMBRANE_INT_WIDTH + MEMBRANE_FRAC_WIDTH;
	localparam integer OUT_CHANNEL_WIDTH = (OUT_CHANNELS > 1) ? $clog2(OUT_CHANNELS) : 1;
	localparam integer OUT_Y_WIDTH       = (OUT_ROWS > 1) ? $clog2(OUT_ROWS) : 1;
	localparam integer OUT_X_WIDTH       = (OUT_COLS > 1) ? $clog2(OUT_COLS) : 1;
	localparam integer AXIS_BANK_COUNT   = (KERNEL_SIZE + STRIDE - 1) / STRIDE;
	localparam integer ROW_SLOTS         = (OUT_ROWS + AXIS_BANK_COUNT - 1) / AXIS_BANK_COUNT;
	localparam integer COL_SLOTS         = (OUT_COLS + AXIS_BANK_COUNT - 1) / AXIS_BANK_COUNT;
	localparam integer BANK_DEPTH        = OUT_CHANNELS * ROW_SLOTS * COL_SLOTS;
	localparam integer WORD_WIDTH        = MEMBRANE_WIDTH + TIME_WIDTH;

	localparam integer CLOCK_PERIOD     = 10;
	localparam integer RESET_CYCLES     = 3;
	localparam integer MODE_COUNT       = 4;
	localparam integer MAX_PRINTED      = 20;    // 錯誤訊息最多印幾筆,之後只計數
	localparam integer BURST_MAX        = 80;    // 模式 C 連續 0 或連續 1 的最長拍數

	// 模式
	localparam integer MODE_A = 0;
	localparam integer MODE_B = 1;
	localparam integer MODE_C = 2;
	localparam integer MODE_D = 3;

	// 涵蓋項目
	localparam integer COVER_STALL_WITH_MORE_LEFT            = 0;
	localparam integer COVER_STALL_LAST_OF_OC                = 1;
	localparam integer COVER_STALL_LAST_OF_EVENT_NEXT_QUEUED = 2;
	localparam integer COVER_STALL_LAST_OF_EVENT             = 3;
	localparam integer COVER_READY_LOW_WITHOUT_VALID         = 4;
	localparam integer COVER_UPSTREAM_BLOCKED                = 5;
	localparam integer COVER_RESUME_FROM_IDLE                = 6;
	localparam integer COVER_VALID_DURING_CLEARING           = 7;
	localparam integer COVER_COUNT                           = 8;
	localparam string  COVER_NAMES [0:COVER_COUNT-1] = '{
		"stall_with_more_left", "stall_last_of_oc", "stall_last_of_event_next_queued", "stall_last_of_event",
		"ready_low_without_valid", "upstream_blocked", "resume_from_idle", "valid_during_clearing"};

	logic clk;
	logic rst_n;
	logic                         in_valid;
	logic                         in_ready;
	logic [X_WIDTH-1:0]           in_x;
	logic [Y_WIDTH-1:0]           in_y;
	logic [IN_CHANNEL_WIDTH-1:0]  in_channel;
	logic [TIME_WIDTH-1:0]        in_time;
	logic                         out_valid;
	logic                         out_ready;
	logic [OUT_X_WIDTH-1:0]       out_x;
	logic [OUT_Y_WIDTH-1:0]       out_y;
	logic [OUT_CHANNEL_WIDTH-1:0] out_channel;
	logic [TIME_WIDTH-1:0]        out_time;

	SaltConv #(
		.X_WIDTH            (X_WIDTH),
		.Y_WIDTH            (Y_WIDTH),
		.IN_CHANNEL_WIDTH   (IN_CHANNEL_WIDTH),
		.IN_CHANNELS        (IN_CHANNELS),
		.OUT_CHANNELS       (OUT_CHANNELS),
		.OUT_ROWS           (OUT_ROWS),
		.OUT_COLS           (OUT_COLS),
		.KERNEL_SIZE        (KERNEL_SIZE),
		.STRIDE             (STRIDE),
		.PADDING            (PADDING),
		.TIME_WIDTH         (TIME_WIDTH),
		.WEIGHT_WIDTH       (WEIGHT_WIDTH),
		.MEMBRANE_INT_WIDTH (MEMBRANE_INT_WIDTH),
		.MEMBRANE_FRAC_WIDTH(MEMBRANE_FRAC_WIDTH),
		.DECAY_FRAC_WIDTH   (DECAY_FRAC_WIDTH),
		.DECAY_TABLE_DEPTH  (DECAY_TABLE_DEPTH),
		.ROUND              (ROUND),
		.SATURATE           (SATURATE),
		.WEIGHT_FILE        (WEIGHT_FILE),
		.THRESHOLD_FILE     (THRESHOLD_FILE),
		.DECAY_FILE         (DECAY_FILE),
		.FIFO_DEPTH         (FIFO_DEPTH)
	) dut (.*);

	initial clk = 1'b0;
	always #(CLOCK_PERIOD / 2) clk = ~clk;

	// ---------------------------------------------------------------
	// NeuronMemory 記憶體內容的快照:generate 的 bank 只能用常數 index 取,每個 bank 一個 process 複製
	// ---------------------------------------------------------------
	logic [WORD_WIDTH-1:0] bank_snapshot [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1][0:BANK_DEPTH-1];
	event snapshot_request;

	for (genvar row_bank = 0; row_bank < AXIS_BANK_COUNT; row_bank++) begin : snapshot_rows
		for (genvar col_bank = 0; col_bank < AXIS_BANK_COUNT; col_bank++) begin : snapshot_cols
			always @(snapshot_request) begin
				for (int addr = 0; addr < BANK_DEPTH; addr++) begin
					bank_snapshot[row_bank][col_bank][addr] = dut.neuron_memory.row_banks[row_bank].col_banks[col_bank].bank[addr];
				end
			end
		end
	end

	// ---------------------------------------------------------------
	// 一筆樣本的答案
	// ---------------------------------------------------------------
	int in_count, out_count, expected_cycle_count, state_count;
	int expected_in_x[$], expected_in_y[$], expected_in_c[$], expected_in_t[$];
	int expected_out_c[$], expected_out_y[$], expected_out_x[$], expected_out_t[$];
	int state_row_bank[$], state_col_bank[$], state_addr[$], state_membrane[$], state_last_time[$];

	// 統計
	int error_count     = 0;
	int run_count       = 0;
	int out_check_count = 0;
	int state_check_count = 0;
	int cycle_check_count = 0;
	int cover_count    [0:COVER_COUNT-1];
	bit cover_required [0:COVER_COUNT-1];

	function automatic string parameter_text();
		return $sformatf({"X_WIDTH=%0d Y_WIDTH=%0d IN_CHANNEL_WIDTH=%0d IN_CHANNELS=%0d OUT_CHANNELS=%0d ",
		                  "OUT_ROWS=%0d OUT_COLS=%0d KERNEL_SIZE=%0d STRIDE=%0d PADDING=%0d TIME_WIDTH=%0d ",
		                  "WEIGHT_WIDTH=%0d MEMBRANE_INT_WIDTH=%0d MEMBRANE_FRAC_WIDTH=%0d DECAY_FRAC_WIDTH=%0d ",
		                  "DECAY_TABLE_DEPTH=%0d ROUND=%0d SATURATE=%0d FIFO_DEPTH=%0d"},
		                 X_WIDTH, Y_WIDTH, IN_CHANNEL_WIDTH, IN_CHANNELS, OUT_CHANNELS, OUT_ROWS, OUT_COLS,
		                 KERNEL_SIZE, STRIDE, PADDING, TIME_WIDTH, WEIGHT_WIDTH, MEMBRANE_INT_WIDTH,
		                 MEMBRANE_FRAC_WIDTH, DECAY_FRAC_WIDTH, DECAY_TABLE_DEPTH, ROUND, SATURATE, FIFO_DEPTH);
	endfunction

	function automatic void report_error(string message);
		if (error_count < MAX_PRINTED) begin
			$display("MISMATCH t=%0t %s", $time, message);
		end
		error_count++;
	endfunction

	// 讀一筆樣本;讀到 end 回傳 0
	function automatic bit read_sample(int fd, int sample_index);
		string kind;
		int scan_count;
		int a, b, c, d, e;
		scan_count = $fscanf(fd, "%s", kind);
		if (scan_count != 1) begin
			$fatal(1, "答案檔第 %0d 筆樣本之前讀不到資料", sample_index);
		end
		if (kind == "end") begin
			scan_count = $fscanf(fd, "%d", a);
			if (scan_count != 1 || a != sample_index) begin
				$fatal(1, "答案檔 end 行的樣本數 %0d,實際讀到 %0d 筆", a, sample_index);
			end
			return 1'b0;
		end
		if (kind != "sample") begin
			$fatal(1, "答案檔第 %0d 筆樣本開頭不是 sample,是 %s", sample_index, kind);
		end
		scan_count = $fscanf(fd, "%d %d %d %d", in_count, out_count, expected_cycle_count, state_count);
		if (scan_count != 4) $fatal(1, "sample 行格式不對");

		expected_in_x.delete(); expected_in_y.delete(); expected_in_c.delete(); expected_in_t.delete();
		for (int i = 0; i < in_count; i++) begin
			scan_count = $fscanf(fd, "%s %d %d %d %d", kind, a, b, c, d);
			if (scan_count != 5 || kind != "in") $fatal(1, "樣本 %0d 第 %0d 個 in 行格式不對", sample_index, i);
			expected_in_x.push_back(a); expected_in_y.push_back(b); expected_in_c.push_back(c); expected_in_t.push_back(d);
		end
		expected_out_c.delete(); expected_out_y.delete(); expected_out_x.delete(); expected_out_t.delete();
		for (int i = 0; i < out_count; i++) begin
			scan_count = $fscanf(fd, "%s %d %d %d %d", kind, a, b, c, d);
			if (scan_count != 5 || kind != "out") $fatal(1, "樣本 %0d 第 %0d 個 out 行格式不對", sample_index, i);
			expected_out_c.push_back(a); expected_out_y.push_back(b); expected_out_x.push_back(c); expected_out_t.push_back(d);
		end
		state_row_bank.delete(); state_col_bank.delete(); state_addr.delete(); state_membrane.delete(); state_last_time.delete();
		for (int i = 0; i < state_count; i++) begin
			scan_count = $fscanf(fd, "%s %d %d %d %d %d", kind, a, b, c, d, e);
			if (scan_count != 6 || kind != "state") $fatal(1, "樣本 %0d 第 %0d 個 state 行格式不對", sample_index, i);
			state_row_bank.push_back(a); state_col_bank.push_back(b); state_addr.push_back(c);
			state_membrane.push_back(d); state_last_time.push_back(e);
		end
		return 1'b1;
	endfunction

	// SaltConv 整個空下來:IDLE,FIFO 也沒有事件
	function automatic bit dut_idle();
		return (dut.state == dut.IDLE) && !dut.fifo_read_valid && !dut.clearing;
	endfunction

	function automatic int pending_fire_count();
		int count = 0;
		for (int row_bank = 0; row_bank < AXIS_BANK_COUNT; row_bank++) begin
			for (int col_bank = 0; col_bank < AXIS_BANK_COUNT; col_bank++) begin
				count += dut.bitmask[row_bank][col_bank];
			end
		end
		return count;
	endfunction

	task automatic apply_reset();
		@(negedge clk);
		rst_n     = 1'b0;
		in_valid  = 1'b0;
		out_ready = 1'b0;
		repeat (RESET_CYCLES) @(negedge clk);
		rst_n = 1'b1;
	endtask

	// 一筆樣本、一種模式
	task automatic run_sample(int sample_index, int mode);
		int  in_index      = 0;
		int  out_index     = 0;
		bit  presenting    = 1'b0;
		bit  wait_for_idle = 1'b0;   // 模式 C:等 SaltConv 整個空下來才送下一筆
		int  gap_left      = 0;      // 等到空下來之後再空幾拍
		int  burst_left    = 0;      // 模式 C:out_ready 這一段還剩幾拍
		bit  burst_level   = 1'b1;
		int  events_taken  = 0;      // 這筆樣本已經從 FIFO 拿出幾筆事件
		int  cycle         = 0;
		int  first_process_cycle = -1;
		int  last_sending_cycle  = -1;
		int  max_cycles;
		bit  previous_stalled = 1'b0;
		logic [OUT_CHANNEL_WIDTH-1:0] previous_channel;
		logic [OUT_Y_WIDTH-1:0]       previous_y;
		logic [OUT_X_WIDTH-1:0]       previous_x;
		logic [TIME_WIDTH-1:0]        previous_time;
		logic sampled_out_valid, flipped_out_valid;
		bit   sampled_in_handshake, sampled_out_handshake;
		string where;

		max_cycles = 20 * (expected_cycle_count + in_count) + BANK_DEPTH + 10000;
		apply_reset();

		forever begin
			where = $sformatf("sample=%0d mode=%0d cycle=%0d", sample_index, mode, cycle);

			// ---------------- negedge:驅動輸入 ----------------
			case (mode)
				MODE_A: out_ready = 1'b1;
				MODE_B: out_ready = $urandom_range(0, 1);
				MODE_C: begin
					if (burst_left == 0) begin
						burst_level = ~burst_level;
						burst_left  = $urandom_range(1, BURST_MAX);
					end
					out_ready = burst_level;
					burst_left--;
				end
				default: out_ready = cycle[0];
			endcase

			if (!presenting && in_index < in_count) begin
				bit start_now;
				case (mode)
					MODE_B: start_now = ($urandom_range(0, 9) < 7);
					MODE_C: begin
						if (wait_for_idle) begin
							if (dut_idle()) begin
								wait_for_idle = 1'b0;
								gap_left = $urandom_range(0, 3);
							end
							start_now = 1'b0;
						end else if (gap_left > 0) begin
							gap_left--;
							start_now = 1'b0;
						end else begin
							start_now = ($urandom_range(0, 9) < 7);
						end
					end
					default: start_now = 1'b1;
				endcase
				if (start_now) begin
					presenting = 1'b1;
					in_x       = X_WIDTH'(expected_in_x[in_index]);
					in_y       = Y_WIDTH'(expected_in_y[in_index]);
					in_channel = IN_CHANNEL_WIDTH'(expected_in_c[in_index]);
					in_time    = TIME_WIDTH'(expected_in_t[in_index]);
				end
			end
			in_valid = presenting;

			// 等組合邏輯穩定,再檢查 out_valid 不能跟著 out_ready 變
			#1;
			sampled_out_valid = out_valid;
			out_ready = ~out_ready;
			#1;
			flipped_out_valid = out_valid;
			out_ready = ~out_ready;
			#1;
			if (flipped_out_valid !== sampled_out_valid) begin
				report_error($sformatf("%s out_valid 跟著 out_ready 變:%b -> %b", where, sampled_out_valid, flipped_out_valid));
			end

			// ---------------- posedge 之前:取樣、檢查協定、數涵蓋 ----------------
			if ($isunknown(out_valid) || $isunknown(in_ready)) begin
				report_error($sformatf("%s out_valid=%b in_ready=%b 是 X", where, out_valid, in_ready));
			end
			if (dut.clearing) begin
				if (in_ready) report_error($sformatf("%s 清除期間 in_ready=1", where));
				if (dut.fifo_read_valid) report_error($sformatf("%s 清除期間 FIFO 有事件", where));
				if (in_valid) cover_count[COVER_VALID_DURING_CLEARING]++;
			end
			if (previous_stalled) begin
				if (!out_valid) begin
					report_error($sformatf("%s 上一拍送不出去,這一拍 out_valid=0", where));
				end else if (out_channel != previous_channel || out_y != previous_y || out_x != previous_x
				             || out_time != previous_time) begin
					report_error($sformatf("%s 上一拍送不出去,這一拍資料變了:(%0d,%0d,%0d,%0d) -> (%0d,%0d,%0d,%0d)",
					                       where, previous_channel, previous_y, previous_x, previous_time,
					                       out_channel, out_y, out_x, out_time));
				end
			end

			if (out_valid && !out_ready) begin
				int left = pending_fire_count();
				if (left >= 2) cover_count[COVER_STALL_WITH_MORE_LEFT]++;
				else if (!dut.last_channel) cover_count[COVER_STALL_LAST_OF_OC]++;
				else if (dut.fifo_read_valid) cover_count[COVER_STALL_LAST_OF_EVENT_NEXT_QUEUED]++;
				else cover_count[COVER_STALL_LAST_OF_EVENT]++;
			end
			if (!out_valid && !out_ready && !dut.clearing) cover_count[COVER_READY_LOW_WITHOUT_VALID]++;
			if (in_valid && !in_ready && !dut.clearing) cover_count[COVER_UPSTREAM_BLOCKED]++;
			if (dut.state == dut.IDLE && dut.begin_next_oc && events_taken > 0) cover_count[COVER_RESUME_FROM_IDLE]++;

			if (dut.state == dut.PROCESS && first_process_cycle < 0) first_process_cycle = cycle;
			if (dut.state == dut.SENDING) last_sending_cycle = cycle;
			if (dut.take_new_event) events_taken++;

			sampled_in_handshake  = in_valid && in_ready;
			sampled_out_handshake = out_valid && out_ready;
			previous_stalled = out_valid && !out_ready;
			previous_channel = out_channel;
			previous_y       = out_y;
			previous_x       = out_x;
			previous_time    = out_time;

			if (sampled_out_handshake) begin
				if (out_index >= out_count) begin
					report_error($sformatf("%s 多送了一筆 (%0d,%0d,%0d,%0d)", where, out_channel, out_y, out_x, out_time));
				end else if (out_channel != expected_out_c[out_index] || out_y != expected_out_y[out_index]
				             || out_x != expected_out_x[out_index] || out_time != expected_out_t[out_index]) begin
					report_error($sformatf("%s 第 %0d 筆輸出:expected=(%0d,%0d,%0d,%0d) actual=(%0d,%0d,%0d,%0d)",
					                       where, out_index, expected_out_c[out_index], expected_out_y[out_index],
					                       expected_out_x[out_index], expected_out_t[out_index],
					                       out_channel, out_y, out_x, out_time));
				end
				out_check_count++;
				out_index++;
			end

			// ---------------- posedge ----------------
			@(posedge clk);
			#1;
			cycle++;
			if (sampled_in_handshake) begin
				presenting = 1'b0;
				in_index++;
				if (mode == MODE_C && $urandom_range(0, 9) < 2) wait_for_idle = 1'b1;
			end

			if (in_index == in_count && !presenting && dut_idle()) break;
			if (cycle > max_cycles) begin
				report_error($sformatf("%s 跑了 %0d 拍還沒結束:in %0d/%0d out %0d/%0d", where, cycle, in_index,
				                       in_count, out_index, out_count));
				break;
			end
			@(negedge clk);
		end

		if (out_index != out_count) begin
			report_error($sformatf("sample=%0d mode=%0d 輸出 %0d 筆,答案 %0d 筆", sample_index, mode, out_index, out_count));
		end
		if (mode == MODE_A) begin
			int measured = (first_process_cycle < 0) ? 0 : last_sending_cycle - first_process_cycle + 1;
			if (measured != expected_cycle_count) begin
				report_error($sformatf("sample=%0d mode=A 拍數:expected=%0d actual=%0d", sample_index,
				                       expected_cycle_count, measured));
			end
			cycle_check_count++;
		end

		// 神經元狀態
		-> snapshot_request;
		#1;
		for (int i = 0; i < state_count; i++) begin
			logic [WORD_WIDTH-1:0]            word;
			logic signed [MEMBRANE_WIDTH-1:0] membrane;
			logic [TIME_WIDTH-1:0]            last_time;
			word      = bank_snapshot[state_row_bank[i]][state_col_bank[i]][state_addr[i]];
			membrane  = word[MEMBRANE_WIDTH-1:0];
			last_time = word[WORD_WIDTH-1:MEMBRANE_WIDTH];
			if (membrane != MEMBRANE_WIDTH'(state_membrane[i]) || last_time != TIME_WIDTH'(state_last_time[i])) begin
				report_error($sformatf("sample=%0d mode=%0d bank=(%0d,%0d) addr=%0d:expected=(%0d,%0d) actual=(%0d,%0d)",
				                       sample_index, mode, state_row_bank[i], state_col_bank[i], state_addr[i],
				                       state_membrane[i], state_last_time[i], membrane, last_time));
			end
			state_check_count++;
		end
		run_count++;
	endtask

	initial begin
		string ref_dir;
		string ref_path;
		int    ref_fd;
		int    scan_count;
		int    sample_index;
		string kind;
		int    required [0:3];
		bit    coverage_ok;
		string coverage_text;
		string verdict;

		// 亂數不另外設種子:xsim 不支援 $urandom(seed),用預設的 -sv_seed,每次跑都是同一串
		for (int i = 0; i < COVER_COUNT; i++) begin
			cover_count[i]    = 0;
			cover_required[i] = 1'b1;
		end
		rst_n     = 1'b0;
		in_valid  = 1'b0;
		out_ready = 1'b0;
		in_x = '0; in_y = '0; in_channel = '0; in_time = '0;

		if (!$value$plusargs("REF_DIR=%s", ref_dir))
			$fatal(1, "缺少 -testplusarg REF_DIR=<答案檔目錄>");
		ref_path = $sformatf("%s/salt_conv_K%0d_S%0d_P%0d_R%0d_C%0d_IC%0d_OC%0d_IV%0d_FV%0d_RD%0d_SAT%0d.txt",
		                     ref_dir, KERNEL_SIZE, STRIDE, PADDING, OUT_ROWS, OUT_COLS, IN_CHANNELS, OUT_CHANNELS,
		                     MEMBRANE_INT_WIDTH, MEMBRANE_FRAC_WIDTH, ROUND, SATURATE);
		ref_fd = $fopen(ref_path, "r");
		if (ref_fd == 0) $fatal(1, "打不開答案檔 %s", ref_path);

		scan_count = $fscanf(ref_fd, "%s %d %d %d %d", kind, required[0], required[1], required[2], required[3]);
		if (scan_count != 5 || kind != "coverage") $fatal(1, "答案檔第一行不是 coverage");
		for (int i = 0; i < 4; i++) cover_required[i] = (required[i] != 0);

		sample_index = 0;
		while (read_sample(ref_fd, sample_index)) begin
			for (int mode = 0; mode < MODE_COUNT; mode++) begin
				run_sample(sample_index, mode);
			end
			sample_index++;
		end
		$fclose(ref_fd);

		// 字串不用 ?: 選:兩邊都是字串常數時結果是補到等寬的位元向量,印出來會多空白
		coverage_ok = 1'b1;
		for (int i = 0; i < COVER_COUNT; i++) begin
			if (cover_required[i]) begin
				$display("coverage %s=%0d", COVER_NAMES[i], cover_count[i]);
			end else begin
				$display("coverage %s=%0d (not required)", COVER_NAMES[i], cover_count[i]);
			end
			if (cover_required[i] && cover_count[i] == 0) begin
				$display("COVERAGE MISSING %s", COVER_NAMES[i]);
				coverage_ok = 1'b0;
			end
		end

		if (coverage_ok) coverage_text = "ok";
		else coverage_text = "missing";
		if (error_count == 0 && coverage_ok && run_count > 0) verdict = "ALL PASS";
		else verdict = "FAIL";
		$display("%s: sample_count=%0d run_count=%0d out_check_count=%0d state_check_count=%0d cycle_check_count=%0d error_count=%0d coverage=%s %s",
		         parameter_text(), sample_index, run_count, out_check_count, state_check_count, cycle_check_count,
		         error_count, coverage_text, verdict);
		$finish;
	end

endmodule
