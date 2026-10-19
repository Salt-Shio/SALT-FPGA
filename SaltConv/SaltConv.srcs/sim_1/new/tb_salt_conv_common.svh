//////////////////////////////////////////////////////////////////////////////////
// tb_salt_conv_common.svh
//   tb_salt_conv_*.sv 四支共用的部分,在各自的 module 裡 `include,不單獨編譯。
//   每支 testbench 只測一種下游/上游的驅動方式,共用的檢查都在這裡:
//     輸出事件 (o_c, o_y, o_x, t) 逐筆照順序比;樣本結束時每顆神經元的 (V̂, t_last)
//     直接從 NeuronMemory 的記憶體內容讀出來比。答案由 scripts/gen_salt_conv_ref.py 產生。
//     每一拍檢查的協定規則:
//       上一拍 out_valid=1、out_ready=0,這一拍 out_valid 要還是 1,(o_c, o_y, o_x, t) 不變。
//       同一拍裡改 out_ready,out_valid 不能跟著變(out_valid 不能用到 out_ready)。
//       清除期間 in_ready=0,FIFO 也沒有收進任何事件。
//       reset 之後 out_valid、in_ready 不是 X。
//       讀出的資料出來那一拍(位置 R 剛到,dut.data_cycle),讀出值要等於記憶體裡的內容:每個合法候選的 (V̂, t_last)
//       等於 NeuronMemory 陣列裡候選位址那一格(這一拍寫入之前),權重寬字等於權重 ROM 裡 (o_c, c) 那一格;
//       (o_c, c) 由 testbench 在送讀位址那一拍記下來,照順序對。
//       只比最後結果時,讀錯資料但結果剛好對(例如讀到 X、飽和判斷剛好算出會 fire 的值)會漏掉,這一項在讀錯的那一拍就抓到。
//     上游照 valid/ready 的規則:in_valid 拉高後資料不變,直到 in_ready=1 收走;清除期間也會拉高 in_valid。
//   每筆樣本跑一次,開始前用 rst_n 重來(清除神經元記憶體)。
//   只用一個 initial 流程:negedge 驅動輸入、#1 等組合邏輯穩定後取樣,posedge 後 #1 依取樣結果判斷。
//
//   include 這個檔案的 module 要在 include 之前定義:
//     localparam bit CHECK_CYCLE_COUNT   out_ready 一直是 1、輸入一直有時才設 1:比拍數
//   include 之後(或之前)定義這幾個函式,決定這支 testbench 的驅動方式:
//     function automatic void reset_driver();           每筆樣本開始前,把驅動用的狀態回到初始值
//     function automatic bit  drive_out_ready(int cycle); 這一拍的 out_ready
//     function automatic bit  input_starts_now();        上游這一拍要不要開始送下一筆事件
//     function automatic void input_taken();             上游的一筆事件剛被收走
//     function automatic bit  coverage_wanted(int item); 這支 testbench 要求哪些涵蓋項目
//   涵蓋項目(要求的項目 0 次就 FAIL;前五項還要看答案檔的 coverage 行,這組參數的 fire 分布碰不碰得到):
//     stall_on_compute_cycle           下游不收,這一拍是算的那一拍(挑的是剛算出的 s)
//     stall_with_more_left            下游不收,這個 o_c 還剩 2 個以上
//     stall_last_of_oc                下游不收,是這個 o_c 的最後一個,後面還有 o_c
//     stall_last_of_event_next_queued 下游不收,是這筆事件的最後一個,FIFO 有下一筆
//     stall_last_of_event             下游不收,是這筆事件的最後一個,FIFO 是空的
//     ready_low_without_valid         下游不收,可是 out_valid=0
//     upstream_blocked                上游 in_valid=1 被擋(FIFO 滿)
//     resume_from_idle                樣本中途整層空下來之後,事件進來
//     valid_during_clearing           清除期間上游送事件
//   參數用 xelab -generic_top 帶入,答案檔目錄用 xsim -testplusarg REF_DIR=<目錄> 帶入,
//   檔名照參數組出來,規則跟 gen_salt_conv_ref.py 的 ParamSet.stem 相同。
//   READ_LATENCY(R)、COMPUTE_LATENCY(C)、OVERLAP 不影響答案,只影響拍數:答案檔的 sample 行列出每組
//   (R, C, OVERLAP) 的拍數(順序見 gen_salt_conv_ref.py 的 CYCLE_CONFIGS),照自己的參數挑一個比。
//////////////////////////////////////////////////////////////////////////////////

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
	parameter integer READ_LATENCY        = 1;
	parameter integer COMPUTE_LATENCY     = 1;
	parameter bit     OVERLAP             = 0;
	parameter WEIGHT_FILE   = "../../../../SaltConv.srcs/sources_1/mem/best_val50_b7_fa6_fv0_round_pc_clip100_saturate_iv9-11-11/conv1_weight.mem";
	parameter THRESHOLD_FILE = "../../../../SaltConv.srcs/sources_1/mem/best_val50_b7_fa6_fv0_round_pc_clip100_saturate_iv9-11-11/conv1_threshold.mem";
	parameter DECAY_FILE     = "../../../../SaltConv.srcs/sources_1/mem/best_val50_b7_fa6_fv0_round_pc_clip100_saturate_iv9-11-11/conv1_decay.mem";

	// 跟 SaltConv 的 localparam 同一套公式
	localparam integer MEMBRANE_WIDTH    = MEMBRANE_INT_WIDTH + MEMBRANE_FRAC_WIDTH;
	localparam integer OUT_CHANNEL_WIDTH = (OUT_CHANNELS > 1) ? $clog2(OUT_CHANNELS) : 1;
	localparam integer OUT_Y_WIDTH       = (OUT_ROWS > 1) ? $clog2(OUT_ROWS) : 1;
	localparam integer OUT_X_WIDTH       = (OUT_COLS > 1) ? $clog2(OUT_COLS) : 1;
	localparam integer AXIS_BANK_COUNT   = (KERNEL_SIZE + STRIDE - 1) / STRIDE;
	localparam integer ROW_SLOTS         = (OUT_ROWS + AXIS_BANK_COUNT - 1) / AXIS_BANK_COUNT;
	localparam integer COL_SLOTS         = (OUT_COLS + AXIS_BANK_COUNT - 1) / AXIS_BANK_COUNT;
	localparam integer BANK_DEPTH        = OUT_CHANNELS * ROW_SLOTS * COL_SLOTS;
	localparam integer WORD_WIDTH        = MEMBRANE_WIDTH + TIME_WIDTH;
	localparam integer KERNEL_WORD_WIDTH = KERNEL_SIZE * KERNEL_SIZE * WEIGHT_WIDTH;
	localparam integer PIPELINE_DEPTH    = READ_LATENCY + COMPUTE_LATENCY - 1;

	localparam integer CLOCK_PERIOD = 10;
	localparam integer RESET_CYCLES = 3;
	localparam integer MAX_PRINTED  = 20;   // 錯誤訊息最多印幾筆,之後只計數
	// 答案檔 sample 行的拍數:R、C 各 1~2、OVERLAP 0~1,共 8 個,順序 ((R-1)*2 + (C-1))*2 + OVERLAP,
	// 跟 gen_salt_conv_ref.py 的 CYCLE_CONFIGS 相同
	localparam integer CYCLE_CONFIG_COUNT = 8;

	// 涵蓋項目;前 FIRE_COVER_COUNT 項由答案檔的 coverage 行決定碰不碰得到
	localparam integer COVER_STALL_ON_COMPUTE_CYCLE          = 0;
	localparam integer COVER_STALL_WITH_MORE_LEFT            = 1;
	localparam integer COVER_STALL_LAST_OF_OC                = 2;
	localparam integer COVER_STALL_LAST_OF_EVENT_NEXT_QUEUED = 3;
	localparam integer COVER_STALL_LAST_OF_EVENT             = 4;
	localparam integer COVER_READY_LOW_WITHOUT_VALID         = 5;
	localparam integer COVER_UPSTREAM_BLOCKED                = 6;
	localparam integer COVER_RESUME_FROM_IDLE                = 7;
	localparam integer COVER_VALID_DURING_CLEARING           = 8;
	localparam integer COVER_COUNT                           = 9;
	localparam integer FIRE_COVER_COUNT                      = 5;
	localparam string  COVER_NAMES [0:COVER_COUNT-1] = '{
		"stall_on_compute_cycle", "stall_with_more_left", "stall_last_of_oc", "stall_last_of_event_next_queued",
		"stall_last_of_event", "ready_low_without_valid", "upstream_blocked", "resume_from_idle",
		"valid_during_clearing"};

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
		.FIFO_DEPTH         (FIFO_DEPTH),
		.READ_LATENCY       (READ_LATENCY),
		.COMPUTE_LATENCY    (COMPUTE_LATENCY),
		.OVERLAP            (OVERLAP)
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
					bank_snapshot[row_bank][col_bank][addr] = dut.row_banks[row_bank].col_banks[col_bank].neuron_memory.memory_array.bank[addr];
				end
			end
		end
	end

	// ---------------------------------------------------------------
	// 讀出值檢查:同樣因為 bank 只能用常數 index 取,每個 bank 一個 process 複製兩個值,
	// 主流程觸發 read_check_request 後比對
	// ---------------------------------------------------------------
	logic [WORD_WIDTH-1:0] read_used  [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1];   // NeuronUpdate 用到的 {t_last, V̂}
	logic [WORD_WIDTH-1:0] read_truth [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1];   // 陣列裡候選位址那一格
	event read_check_request;

	for (genvar row_bank = 0; row_bank < AXIS_BANK_COUNT; row_bank++) begin : read_check_rows
		for (genvar col_bank = 0; col_bank < AXIS_BANK_COUNT; col_bank++) begin : read_check_cols
			always @(read_check_request) begin
				read_used[row_bank][col_bank]  = {dut.row_banks[row_bank].col_banks[col_bank].last_time,
				                                  dut.row_banks[row_bank].col_banks[col_bank].membrane};
				read_truth[row_bank][col_bank] = dut.row_banks[row_bank].col_banks[col_bank].neuron_memory.memory_array
				                                     .bank[dut.pipe_bank_addr[READ_LATENCY][row_bank][col_bank]];
			end
		end
	end

	// ---------------------------------------------------------------
	// 一筆樣本的答案
	// ---------------------------------------------------------------
	int in_count, out_count, expected_cycle_count, state_count;
	int expected_in_x[$], expected_in_y[$], expected_in_c[$], expected_in_t[$];
	int expected_out_c[$], expected_out_y[$], expected_out_x[$], expected_out_t[$];
	int sent_out_channel[$], sent_in_channel[$];   // 送過讀位址、資料還沒出來的 (o_c, c),照送的順序
	int state_row_bank[$], state_col_bank[$], state_addr[$], state_membrane[$], state_last_time[$];

	// 統計
	int error_count       = 0;
	int run_count         = 0;
	int out_check_count   = 0;
	int state_check_count = 0;
	int cycle_check_count = 0;
	int read_check_count  = 0;   // 檢查過讀出值的拍數(位置 R 剛到)
	int cover_count    [0:COVER_COUNT-1];
	bit cover_required [0:COVER_COUNT-1];

	function automatic string parameter_text();
		return $sformatf({"X_WIDTH=%0d Y_WIDTH=%0d IN_CHANNEL_WIDTH=%0d IN_CHANNELS=%0d OUT_CHANNELS=%0d ",
		                  "OUT_ROWS=%0d OUT_COLS=%0d KERNEL_SIZE=%0d STRIDE=%0d PADDING=%0d TIME_WIDTH=%0d ",
		                  "WEIGHT_WIDTH=%0d MEMBRANE_INT_WIDTH=%0d MEMBRANE_FRAC_WIDTH=%0d DECAY_FRAC_WIDTH=%0d ",
		                  "DECAY_TABLE_DEPTH=%0d ROUND=%0d SATURATE=%0d FIFO_DEPTH=%0d READ_LATENCY=%0d ",
		                  "COMPUTE_LATENCY=%0d OVERLAP=%0d"},
		                 X_WIDTH, Y_WIDTH, IN_CHANNEL_WIDTH, IN_CHANNELS, OUT_CHANNELS, OUT_ROWS, OUT_COLS,
		                 KERNEL_SIZE, STRIDE, PADDING, TIME_WIDTH, WEIGHT_WIDTH, MEMBRANE_INT_WIDTH,
		                 MEMBRANE_FRAC_WIDTH, DECAY_FRAC_WIDTH, DECAY_TABLE_DEPTH, ROUND, SATURATE, FIFO_DEPTH,
		                 READ_LATENCY, COMPUTE_LATENCY, OVERLAP);
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
		scan_count = $fscanf(fd, "%d %d %d", in_count, out_count, state_count);
		if (scan_count != 3) $fatal(1, "sample 行格式不對");
		// 拍數:每組 (R, C, OVERLAP) 一個,挑自己那一組
		if (READ_LATENCY < 1 || READ_LATENCY > 2 || COMPUTE_LATENCY < 1 || COMPUTE_LATENCY > 2) begin
			$fatal(1, "READ_LATENCY=%0d COMPUTE_LATENCY=%0d,答案檔只有 R、C 各 1~2 的拍數", READ_LATENCY, COMPUTE_LATENCY);
		end
		for (int config_index = 0; config_index < CYCLE_CONFIG_COUNT; config_index++) begin
			scan_count = $fscanf(fd, "%d", a);
			if (scan_count != 1) $fatal(1, "sample 行少了第 %0d 組的拍數", config_index);
			if (config_index == ((READ_LATENCY - 1) * 2 + (COMPUTE_LATENCY - 1)) * 2 + OVERLAP) expected_cycle_count = a;
		end

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

	// 管線位置 first..last 有沒有 o_c
	function automatic bit pipe_occupied(int first, int last);
		for (int position = first; position <= last; position++) begin
			if (dut.pipe_valid[position]) return 1'b1;
		end
		return 1'b0;
	endfunction

	// SaltConv 整個空下來:管線裡沒有 o_c,FIFO 也沒有事件
	function automatic bit dut_idle();
		return !pipe_occupied(1, PIPELINE_DEPTH) && !dut.fifo_read_valid && !dut.clearing;
	endfunction

	// 這一拍還沒送出的 fire 數(算的那一拍是剛算出的 s && valid,之後是 bitmask)
	function automatic int pending_fire_count();
		int count = 0;
		for (int row_bank = 0; row_bank < AXIS_BANK_COUNT; row_bank++) begin
			for (int col_bank = 0; col_bank < AXIS_BANK_COUNT; col_bank++) begin
				count += dut.pending[row_bank][col_bank];
			end
		end
		return count;
	endfunction

	// 位置 R 剛到:讀出值要等於記憶體裡的內容;posedge 之前呼叫,記憶體還沒被這一拍寫入
	task automatic check_read_data(string where);
		logic [KERNEL_WORD_WIDTH-1:0] weight_truth;
		int out_channel_sent, in_channel_sent;
		if (sent_out_channel.size() == 0) begin
			report_error($sformatf("%s 資料出來了,可是沒有送過讀位址", where));
			return;
		end
		out_channel_sent = sent_out_channel.pop_front();
		in_channel_sent  = sent_in_channel.pop_front();
		if (out_channel_sent != dut.pipe_channel[READ_LATENCY]) begin
			report_error($sformatf("%s 位置 R 的 o_c=%0d,送讀位址的順序是 o_c=%0d", where,
			                       dut.pipe_channel[READ_LATENCY], out_channel_sent));
		end
		-> read_check_request;
		#1;
		weight_truth = dut.weight_memory.rom[out_channel_sent * IN_CHANNELS + in_channel_sent];
		if (dut.kernel_word !== weight_truth) begin
			report_error($sformatf("%s 權重讀錯:o_c=%0d c=%0d used=%h truth=%h", where,
			                       out_channel_sent, in_channel_sent, dut.kernel_word, weight_truth));
		end
		for (int row_bank = 0; row_bank < AXIS_BANK_COUNT; row_bank++) begin
			for (int col_bank = 0; col_bank < AXIS_BANK_COUNT; col_bank++) begin
				if (dut.pipe_candidate_valid[READ_LATENCY][row_bank][col_bank]
				    && read_used[row_bank][col_bank] !== read_truth[row_bank][col_bank]) begin
					report_error($sformatf("%s 神經元讀錯:bank=(%0d,%0d) addr=%0d used=%h truth=%h", where,
					                       row_bank, col_bank, dut.pipe_bank_addr[READ_LATENCY][row_bank][col_bank],
					                       read_used[row_bank][col_bank], read_truth[row_bank][col_bank]));
				end
			end
		end
		read_check_count++;
	endtask

	task automatic apply_reset();
		@(negedge clk);
		rst_n     = 1'b0;
		in_valid  = 1'b0;
		out_ready = 1'b0;
		repeat (RESET_CYCLES) @(negedge clk);
		rst_n = 1'b1;
	endtask

	// 一筆樣本
	task automatic run_sample(int sample_index);
		int  in_index      = 0;
		int  out_index     = 0;
		bit  presenting    = 1'b0;
		int  events_taken  = 0;    // 這筆樣本已經從 FIFO 拿出幾筆事件
		int  cycle         = 0;
		int  first_compute_cycle = -1;
		int  last_done_cycle     = -1;
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
		sent_out_channel.delete();
		sent_in_channel.delete();
		reset_driver();
		apply_reset();

		forever begin
			where = $sformatf("sample=%0d cycle=%0d", sample_index, cycle);

			// ---------------- negedge:驅動輸入 ----------------
			out_ready = drive_out_ready(cycle);
			if (!presenting && in_index < in_count && input_starts_now()) begin
				presenting = 1'b1;
				in_x       = X_WIDTH'(expected_in_x[in_index]);
				in_y       = Y_WIDTH'(expected_in_y[in_index]);
				in_channel = IN_CHANNEL_WIDTH'(expected_in_c[in_index]);
				in_time    = TIME_WIDTH'(expected_in_t[in_index]);
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
				if (dut.compute_cycle) cover_count[COVER_STALL_ON_COMPUTE_CYCLE]++;
				if (left >= 2) cover_count[COVER_STALL_WITH_MORE_LEFT]++;
				else if (out_channel != OUT_CHANNEL_WIDTH'(OUT_CHANNELS - 1)) cover_count[COVER_STALL_LAST_OF_OC]++;
				// 下一筆事件在 FIFO,或已經在管線位置 1..L-1
				else if (dut.fifo_read_valid || pipe_occupied(1, PIPELINE_DEPTH - 1)) cover_count[COVER_STALL_LAST_OF_EVENT_NEXT_QUEUED]++;
				else cover_count[COVER_STALL_LAST_OF_EVENT]++;
			end
			if (!out_valid && !out_ready && !dut.clearing) cover_count[COVER_READY_LOW_WITHOUT_VALID]++;
			if (in_valid && !in_ready && !dut.clearing) cover_count[COVER_UPSTREAM_BLOCKED]++;
			if (!pipe_occupied(1, PIPELINE_DEPTH) && dut.begin_next_oc && events_taken > 0) cover_count[COVER_RESUME_FROM_IDLE]++;

			if (dut.compute_cycle && first_compute_cycle < 0) first_compute_cycle = cycle;
			if (dut.oc_done) last_done_cycle = cycle;
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

			// 放在取樣的最後:裡面多等的 #1 不影響上面的取樣時間點
			if (dut.begin_next_oc) begin
				sent_out_channel.push_back(dut.read_out_channel);
				sent_in_channel.push_back(dut.read_channel);
			end
			if (dut.data_cycle) check_read_data(where);

			// ---------------- posedge ----------------
			@(posedge clk);
			#1;
			cycle++;
			if (sampled_in_handshake) begin
				presenting = 1'b0;
				in_index++;
				input_taken();
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
			report_error($sformatf("sample=%0d 輸出 %0d 筆,答案 %0d 筆", sample_index, out_index, out_count));
		end
		// 拍數:第一個 o_c 算的那一拍到最後一個 o_c 送完那一拍;中途空下來多一拍也會被抓到
		if (CHECK_CYCLE_COUNT) begin
			int measured = (first_compute_cycle < 0) ? 0 : last_done_cycle - first_compute_cycle + 1;
			if (measured != expected_cycle_count) begin
				report_error($sformatf("sample=%0d 拍數:expected=%0d actual=%0d", sample_index,
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
				report_error($sformatf("sample=%0d bank=(%0d,%0d) addr=%0d:expected=(%0d,%0d) actual=(%0d,%0d)",
				                       sample_index, state_row_bank[i], state_col_bank[i], state_addr[i],
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
		int    fire_reachable [0:FIRE_COVER_COUNT-1];
		bit    coverage_ok;
		string coverage_text;
		string verdict;

		// 亂數不另外設種子:xsim 不支援 $urandom(seed),用預設的 -sv_seed,每次跑都是同一串
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

		scan_count = $fscanf(ref_fd, "%s %d %d %d %d %d", kind, fire_reachable[0], fire_reachable[1],
		                     fire_reachable[2], fire_reachable[3], fire_reachable[4]);
		if (scan_count != 6 || kind != "coverage") $fatal(1, "答案檔第一行不是 coverage");
		for (int i = 0; i < COVER_COUNT; i++) begin
			cover_count[i]    = 0;
			cover_required[i] = coverage_wanted(i) && (i >= FIRE_COVER_COUNT || fire_reachable[i] != 0);
		end

		sample_index = 0;
		while (read_sample(ref_fd, sample_index)) begin
			run_sample(sample_index);
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
		$display("%s: sample_count=%0d run_count=%0d out_check_count=%0d state_check_count=%0d cycle_check_count=%0d read_check_count=%0d error_count=%0d coverage=%s %s",
		         parameter_text(), sample_index, run_count, out_check_count, state_check_count, cycle_check_count,
		         read_check_count, error_count, coverage_text, verdict);
		$finish;
	end
