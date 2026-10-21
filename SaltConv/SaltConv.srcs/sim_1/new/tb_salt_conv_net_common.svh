//////////////////////////////////////////////////////////////////////////////////
// tb_salt_conv_net_common.svh
//   tb_salt_conv_net_*.sv 共用的部分,在各自的 module 裡 `include,不單獨編譯。
//   兩層串接 SaltConvNet(conv1 → conv2),輸入照答案檔餵,每支 testbench 只換下游/上游的驅動方式。
//   答案由 scripts/gen_salt_conv_ref.py 產生(訓練端量化模型算的 conv1、conv2,conv2 的輸入就是 conv1 的輸出)。
//   比對:
//     網路輸出(conv2 送出的)(o_c, o_y, o_x, t) 逐筆照順序比;
//     conv1 送給 conv2 的(層與層之間交握成功的那一拍)也逐筆照順序比,出錯時分得出是哪一層;
//     樣本結束時兩層每顆神經元的 (V̂, t_last),直接從各自 NeuronMemory 的記憶體內容讀出來比。
//   每一拍檢查的協定規則(網路輸出、層與層之間兩個介面都查):
//     上一拍 valid=1、ready=0,這一拍 valid 要還是 1,(o_c, o_y, o_x, t) 不變。
//   只查網路輸出的:同一拍裡改 out_ready,out_valid 不能跟著變;reset 之後 out_valid、in_ready 不是 X。
//   清除:conv1 清除期間 in_ready=0;conv2 清除期間 conv1 的輸出不能被收。
//   上游照 valid/ready 的規則:in_valid 拉高後資料不變,直到 in_ready=1 收走;清除期間也會拉高 in_valid。
//   單層已經查過的(讀出值、單層拍數、各種停住位置的涵蓋)這裡不重複。
//   每筆樣本跑一次,開始前用 rst_n 重來(兩層都清除神經元記憶體)。
//   只用一個 initial 流程:negedge 驅動輸入、#1 等組合邏輯穩定後取樣,posedge 後 #1 依取樣結果判斷。
//
//   拍數(只量不比,印在 log,另外寫一份到 xsim 執行目錄的 latency_SAT<0|1>.txt):
//     拍數從 reset 釋放後第一個 posedge 之前那一拍算 0,「第 n 拍」指第 n 個 posedge 之前取樣的那一拍。
//     clear     第一次 in_ready=1 的那一拍(conv1 清完)
//     first_in  第一筆輸入被收下的那一拍
//     last_in   最後一筆輸入被收下的那一拍
//     last_out  網路最後一筆輸出被收下的那一拍(沒有輸出時 -1)
//     done      兩層最後還有東西在處理的那一拍(之後兩層的管線、FIFO 都空)
//     done - last_in 就是「輸入送完之後還要等幾拍」。
//     conv1_blocked:conv1 有東西要送、conv2 不收的拍數;in_blocked:上游要送、conv1 不收的拍數(不含清除期間)。
//
//   include 這個檔案的 module 要在 include 之後(或之前)定義這幾個函式,決定這支 testbench 的驅動方式:
//     function automatic void reset_driver();           每筆樣本開始前,把驅動用的狀態回到初始值
//     function automatic bit  drive_out_ready(int cycle); 這一拍的 out_ready
//     function automatic bit  input_starts_now();        上游這一拍要不要開始送下一筆事件
//   參數用 xelab -generic_top 帶入,答案檔目錄用 xsim -testplusarg REF_DIR=<目錄> 帶入,
//   答案檔是 <REF_DIR>/salt_conv_net_SAT<SATURATE>.txt。
//////////////////////////////////////////////////////////////////////////////////

	// 預設值是訓練端飽和版、R2C2 重疊
	parameter integer IN_CHANNELS              = 2;
	parameter integer IN_ROWS                  = 34;
	parameter integer IN_COLS                  = 34;
	parameter integer CONV1_OUT_CHANNELS       = 8;
	parameter integer CONV1_KERNEL_SIZE        = 3;
	parameter integer CONV1_STRIDE             = 2;
	parameter integer CONV1_PADDING            = 1;
	parameter integer CONV1_MEMBRANE_INT_WIDTH = 9;
	parameter integer CONV1_DECAY_TABLE_DEPTH  = 75;
	parameter integer CONV1_FIFO_DEPTH         = 16;
	parameter CONV1_WEIGHT_FILE    = "../../../../SaltConv.srcs/sources_1/mem/best_val50_b7_fa6_fv0_round_pc_clip100_saturate_iv9-11-11/conv1_weight.mem";
	parameter CONV1_THRESHOLD_FILE = "../../../../SaltConv.srcs/sources_1/mem/best_val50_b7_fa6_fv0_round_pc_clip100_saturate_iv9-11-11/conv1_threshold.mem";
	parameter CONV1_DECAY_FILE     = "../../../../SaltConv.srcs/sources_1/mem/best_val50_b7_fa6_fv0_round_pc_clip100_saturate_iv9-11-11/conv1_decay.mem";
	parameter integer CONV2_OUT_CHANNELS       = 16;
	parameter integer CONV2_KERNEL_SIZE        = 3;
	parameter integer CONV2_STRIDE             = 2;
	parameter integer CONV2_PADDING            = 1;
	parameter integer CONV2_MEMBRANE_INT_WIDTH = 11;
	parameter integer CONV2_DECAY_TABLE_DEPTH  = 75;
	parameter integer CONV2_FIFO_DEPTH         = 16;
	parameter CONV2_WEIGHT_FILE    = "../../../../SaltConv.srcs/sources_1/mem/best_val50_b7_fa6_fv0_round_pc_clip100_saturate_iv9-11-11/conv2_weight.mem";
	parameter CONV2_THRESHOLD_FILE = "../../../../SaltConv.srcs/sources_1/mem/best_val50_b7_fa6_fv0_round_pc_clip100_saturate_iv9-11-11/conv2_threshold.mem";
	parameter CONV2_DECAY_FILE     = "../../../../SaltConv.srcs/sources_1/mem/best_val50_b7_fa6_fv0_round_pc_clip100_saturate_iv9-11-11/conv2_decay.mem";
	parameter integer TIME_WIDTH          = 16;
	parameter integer WEIGHT_WIDTH        = 7;
	parameter integer MEMBRANE_FRAC_WIDTH = 0;
	parameter integer DECAY_FRAC_WIDTH    = 6;
	parameter bit     ROUND               = 1;
	parameter bit     SATURATE            = 1;
	parameter integer READ_LATENCY        = 2;
	parameter integer COMPUTE_LATENCY     = 2;
	parameter bit     OVERLAP             = 1;

	// 跟 SaltConvNet、SaltConv 的 localparam 同一套公式
	localparam integer CONV1_OUT_ROWS = (IN_ROWS + 2 * CONV1_PADDING - CONV1_KERNEL_SIZE) / CONV1_STRIDE + 1;
	localparam integer CONV1_OUT_COLS = (IN_COLS + 2 * CONV1_PADDING - CONV1_KERNEL_SIZE) / CONV1_STRIDE + 1;
	localparam integer CONV2_OUT_ROWS = (CONV1_OUT_ROWS + 2 * CONV2_PADDING - CONV2_KERNEL_SIZE) / CONV2_STRIDE + 1;
	localparam integer CONV2_OUT_COLS = (CONV1_OUT_COLS + 2 * CONV2_PADDING - CONV2_KERNEL_SIZE) / CONV2_STRIDE + 1;
	localparam integer IN_X_WIDTH          = (IN_COLS > 1) ? $clog2(IN_COLS) : 1;
	localparam integer IN_Y_WIDTH          = (IN_ROWS > 1) ? $clog2(IN_ROWS) : 1;
	localparam integer IN_CHANNEL_WIDTH    = (IN_CHANNELS > 1) ? $clog2(IN_CHANNELS) : 1;
	localparam integer CONV1_X_WIDTH       = (CONV1_OUT_COLS > 1) ? $clog2(CONV1_OUT_COLS) : 1;
	localparam integer CONV1_Y_WIDTH       = (CONV1_OUT_ROWS > 1) ? $clog2(CONV1_OUT_ROWS) : 1;
	localparam integer CONV1_CHANNEL_WIDTH = (CONV1_OUT_CHANNELS > 1) ? $clog2(CONV1_OUT_CHANNELS) : 1;
	localparam integer OUT_X_WIDTH         = (CONV2_OUT_COLS > 1) ? $clog2(CONV2_OUT_COLS) : 1;
	localparam integer OUT_Y_WIDTH         = (CONV2_OUT_ROWS > 1) ? $clog2(CONV2_OUT_ROWS) : 1;
	localparam integer OUT_CHANNEL_WIDTH   = (CONV2_OUT_CHANNELS > 1) ? $clog2(CONV2_OUT_CHANNELS) : 1;
	localparam integer CONV1_MEMBRANE_WIDTH = CONV1_MEMBRANE_INT_WIDTH + MEMBRANE_FRAC_WIDTH;
	localparam integer CONV2_MEMBRANE_WIDTH = CONV2_MEMBRANE_INT_WIDTH + MEMBRANE_FRAC_WIDTH;
	localparam integer CONV1_BANK_COUNT = (CONV1_KERNEL_SIZE + CONV1_STRIDE - 1) / CONV1_STRIDE;   // M
	localparam integer CONV2_BANK_COUNT = (CONV2_KERNEL_SIZE + CONV2_STRIDE - 1) / CONV2_STRIDE;
	localparam integer CONV1_BANK_DEPTH = CONV1_OUT_CHANNELS * ((CONV1_OUT_ROWS + CONV1_BANK_COUNT - 1) / CONV1_BANK_COUNT)
	                                    * ((CONV1_OUT_COLS + CONV1_BANK_COUNT - 1) / CONV1_BANK_COUNT);
	localparam integer CONV2_BANK_DEPTH = CONV2_OUT_CHANNELS * ((CONV2_OUT_ROWS + CONV2_BANK_COUNT - 1) / CONV2_BANK_COUNT)
	                                    * ((CONV2_OUT_COLS + CONV2_BANK_COUNT - 1) / CONV2_BANK_COUNT);
	localparam integer CONV1_WORD_WIDTH = CONV1_MEMBRANE_WIDTH + TIME_WIDTH;
	localparam integer CONV2_WORD_WIDTH = CONV2_MEMBRANE_WIDTH + TIME_WIDTH;
	localparam integer PIPELINE_DEPTH   = READ_LATENCY + COMPUTE_LATENCY - 1;   // L

	localparam integer CLOCK_PERIOD = 10;
	localparam integer RESET_CYCLES = 3;
	localparam integer MAX_PRINTED  = 20;   // 錯誤訊息最多印幾筆,之後只計數

	logic clk;
	logic rst_n;
	logic                         in_valid;
	logic                         in_ready;
	logic [IN_X_WIDTH-1:0]        in_x;
	logic [IN_Y_WIDTH-1:0]        in_y;
	logic [IN_CHANNEL_WIDTH-1:0]  in_channel;
	logic [TIME_WIDTH-1:0]        in_time;
	logic                         out_valid;
	logic                         out_ready;
	logic [OUT_X_WIDTH-1:0]       out_x;
	logic [OUT_Y_WIDTH-1:0]       out_y;
	logic [OUT_CHANNEL_WIDTH-1:0] out_channel;
	logic [TIME_WIDTH-1:0]        out_time;

	SaltConvNet #(
		.IN_CHANNELS             (IN_CHANNELS),
		.IN_ROWS                 (IN_ROWS),
		.IN_COLS                 (IN_COLS),
		.CONV1_OUT_CHANNELS      (CONV1_OUT_CHANNELS),
		.CONV1_KERNEL_SIZE       (CONV1_KERNEL_SIZE),
		.CONV1_STRIDE            (CONV1_STRIDE),
		.CONV1_PADDING           (CONV1_PADDING),
		.CONV1_MEMBRANE_INT_WIDTH(CONV1_MEMBRANE_INT_WIDTH),
		.CONV1_DECAY_TABLE_DEPTH (CONV1_DECAY_TABLE_DEPTH),
		.CONV1_FIFO_DEPTH        (CONV1_FIFO_DEPTH),
		.CONV1_WEIGHT_FILE       (CONV1_WEIGHT_FILE),
		.CONV1_THRESHOLD_FILE    (CONV1_THRESHOLD_FILE),
		.CONV1_DECAY_FILE        (CONV1_DECAY_FILE),
		.CONV2_OUT_CHANNELS      (CONV2_OUT_CHANNELS),
		.CONV2_KERNEL_SIZE       (CONV2_KERNEL_SIZE),
		.CONV2_STRIDE            (CONV2_STRIDE),
		.CONV2_PADDING           (CONV2_PADDING),
		.CONV2_MEMBRANE_INT_WIDTH(CONV2_MEMBRANE_INT_WIDTH),
		.CONV2_DECAY_TABLE_DEPTH (CONV2_DECAY_TABLE_DEPTH),
		.CONV2_FIFO_DEPTH        (CONV2_FIFO_DEPTH),
		.CONV2_WEIGHT_FILE       (CONV2_WEIGHT_FILE),
		.CONV2_THRESHOLD_FILE    (CONV2_THRESHOLD_FILE),
		.CONV2_DECAY_FILE        (CONV2_DECAY_FILE),
		.TIME_WIDTH              (TIME_WIDTH),
		.WEIGHT_WIDTH            (WEIGHT_WIDTH),
		.MEMBRANE_FRAC_WIDTH     (MEMBRANE_FRAC_WIDTH),
		.DECAY_FRAC_WIDTH        (DECAY_FRAC_WIDTH),
		.ROUND                   (ROUND),
		.SATURATE                (SATURATE),
		.READ_LATENCY            (READ_LATENCY),
		.COMPUTE_LATENCY         (COMPUTE_LATENCY),
		.OVERLAP                 (OVERLAP)
	) dut (.*);

	initial clk = 1'b0;
	always #(CLOCK_PERIOD / 2) clk = ~clk;

	// ---------------------------------------------------------------
	// 兩層 NeuronMemory 記憶體內容的快照:generate 的 bank 只能用常數 index 取,每個 bank 一個 process 複製
	// ---------------------------------------------------------------
	logic [CONV1_WORD_WIDTH-1:0] conv1_snapshot [0:CONV1_BANK_COUNT-1][0:CONV1_BANK_COUNT-1][0:CONV1_BANK_DEPTH-1];
	logic [CONV2_WORD_WIDTH-1:0] conv2_snapshot [0:CONV2_BANK_COUNT-1][0:CONV2_BANK_COUNT-1][0:CONV2_BANK_DEPTH-1];
	event snapshot_request;

	for (genvar row_bank = 0; row_bank < CONV1_BANK_COUNT; row_bank++) begin : conv1_snapshot_rows
		for (genvar col_bank = 0; col_bank < CONV1_BANK_COUNT; col_bank++) begin : conv1_snapshot_cols
			always @(snapshot_request) begin
				for (int addr = 0; addr < CONV1_BANK_DEPTH; addr++) begin
					conv1_snapshot[row_bank][col_bank][addr] = dut.conv1.row_banks[row_bank].col_banks[col_bank].neuron_memory.memory_array.bank[addr];
				end
			end
		end
	end

	for (genvar row_bank = 0; row_bank < CONV2_BANK_COUNT; row_bank++) begin : conv2_snapshot_rows
		for (genvar col_bank = 0; col_bank < CONV2_BANK_COUNT; col_bank++) begin : conv2_snapshot_cols
			always @(snapshot_request) begin
				for (int addr = 0; addr < CONV2_BANK_DEPTH; addr++) begin
					conv2_snapshot[row_bank][col_bank][addr] = dut.conv2.row_banks[row_bank].col_banks[col_bank].neuron_memory.memory_array.bank[addr];
				end
			end
		end
	end

	// ---------------------------------------------------------------
	// 一筆樣本的答案;輸出事件、神經元狀態兩層各一份,index 0 是 conv1、1 是 conv2
	// ---------------------------------------------------------------
	int in_count;
	int expected_in_x[$], expected_in_y[$], expected_in_c[$], expected_in_t[$];
	int out_count [0:1];
	int expected_out_c[0:1][$], expected_out_y[0:1][$], expected_out_x[0:1][$], expected_out_t[0:1][$];
	int state_count [0:1];
	int state_row_bank[0:1][$], state_col_bank[0:1][$], state_addr[0:1][$], state_membrane[0:1][$], state_last_time[0:1][$];

	// 統計
	int error_count       = 0;
	int run_count         = 0;
	int out_check_count   [0:1] = '{0, 0};
	int state_check_count [0:1] = '{0, 0};
	int latency_fd;

	function automatic string parameter_text();
		return $sformatf({"IN_CHANNELS=%0d IN_ROWS=%0d IN_COLS=%0d ",
		                  "CONV1_OUT_CHANNELS=%0d CONV1_KERNEL_SIZE=%0d CONV1_STRIDE=%0d CONV1_PADDING=%0d ",
		                  "CONV1_MEMBRANE_INT_WIDTH=%0d CONV1_DECAY_TABLE_DEPTH=%0d CONV1_FIFO_DEPTH=%0d ",
		                  "CONV2_OUT_CHANNELS=%0d CONV2_KERNEL_SIZE=%0d CONV2_STRIDE=%0d CONV2_PADDING=%0d ",
		                  "CONV2_MEMBRANE_INT_WIDTH=%0d CONV2_DECAY_TABLE_DEPTH=%0d CONV2_FIFO_DEPTH=%0d ",
		                  "TIME_WIDTH=%0d WEIGHT_WIDTH=%0d MEMBRANE_FRAC_WIDTH=%0d DECAY_FRAC_WIDTH=%0d ",
		                  "ROUND=%0d SATURATE=%0d READ_LATENCY=%0d COMPUTE_LATENCY=%0d OVERLAP=%0d"},
		                 IN_CHANNELS, IN_ROWS, IN_COLS,
		                 CONV1_OUT_CHANNELS, CONV1_KERNEL_SIZE, CONV1_STRIDE, CONV1_PADDING,
		                 CONV1_MEMBRANE_INT_WIDTH, CONV1_DECAY_TABLE_DEPTH, CONV1_FIFO_DEPTH,
		                 CONV2_OUT_CHANNELS, CONV2_KERNEL_SIZE, CONV2_STRIDE, CONV2_PADDING,
		                 CONV2_MEMBRANE_INT_WIDTH, CONV2_DECAY_TABLE_DEPTH, CONV2_FIFO_DEPTH,
		                 TIME_WIDTH, WEIGHT_WIDTH, MEMBRANE_FRAC_WIDTH, DECAY_FRAC_WIDTH,
		                 ROUND, SATURATE, READ_LATENCY, COMPUTE_LATENCY, OVERLAP);
	endfunction

	function automatic void report_error(string message);
		if (error_count < MAX_PRINTED) begin
			$display("MISMATCH t=%0t %s", $time, message);
		end
		error_count++;
	endfunction

	// 讀 count 行 kind 種類的輸出事件,放進第 layer 層的答案
	function automatic void read_outputs(int fd, int sample_index, int layer, string expected_kind);
		string kind;
		int a, b, c, d;
		expected_out_c[layer].delete(); expected_out_y[layer].delete();
		expected_out_x[layer].delete(); expected_out_t[layer].delete();
		for (int i = 0; i < out_count[layer]; i++) begin
			if ($fscanf(fd, "%s %d %d %d %d", kind, a, b, c, d) != 5 || kind != expected_kind)
				$fatal(1, "樣本 %0d 第 %0d 個 %s 行格式不對", sample_index, i, expected_kind);
			expected_out_c[layer].push_back(a); expected_out_y[layer].push_back(b);
			expected_out_x[layer].push_back(c); expected_out_t[layer].push_back(d);
		end
	endfunction

	// 讀 count 行 kind 種類的神經元狀態,放進第 layer 層的答案
	function automatic void read_states(int fd, int sample_index, int layer, string expected_kind);
		string kind;
		int a, b, c, d, e;
		state_row_bank[layer].delete(); state_col_bank[layer].delete(); state_addr[layer].delete();
		state_membrane[layer].delete(); state_last_time[layer].delete();
		for (int i = 0; i < state_count[layer]; i++) begin
			if ($fscanf(fd, "%s %d %d %d %d %d", kind, a, b, c, d, e) != 6 || kind != expected_kind)
				$fatal(1, "樣本 %0d 第 %0d 個 %s 行格式不對", sample_index, i, expected_kind);
			state_row_bank[layer].push_back(a); state_col_bank[layer].push_back(b); state_addr[layer].push_back(c);
			state_membrane[layer].push_back(d); state_last_time[layer].push_back(e);
		end
	endfunction

	// 讀一筆樣本;讀到 end 回傳 0
	function automatic bit read_sample(int fd, int sample_index);
		string kind;
		int a, b, c, d;
		if ($fscanf(fd, "%s", kind) != 1) $fatal(1, "答案檔第 %0d 筆樣本之前讀不到資料", sample_index);
		if (kind == "end") begin
			if ($fscanf(fd, "%d", a) != 1 || a != sample_index)
				$fatal(1, "答案檔 end 行的樣本數 %0d,實際讀到 %0d 筆", a, sample_index);
			return 1'b0;
		end
		if (kind != "sample") $fatal(1, "答案檔第 %0d 筆樣本開頭不是 sample,是 %s", sample_index, kind);
		if ($fscanf(fd, "%d %d %d %d %d", in_count, out_count[0], out_count[1], state_count[0], state_count[1]) != 5)
			$fatal(1, "sample 行格式不對");

		expected_in_x.delete(); expected_in_y.delete(); expected_in_c.delete(); expected_in_t.delete();
		for (int i = 0; i < in_count; i++) begin
			if ($fscanf(fd, "%s %d %d %d %d", kind, a, b, c, d) != 5 || kind != "in")
				$fatal(1, "樣本 %0d 第 %0d 個 in 行格式不對", sample_index, i);
			expected_in_x.push_back(a); expected_in_y.push_back(b); expected_in_c.push_back(c); expected_in_t.push_back(d);
		end
		read_outputs(fd, sample_index, 0, "conv1_out");
		read_outputs(fd, sample_index, 1, "conv2_out");
		read_states(fd, sample_index, 0, "conv1_state");
		read_states(fd, sample_index, 1, "conv2_state");
		return 1'b1;
	endfunction

	// 兩層都空下來:管線裡沒有 o_c,FIFO 也沒有事件,也不在清除
	function automatic bit net_idle();
		for (int position = 1; position <= PIPELINE_DEPTH; position++) begin
			if (dut.conv1.pipe_valid[position] || dut.conv2.pipe_valid[position]) return 1'b0;
		end
		return !dut.conv1.fifo_read_valid && !dut.conv2.fifo_read_valid && !dut.conv1.clearing && !dut.conv2.clearing;
	endfunction

	// 一個 valid/ready 介面這一拍的檢查:上一拍沒送出去,這一拍 valid 要還是 1、內容不變;
	// 交握成功就跟第 layer 層的答案比下一筆。previous_* 是上一拍的取樣,呼叫完更新成這一拍
	task automatic check_interface(string where, string name, int layer, int unsigned channel, int unsigned y,
	                               int unsigned x, int unsigned time_value, logic valid, logic ready,
	                               ref bit previous_stalled, ref int unsigned previous [0:3], ref int out_index);
		if (previous_stalled) begin
			if (!valid) begin
				report_error($sformatf("%s %s:上一拍送不出去,這一拍 valid=0", where, name));
			end else if (channel != previous[0] || y != previous[1] || x != previous[2] || time_value != previous[3]) begin
				report_error($sformatf("%s %s:上一拍送不出去,這一拍資料變了:(%0d,%0d,%0d,%0d) -> (%0d,%0d,%0d,%0d)",
				                       where, name, previous[0], previous[1], previous[2], previous[3],
				                       channel, y, x, time_value));
			end
		end
		if (valid && ready) begin
			if (out_index >= out_count[layer]) begin
				report_error($sformatf("%s %s 多送了一筆 (%0d,%0d,%0d,%0d)", where, name, channel, y, x, time_value));
			end else if (channel != expected_out_c[layer][out_index] || y != expected_out_y[layer][out_index]
			             || x != expected_out_x[layer][out_index] || time_value != expected_out_t[layer][out_index]) begin
				report_error($sformatf("%s %s 第 %0d 筆:expected=(%0d,%0d,%0d,%0d) actual=(%0d,%0d,%0d,%0d)",
				                       where, name, out_index, expected_out_c[layer][out_index],
				                       expected_out_y[layer][out_index], expected_out_x[layer][out_index],
				                       expected_out_t[layer][out_index], channel, y, x, time_value));
			end
			out_check_count[layer]++;
			out_index++;
		end
		previous_stalled = valid && !ready;
		previous = '{channel, y, x, time_value};
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
		int  in_index   = 0;
		bit  presenting = 1'b0;
		int  cycle      = 0;
		int  max_cycles;
		int  out_index        [0:1] = '{0, 0};
		bit  previous_stalled [0:1] = '{1'b0, 1'b0};
		int unsigned previous [0:1][0:3];
		// 拍數,定義見檔頭
		int  clear_cycle    = -1;
		int  first_in_cycle = -1;
		int  last_in_cycle  = -1;
		int  last_out_cycle = -1;
		int  done_cycle     = -1;
		int  conv1_blocked  = 0;
		int  in_blocked     = 0;
		logic sampled_out_valid, flipped_out_valid;
		bit   sampled_in_handshake;
		string where;

		// 一筆事件最多 OC 個 o_c、每個 o_c 最多 M×M 拍;下游擋住的拍數另外加一倍
		max_cycles = 2 * (in_count * CONV1_OUT_CHANNELS * CONV1_BANK_COUNT * CONV1_BANK_COUNT
		                  + out_count[0] * CONV2_OUT_CHANNELS * CONV2_BANK_COUNT * CONV2_BANK_COUNT)
		           + CONV1_BANK_DEPTH + 10000;
		reset_driver();
		apply_reset();

		forever begin
			where = $sformatf("sample=%0d cycle=%0d", sample_index, cycle);

			// ---------------- negedge:驅動輸入 ----------------
			out_ready = drive_out_ready(cycle);
			if (!presenting && in_index < in_count && input_starts_now()) begin
				presenting = 1'b1;
				in_x       = IN_X_WIDTH'(expected_in_x[in_index]);
				in_y       = IN_Y_WIDTH'(expected_in_y[in_index]);
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

			// ---------------- posedge 之前:取樣、檢查 ----------------
			if ($isunknown(out_valid) || $isunknown(in_ready)) begin
				report_error($sformatf("%s out_valid=%b in_ready=%b 是 X", where, out_valid, in_ready));
			end
			if (dut.conv1.clearing && in_ready) report_error($sformatf("%s conv1 清除期間 in_ready=1", where));
			if (dut.conv2.clearing && dut.conv1_out_ready) report_error($sformatf("%s conv2 清除期間 conv1 的輸出被收", where));

			check_interface(where, "conv1 輸出", 0, dut.conv1_out_channel, dut.conv1_out_y, dut.conv1_out_x,
			                dut.conv1_out_time, dut.conv1_out_valid, dut.conv1_out_ready,
			                previous_stalled[0], previous[0], out_index[0]);
			if (out_valid && out_ready) last_out_cycle = cycle;
			check_interface(where, "網路輸出", 1, out_channel, out_y, out_x, out_time, out_valid, out_ready,
			                previous_stalled[1], previous[1], out_index[1]);

			if (in_ready && clear_cycle < 0) clear_cycle = cycle;
			if (dut.conv1_out_valid && !dut.conv1_out_ready) conv1_blocked++;
			if (in_valid && !in_ready && !dut.conv1.clearing) in_blocked++;
			sampled_in_handshake = in_valid && in_ready;
			if (sampled_in_handshake) begin
				if (first_in_cycle < 0) first_in_cycle = cycle;
				last_in_cycle = cycle;
			end

			// ---------------- posedge ----------------
			@(posedge clk);
			#1;
			cycle++;
			if (sampled_in_handshake) begin
				presenting = 1'b0;
				in_index++;
			end

			if (in_index == in_count && !presenting && net_idle()) begin
				done_cycle = cycle - 1;
				break;
			end
			if (cycle > max_cycles) begin
				report_error($sformatf("%s 跑了 %0d 拍還沒結束:in %0d/%0d conv1 out %0d/%0d out %0d/%0d", where, cycle,
				                       in_index, in_count, out_index[0], out_count[0], out_index[1], out_count[1]));
				break;
			end
			@(negedge clk);
		end

		for (int layer = 0; layer < 2; layer++) begin
			if (out_index[layer] != out_count[layer]) begin
				report_error($sformatf("sample=%0d %s 輸出 %0d 筆,答案 %0d 筆", sample_index,
				                       (layer == 0) ? "conv1" : "conv2", out_index[layer], out_count[layer]));
			end
		end

		$display("latency sample=%0d in=%0d conv1_out=%0d out=%0d clear=%0d first_in=%0d last_in=%0d last_out=%0d done=%0d after_input=%0d conv1_blocked=%0d in_blocked=%0d",
		         sample_index, in_count, out_count[0], out_count[1], clear_cycle, first_in_cycle, last_in_cycle,
		         last_out_cycle, done_cycle, done_cycle - last_in_cycle, conv1_blocked, in_blocked);
		$fdisplay(latency_fd, "%0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",
		          sample_index, in_count, out_count[0], out_count[1], clear_cycle, first_in_cycle, last_in_cycle,
		          last_out_cycle, done_cycle, conv1_blocked, in_blocked);

		// 兩層的神經元狀態
		-> snapshot_request;
		#1;
		for (int i = 0; i < state_count[0]; i++) begin
			logic [CONV1_WORD_WIDTH-1:0] word;
			word = conv1_snapshot[state_row_bank[0][i]][state_col_bank[0][i]][state_addr[0][i]];
			if (word[CONV1_MEMBRANE_WIDTH-1:0] != CONV1_MEMBRANE_WIDTH'(state_membrane[0][i])
			    || word[CONV1_WORD_WIDTH-1:CONV1_MEMBRANE_WIDTH] != TIME_WIDTH'(state_last_time[0][i])) begin
				report_error($sformatf("sample=%0d conv1 bank=(%0d,%0d) addr=%0d:expected=(%0d,%0d) actual=(%0d,%0d)",
				                       sample_index, state_row_bank[0][i], state_col_bank[0][i], state_addr[0][i],
				                       state_membrane[0][i], state_last_time[0][i],
				                       $signed(word[CONV1_MEMBRANE_WIDTH-1:0]), word[CONV1_WORD_WIDTH-1:CONV1_MEMBRANE_WIDTH]));
			end
			state_check_count[0]++;
		end
		for (int i = 0; i < state_count[1]; i++) begin
			logic [CONV2_WORD_WIDTH-1:0] word;
			word = conv2_snapshot[state_row_bank[1][i]][state_col_bank[1][i]][state_addr[1][i]];
			if (word[CONV2_MEMBRANE_WIDTH-1:0] != CONV2_MEMBRANE_WIDTH'(state_membrane[1][i])
			    || word[CONV2_WORD_WIDTH-1:CONV2_MEMBRANE_WIDTH] != TIME_WIDTH'(state_last_time[1][i])) begin
				report_error($sformatf("sample=%0d conv2 bank=(%0d,%0d) addr=%0d:expected=(%0d,%0d) actual=(%0d,%0d)",
				                       sample_index, state_row_bank[1][i], state_col_bank[1][i], state_addr[1][i],
				                       state_membrane[1][i], state_last_time[1][i],
				                       $signed(word[CONV2_MEMBRANE_WIDTH-1:0]), word[CONV2_WORD_WIDTH-1:CONV2_MEMBRANE_WIDTH]));
			end
			state_check_count[1]++;
		end
		run_count++;
	endtask

	initial begin
		string ref_dir;
		string ref_path;
		string latency_path;
		int    ref_fd;
		int    sample_index;
		string verdict;

		// 亂數不另外設種子:xsim 不支援 $urandom(seed),用預設的 -sv_seed,每次跑都是同一串
		rst_n     = 1'b0;
		in_valid  = 1'b0;
		out_ready = 1'b0;
		in_x = '0; in_y = '0; in_channel = '0; in_time = '0;

		if (!$value$plusargs("REF_DIR=%s", ref_dir))
			$fatal(1, "缺少 -testplusarg REF_DIR=<答案檔目錄>");
		ref_path = $sformatf("%s/salt_conv_net_SAT%0d.txt", ref_dir, SATURATE);
		ref_fd = $fopen(ref_path, "r");
		if (ref_fd == 0) $fatal(1, "打不開答案檔 %s", ref_path);
		// 拍數一筆樣本一行,欄位順序同 latency 那行(少了 after_input)
		latency_path = $sformatf("latency_SAT%0d.txt", SATURATE);
		latency_fd = $fopen(latency_path, "w");
		if (latency_fd == 0) $fatal(1, "打不開 %s", latency_path);
		$fdisplay(latency_fd, "sample in conv1_out out clear first_in last_in last_out done conv1_blocked in_blocked");

		sample_index = 0;
		while (read_sample(ref_fd, sample_index)) begin
			run_sample(sample_index);
			sample_index++;
		end
		$fclose(ref_fd);
		$fclose(latency_fd);

		if (error_count == 0 && run_count > 0) verdict = "ALL PASS";
		else verdict = "FAIL";
		$display("%s: sample_count=%0d run_count=%0d conv1_out_check_count=%0d out_check_count=%0d conv1_state_check_count=%0d conv2_state_check_count=%0d error_count=%0d %s",
		         parameter_text(), sample_index, run_count, out_check_count[0], out_check_count[1],
		         state_check_count[0], state_check_count[1], error_count, verdict);
		$finish;
	end
