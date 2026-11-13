//////////////////////////////////////////////////////////////////////////////////
// tb_salt_conv_fc_net_common.svh
//   tb_salt_conv_fc_net_*.sv 共用的部分,在各自的 module 裡 `include,不單獨編譯。
//   整個網路 SaltConvFCNet(conv1 → conv2 → ConvToFCAdapter → SaltFC → FCMembraneRegister),輸入照答案檔餵,
//   每支 testbench 只換上游的驅動方式(網路最後是膜電位輸出,沒有 ready)。
//   答案由 scripts/net/gen_salt_conv_fc_net_ref.py 產生(訓練端量化模型整條算的,檔頭有格式;答案檔不進 git)。
//   目標:每一層每一次更新的 (t, V̂)、每一個 spike 都跟訓練端對上。每一拍(posedge 之前)比:
//     三個介面交握成功那一拍的事件,逐筆照順序:
//       conv1 → conv2 的 (o_c, o_y, o_x, t);conv2 → 轉接模組的 (o_c, o_y, o_x, t);轉接模組 → SaltFC 的 (src, t)。
//     conv1、conv2 每一次更新:寫回神經元記憶體那一拍(NeuronMemory 的寫 port)的位址、V̂、t,
//       每個 bank 一串答案照順序比;寫入開關停住的拍子不開,所以每筆事件碰到的每顆神經元剛好寫一次,多寫、少寫都會錯開。
//     FC 每一次更新:update_done 那一拍的 membranes(10 顆的 V̂)、update_time。
//   每一拍檢查的協定規則(三個介面都查):上一拍 valid=1、ready=0,這一拍 valid 要還是 1,資料不變。
//   reset 之後 in_ready 不是 X;清除:conv1 清除期間 in_ready=0,conv2 清除期間 conv1 的輸出不能被收,
//   SaltFC 清除期間轉接模組的輸出不能被收。
//   樣本結束(全部輸入送完、整條空下來,再多跑 END_CYCLES 拍,看有沒有多寫、多送):
//     三個介面的筆數、每個 bank 的更新筆數、FC 的更新筆數都要等於答案;
//     兩層 conv 每顆神經元的 (V̂, t_last),直接從各自 NeuronMemory 的記憶體內容讀出來比。
//   每筆樣本跑一次,開始前用 rst_n 重來(每層都清除神經元記憶體)。
//   只用一個 initial 流程:negedge 驅動輸入、#1 等組合邏輯穩定後取樣,posedge 後 #1 依取樣結果判斷。
//   讀 DUT 內部訊號的 assign(寫 port、記憶體快照)只把 generate 裡的訊號搬出來,不做判斷。
//
//   拍數(只量不比,印在 log 的 latency 行):
//     拍數從 reset 釋放後第一個 posedge 之前那一拍算 0,「第 n 拍」指第 n 個 posedge 之前取樣的那一拍。
//     last_in   最後一筆輸入被收下的那一拍
//     done      整條最後還有東西在處理的那一拍(之後各層的管線、FIFO、轉接模組的暫存器都空)
//     in_blocked:上游要送、conv1 不收的拍數(不含清除期間);conv1_blocked、conv2_blocked、fc_in_blocked:
//     conv1 → conv2、conv2 → 轉接模組、轉接模組 → SaltFC 有東西要送、下一級不收的拍數。
//
//   include 這個檔案的 module 要定義這兩個函式,決定這支 testbench 的驅動方式:
//     function automatic void reset_driver();      每筆樣本開始前,把驅動用的狀態回到初始值
//     function automatic bit  input_starts_now();   上游這一拍要不要開始送下一筆事件
//   參數用 xelab -generic_top 帶入,答案檔目錄用 xsim -testplusarg REF_DIR=<目錄> 帶入,
//   答案檔是 <REF_DIR>/salt_conv_fc_net_SAT<SATURATE>.txt。
//////////////////////////////////////////////////////////////////////////////////

	// 預設值是訓練端飽和版、FC n_col = 4、R2C2 重疊
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
	parameter CONV1_WEIGHT_FILE    = "../../../../SaltNET.srcs/sources_1/mem/best_val50_b7_fa6_fv0_round_pc_clip100_saturate_iv9-11-11/conv1_weight.mem";
	parameter CONV1_THRESHOLD_FILE = "../../../../SaltNET.srcs/sources_1/mem/best_val50_b7_fa6_fv0_round_pc_clip100_saturate_iv9-11-11/conv1_threshold.mem";
	parameter CONV1_DECAY_FILE     = "../../../../SaltNET.srcs/sources_1/mem/best_val50_b7_fa6_fv0_round_pc_clip100_saturate_iv9-11-11/conv1_decay.mem";
	parameter integer CONV2_OUT_CHANNELS       = 16;
	parameter integer CONV2_KERNEL_SIZE        = 3;
	parameter integer CONV2_STRIDE             = 2;
	parameter integer CONV2_PADDING            = 1;
	parameter integer CONV2_MEMBRANE_INT_WIDTH = 11;
	parameter integer CONV2_DECAY_TABLE_DEPTH  = 75;
	parameter integer CONV2_FIFO_DEPTH         = 16;
	parameter CONV2_WEIGHT_FILE    = "../../../../SaltNET.srcs/sources_1/mem/best_val50_b7_fa6_fv0_round_pc_clip100_saturate_iv9-11-11/conv2_weight.mem";
	parameter CONV2_THRESHOLD_FILE = "../../../../SaltNET.srcs/sources_1/mem/best_val50_b7_fa6_fv0_round_pc_clip100_saturate_iv9-11-11/conv2_threshold.mem";
	parameter CONV2_DECAY_FILE     = "../../../../SaltNET.srcs/sources_1/mem/best_val50_b7_fa6_fv0_round_pc_clip100_saturate_iv9-11-11/conv2_decay.mem";
	parameter integer FC_OUT_NEURONS        = 10;
	parameter integer FC_NEURONS_PER_ROW    = 4;
	parameter integer FC_MEMBRANE_INT_WIDTH = 11;
	parameter integer FC_DECAY_TABLE_DEPTH  = 75;
	parameter integer FC_FIFO_DEPTH         = 16;
	parameter FC_WEIGHT_FILE = "../../../../SaltNET.srcs/sim_1/new/net/ref/salt_fc_IN1296_OUT10_COL4_IV11_FV0_RD1_SAT1_SPK0_weight.mem";
	parameter FC_DECAY_FILE  = "../../../../SaltNET.srcs/sim_1/new/net/ref/salt_fc_IN1296_OUT10_COL4_IV11_FV0_RD1_SAT1_SPK0_decay.mem";
	parameter integer TIME_WIDTH          = 16;
	parameter integer WEIGHT_WIDTH        = 7;
	parameter integer MEMBRANE_FRAC_WIDTH = 0;
	parameter integer DECAY_FRAC_WIDTH    = 6;
	parameter bit     ROUND               = 1;
	parameter bit     SATURATE            = 1;
	parameter integer READ_LATENCY        = 2;
	parameter integer COMPUTE_LATENCY     = 2;
	parameter bit     OVERLAP             = 1;

	// 跟 SaltConvFCNet、SaltConv、SaltFC 的 localparam 同一套公式
	localparam integer CONV1_OUT_ROWS = (IN_ROWS + 2 * CONV1_PADDING - CONV1_KERNEL_SIZE) / CONV1_STRIDE + 1;
	localparam integer CONV1_OUT_COLS = (IN_COLS + 2 * CONV1_PADDING - CONV1_KERNEL_SIZE) / CONV1_STRIDE + 1;
	localparam integer CONV2_OUT_ROWS = (CONV1_OUT_ROWS + 2 * CONV2_PADDING - CONV2_KERNEL_SIZE) / CONV2_STRIDE + 1;
	localparam integer CONV2_OUT_COLS = (CONV1_OUT_COLS + 2 * CONV2_PADDING - CONV2_KERNEL_SIZE) / CONV2_STRIDE + 1;
	localparam integer IN_X_WIDTH          = (IN_COLS > 1) ? $clog2(IN_COLS) : 1;
	localparam integer IN_Y_WIDTH          = (IN_ROWS > 1) ? $clog2(IN_ROWS) : 1;
	localparam integer IN_CHANNEL_WIDTH    = (IN_CHANNELS > 1) ? $clog2(IN_CHANNELS) : 1;
	localparam integer CONV1_MEMBRANE_WIDTH = CONV1_MEMBRANE_INT_WIDTH + MEMBRANE_FRAC_WIDTH;
	localparam integer CONV2_MEMBRANE_WIDTH = CONV2_MEMBRANE_INT_WIDTH + MEMBRANE_FRAC_WIDTH;
	localparam integer FC_MEMBRANE_WIDTH    = FC_MEMBRANE_INT_WIDTH + MEMBRANE_FRAC_WIDTH;
	localparam integer FC_ROW_COUNT         = (FC_OUT_NEURONS + FC_NEURONS_PER_ROW - 1) / FC_NEURONS_PER_ROW;   // n_row
	localparam integer CONV1_BANK_COUNT = (CONV1_KERNEL_SIZE + CONV1_STRIDE - 1) / CONV1_STRIDE;   // M
	localparam integer CONV2_BANK_COUNT = (CONV2_KERNEL_SIZE + CONV2_STRIDE - 1) / CONV2_STRIDE;
	localparam integer CONV1_BANK_DEPTH = CONV1_OUT_CHANNELS * ((CONV1_OUT_ROWS + CONV1_BANK_COUNT - 1) / CONV1_BANK_COUNT)
	                                    * ((CONV1_OUT_COLS + CONV1_BANK_COUNT - 1) / CONV1_BANK_COUNT);
	localparam integer CONV2_BANK_DEPTH = CONV2_OUT_CHANNELS * ((CONV2_OUT_ROWS + CONV2_BANK_COUNT - 1) / CONV2_BANK_COUNT)
	                                    * ((CONV2_OUT_COLS + CONV2_BANK_COUNT - 1) / CONV2_BANK_COUNT);
	localparam integer CONV1_WORD_WIDTH = CONV1_MEMBRANE_WIDTH + TIME_WIDTH;
	localparam integer CONV2_WORD_WIDTH = CONV2_MEMBRANE_WIDTH + TIME_WIDTH;
	localparam integer PIPELINE_DEPTH   = READ_LATENCY + COMPUTE_LATENCY - 1;   // L,三層相同
	// 兩層 conv 的記錄放在同一組陣列,index 0 是 conv1、1 是 conv2;bank 數、深度取兩層較大的
	localparam integer MAX_BANK_COUNT = (CONV1_BANK_COUNT > CONV2_BANK_COUNT) ? CONV1_BANK_COUNT : CONV2_BANK_COUNT;
	localparam integer MAX_BANK_DEPTH = (CONV1_BANK_DEPTH > CONV2_BANK_DEPTH) ? CONV1_BANK_DEPTH : CONV2_BANK_DEPTH;

	localparam integer CLOCK_PERIOD = 10;
	localparam integer RESET_CYCLES = 3;
	localparam integer END_CYCLES   = 3;    // 整條空下來之後多跑幾拍,看有沒有多寫、多送
	localparam integer MAX_PRINTED  = 20;   // 錯誤訊息最多印幾筆,之後只計數
	localparam integer INTERFACE_COUNT = 3;   // 0:conv1 → conv2,1:conv2 → 轉接模組,2:轉接模組 → SaltFC

	logic clk;
	logic rst_n;
	logic                                        in_valid;
	logic                                        in_ready;
	logic [IN_X_WIDTH-1:0]                       in_x;
	logic [IN_Y_WIDTH-1:0]                       in_y;
	logic [IN_CHANNEL_WIDTH-1:0]                 in_channel;
	logic [TIME_WIDTH-1:0]                       in_time;
	logic [FC_OUT_NEURONS*FC_MEMBRANE_WIDTH-1:0] membranes;
	logic                                        update_done;
	logic [TIME_WIDTH-1:0]                       update_time;

	SaltConvFCNet #(
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
		.FC_OUT_NEURONS          (FC_OUT_NEURONS),
		.FC_NEURONS_PER_ROW      (FC_NEURONS_PER_ROW),
		.FC_MEMBRANE_INT_WIDTH   (FC_MEMBRANE_INT_WIDTH),
		.FC_DECAY_TABLE_DEPTH    (FC_DECAY_TABLE_DEPTH),
		.FC_FIFO_DEPTH           (FC_FIFO_DEPTH),
		.FC_WEIGHT_FILE          (FC_WEIGHT_FILE),
		.FC_DECAY_FILE           (FC_DECAY_FILE),
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
	// 兩層 conv 每個 bank 的寫 port:generate 的 bank 只能用常數 index 取,搬到陣列裡給 initial 流程讀。
	// 沒有的 bank(這一層的 M 比較小)固定不寫。
	// ---------------------------------------------------------------
	logic conv_write_enable   [0:1][0:MAX_BANK_COUNT-1][0:MAX_BANK_COUNT-1];
	int   conv_write_addr     [0:1][0:MAX_BANK_COUNT-1][0:MAX_BANK_COUNT-1];
	int   conv_write_membrane [0:1][0:MAX_BANK_COUNT-1][0:MAX_BANK_COUNT-1];
	int   conv_write_time     [0:1][0:MAX_BANK_COUNT-1][0:MAX_BANK_COUNT-1];

	for (genvar row_bank = 0; row_bank < MAX_BANK_COUNT; row_bank++) begin : write_port_rows
		for (genvar col_bank = 0; col_bank < MAX_BANK_COUNT; col_bank++) begin : write_port_cols
			if (row_bank < CONV1_BANK_COUNT && col_bank < CONV1_BANK_COUNT) begin : conv1_bank
				assign conv_write_enable[0][row_bank][col_bank]   = dut.conv1.row_banks[row_bank].col_banks[col_bank].neuron_memory.write_enable;
				assign conv_write_addr[0][row_bank][col_bank]     = dut.conv1.row_banks[row_bank].col_banks[col_bank].neuron_memory.write_addr;
				assign conv_write_membrane[0][row_bank][col_bank] = $signed(dut.conv1.row_banks[row_bank].col_banks[col_bank].neuron_memory.write_word[CONV1_MEMBRANE_WIDTH-1:0]);
				assign conv_write_time[0][row_bank][col_bank]     = dut.conv1.row_banks[row_bank].col_banks[col_bank].neuron_memory.write_word[CONV1_WORD_WIDTH-1:CONV1_MEMBRANE_WIDTH];
			end else begin : conv1_no_bank
				assign conv_write_enable[0][row_bank][col_bank]   = 1'b0;
				assign conv_write_addr[0][row_bank][col_bank]     = 0;
				assign conv_write_membrane[0][row_bank][col_bank] = 0;
				assign conv_write_time[0][row_bank][col_bank]     = 0;
			end
			if (row_bank < CONV2_BANK_COUNT && col_bank < CONV2_BANK_COUNT) begin : conv2_bank
				assign conv_write_enable[1][row_bank][col_bank]   = dut.conv2.row_banks[row_bank].col_banks[col_bank].neuron_memory.write_enable;
				assign conv_write_addr[1][row_bank][col_bank]     = dut.conv2.row_banks[row_bank].col_banks[col_bank].neuron_memory.write_addr;
				assign conv_write_membrane[1][row_bank][col_bank] = $signed(dut.conv2.row_banks[row_bank].col_banks[col_bank].neuron_memory.write_word[CONV2_MEMBRANE_WIDTH-1:0]);
				assign conv_write_time[1][row_bank][col_bank]     = dut.conv2.row_banks[row_bank].col_banks[col_bank].neuron_memory.write_word[CONV2_WORD_WIDTH-1:CONV2_MEMBRANE_WIDTH];
			end else begin : conv2_no_bank
				assign conv_write_enable[1][row_bank][col_bank]   = 1'b0;
				assign conv_write_addr[1][row_bank][col_bank]     = 0;
				assign conv_write_membrane[1][row_bank][col_bank] = 0;
				assign conv_write_time[1][row_bank][col_bank]     = 0;
			end
		end
	end

	// ---------------------------------------------------------------
	// 兩層 NeuronMemory 記憶體內容的快照(樣本結束時比最終狀態),每個 bank 一個 process 複製
	// ---------------------------------------------------------------
	int   snapshot_membrane [0:1][0:MAX_BANK_COUNT-1][0:MAX_BANK_COUNT-1][0:MAX_BANK_DEPTH-1];
	int   snapshot_time     [0:1][0:MAX_BANK_COUNT-1][0:MAX_BANK_COUNT-1][0:MAX_BANK_DEPTH-1];
	event snapshot_request;

	for (genvar row_bank = 0; row_bank < CONV1_BANK_COUNT; row_bank++) begin : conv1_snapshot_rows
		for (genvar col_bank = 0; col_bank < CONV1_BANK_COUNT; col_bank++) begin : conv1_snapshot_cols
			always @(snapshot_request) begin
				for (int addr = 0; addr < CONV1_BANK_DEPTH; addr++) begin
					logic [CONV1_WORD_WIDTH-1:0] word;
					word = dut.conv1.row_banks[row_bank].col_banks[col_bank].neuron_memory.memory_array.bank[addr];
					snapshot_membrane[0][row_bank][col_bank][addr] = $signed(word[CONV1_MEMBRANE_WIDTH-1:0]);
					snapshot_time[0][row_bank][col_bank][addr]     = word[CONV1_WORD_WIDTH-1:CONV1_MEMBRANE_WIDTH];
				end
			end
		end
	end

	for (genvar row_bank = 0; row_bank < CONV2_BANK_COUNT; row_bank++) begin : conv2_snapshot_rows
		for (genvar col_bank = 0; col_bank < CONV2_BANK_COUNT; col_bank++) begin : conv2_snapshot_cols
			always @(snapshot_request) begin
				for (int addr = 0; addr < CONV2_BANK_DEPTH; addr++) begin
					logic [CONV2_WORD_WIDTH-1:0] word;
					word = dut.conv2.row_banks[row_bank].col_banks[col_bank].neuron_memory.memory_array.bank[addr];
					snapshot_membrane[1][row_bank][col_bank][addr] = $signed(word[CONV2_MEMBRANE_WIDTH-1:0]);
					snapshot_time[1][row_bank][col_bank][addr]     = word[CONV2_WORD_WIDTH-1:CONV2_MEMBRANE_WIDTH];
				end
			end
		end
	end

	// ---------------------------------------------------------------
	// 一筆樣本的答案
	// ---------------------------------------------------------------
	int in_count;
	int expected_in_x[$], expected_in_y[$], expected_in_c[$], expected_in_t[$];
	// 三個介面的事件,每筆 4 個欄位:conv 的介面是 (o_c, o_y, o_x, t),轉接模組 → SaltFC 是 (src, t, 0, 0)
	int event_count [0:INTERFACE_COUNT-1];
	int expected_event [0:INTERFACE_COUNT-1][0:3][$];
	// 兩層 conv 每個 bank 的更新,照寫回順序
	int write_count [0:1];
	int expected_write_addr     [0:1][0:MAX_BANK_COUNT-1][0:MAX_BANK_COUNT-1][$];
	int expected_write_membrane [0:1][0:MAX_BANK_COUNT-1][0:MAX_BANK_COUNT-1][$];
	int expected_write_time     [0:1][0:MAX_BANK_COUNT-1][0:MAX_BANK_COUNT-1][$];
	// FC 每筆事件之後的 V̂:第 k 筆的第 i 顆在 expected_update_membrane[k * FC_OUT_NEURONS + i]
	int expected_update_time[$];
	int expected_update_membrane[$];
	// 樣本結束時兩層 conv 每顆神經元的 (V̂, t_last)
	int state_count [0:1];
	int state_row_bank[0:1][$], state_col_bank[0:1][$], state_addr[0:1][$], state_membrane[0:1][$], state_last_time[0:1][$];

	// 統計
	int error_count  = 0;
	int run_count    = 0;
	int event_check_count [0:INTERFACE_COUNT-1] = '{0, 0, 0};
	int write_check_count [0:1] = '{0, 0};
	int update_check_count = 0;
	int state_check_count [0:1] = '{0, 0};

	function automatic string interface_name(int interface_index);
		case (interface_index)
			0:       return "conv1 → conv2";
			1:       return "conv2 → 轉接模組";
			default: return "轉接模組 → SaltFC";
		endcase
	endfunction

	function automatic string conv_name(int layer);
		return (layer == 0) ? "conv1" : "conv2";
	endfunction

	function automatic string parameter_text();
		return $sformatf({"IN_CHANNELS=%0d IN_ROWS=%0d IN_COLS=%0d ",
		                  "CONV1_OUT_CHANNELS=%0d CONV1_KERNEL_SIZE=%0d CONV1_STRIDE=%0d CONV1_PADDING=%0d ",
		                  "CONV1_MEMBRANE_INT_WIDTH=%0d CONV1_DECAY_TABLE_DEPTH=%0d CONV1_FIFO_DEPTH=%0d ",
		                  "CONV2_OUT_CHANNELS=%0d CONV2_KERNEL_SIZE=%0d CONV2_STRIDE=%0d CONV2_PADDING=%0d ",
		                  "CONV2_MEMBRANE_INT_WIDTH=%0d CONV2_DECAY_TABLE_DEPTH=%0d CONV2_FIFO_DEPTH=%0d ",
		                  "FC_OUT_NEURONS=%0d FC_NEURONS_PER_ROW=%0d FC_MEMBRANE_INT_WIDTH=%0d FC_DECAY_TABLE_DEPTH=%0d ",
		                  "FC_FIFO_DEPTH=%0d ",
		                  "TIME_WIDTH=%0d WEIGHT_WIDTH=%0d MEMBRANE_FRAC_WIDTH=%0d DECAY_FRAC_WIDTH=%0d ",
		                  "ROUND=%0d SATURATE=%0d READ_LATENCY=%0d COMPUTE_LATENCY=%0d OVERLAP=%0d"},
		                 IN_CHANNELS, IN_ROWS, IN_COLS,
		                 CONV1_OUT_CHANNELS, CONV1_KERNEL_SIZE, CONV1_STRIDE, CONV1_PADDING,
		                 CONV1_MEMBRANE_INT_WIDTH, CONV1_DECAY_TABLE_DEPTH, CONV1_FIFO_DEPTH,
		                 CONV2_OUT_CHANNELS, CONV2_KERNEL_SIZE, CONV2_STRIDE, CONV2_PADDING,
		                 CONV2_MEMBRANE_INT_WIDTH, CONV2_DECAY_TABLE_DEPTH, CONV2_FIFO_DEPTH,
		                 FC_OUT_NEURONS, FC_NEURONS_PER_ROW, FC_MEMBRANE_INT_WIDTH, FC_DECAY_TABLE_DEPTH,
		                 FC_FIFO_DEPTH,
		                 TIME_WIDTH, WEIGHT_WIDTH, MEMBRANE_FRAC_WIDTH, DECAY_FRAC_WIDTH,
		                 ROUND, SATURATE, READ_LATENCY, COMPUTE_LATENCY, OVERLAP);
	endfunction

	function automatic void report_error(string message);
		if (error_count < MAX_PRINTED) begin
			$display("MISMATCH t=%0t %s", $time, message);
		end
		error_count++;
	endfunction

	// ---------------------------------------------------------------
	// 讀答案檔
	// ---------------------------------------------------------------
	// 讀第 layer 層 conv 的 count 行 kind(conv1_out / conv2_out),conv2_out 多一欄 src,同時是轉接模組 → SaltFC 的答案
	function automatic void read_conv_outputs(int fd, int sample_index, int layer, string expected_kind);
		string kind;
		int a, b, c, d, src;
		for (int i = 0; i < event_count[layer]; i++) begin
			if (layer == 0) begin
				if ($fscanf(fd, "%s %d %d %d %d", kind, a, b, c, d) != 5 || kind != expected_kind)
					$fatal(1, "樣本 %0d 第 %0d 個 %s 行格式不對", sample_index, i, expected_kind);
			end else begin
				if ($fscanf(fd, "%s %d %d %d %d %d", kind, a, b, c, d, src) != 6 || kind != expected_kind)
					$fatal(1, "樣本 %0d 第 %0d 個 %s 行格式不對", sample_index, i, expected_kind);
				expected_event[2][0].push_back(src); expected_event[2][1].push_back(d);
				expected_event[2][2].push_back(0);   expected_event[2][3].push_back(0);
			end
			expected_event[layer][0].push_back(a); expected_event[layer][1].push_back(b);
			expected_event[layer][2].push_back(c); expected_event[layer][3].push_back(d);
		end
	endfunction

	// 讀第 layer 層 conv 的 write_count 行更新,放進各自 bank 的佇列
	function automatic void read_writes(int fd, int sample_index, int layer, string expected_kind);
		string kind;
		int row_bank, col_bank, addr, membrane, time_value;
		for (int i = 0; i < write_count[layer]; i++) begin
			if ($fscanf(fd, "%s %d %d %d %d %d", kind, row_bank, col_bank, addr, membrane, time_value) != 6
			    || kind != expected_kind)
				$fatal(1, "樣本 %0d 第 %0d 個 %s 行格式不對", sample_index, i, expected_kind);
			expected_write_addr[layer][row_bank][col_bank].push_back(addr);
			expected_write_membrane[layer][row_bank][col_bank].push_back(membrane);
			expected_write_time[layer][row_bank][col_bank].push_back(time_value);
		end
	endfunction

	function automatic void read_states(int fd, int sample_index, int layer, string expected_kind);
		string kind;
		int a, b, c, d, e;
		for (int i = 0; i < state_count[layer]; i++) begin
			if ($fscanf(fd, "%s %d %d %d %d %d", kind, a, b, c, d, e) != 6 || kind != expected_kind)
				$fatal(1, "樣本 %0d 第 %0d 個 %s 行格式不對", sample_index, i, expected_kind);
			state_row_bank[layer].push_back(a); state_col_bank[layer].push_back(b); state_addr[layer].push_back(c);
			state_membrane[layer].push_back(d); state_last_time[layer].push_back(e);
		end
	endfunction

	function automatic void clear_sample();
		expected_in_x.delete(); expected_in_y.delete(); expected_in_c.delete(); expected_in_t.delete();
		for (int interface_index = 0; interface_index < INTERFACE_COUNT; interface_index++)
			for (int field = 0; field < 4; field++) expected_event[interface_index][field].delete();
		for (int layer = 0; layer < 2; layer++) begin
			for (int row_bank = 0; row_bank < MAX_BANK_COUNT; row_bank++) begin
				for (int col_bank = 0; col_bank < MAX_BANK_COUNT; col_bank++) begin
					expected_write_addr[layer][row_bank][col_bank].delete();
					expected_write_membrane[layer][row_bank][col_bank].delete();
					expected_write_time[layer][row_bank][col_bank].delete();
				end
			end
			state_row_bank[layer].delete(); state_col_bank[layer].delete(); state_addr[layer].delete();
			state_membrane[layer].delete(); state_last_time[layer].delete();
		end
		expected_update_time.delete();
		expected_update_membrane.delete();
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
		if ($fscanf(fd, "%d %d %d %d %d %d %d", in_count, event_count[0], event_count[1], write_count[0],
		            write_count[1], state_count[0], state_count[1]) != 7)
			$fatal(1, "sample 行格式不對");
		event_count[2] = event_count[1];   // 轉接模組一筆進、一筆出
		clear_sample();

		for (int i = 0; i < in_count; i++) begin
			if ($fscanf(fd, "%s %d %d %d %d", kind, a, b, c, d) != 5 || kind != "in")
				$fatal(1, "樣本 %0d 第 %0d 個 in 行格式不對", sample_index, i);
			expected_in_x.push_back(a); expected_in_y.push_back(b); expected_in_c.push_back(c); expected_in_t.push_back(d);
		end
		read_conv_outputs(fd, sample_index, 0, "conv1_out");
		read_conv_outputs(fd, sample_index, 1, "conv2_out");
		read_writes(fd, sample_index, 0, "conv1_write");
		read_writes(fd, sample_index, 1, "conv2_write");
		for (int i = 0; i < event_count[2]; i++) begin
			if ($fscanf(fd, "%s %d", kind, a) != 2 || kind != "fc_update")
				$fatal(1, "樣本 %0d 第 %0d 個 fc_update 行格式不對", sample_index, i);
			expected_update_time.push_back(a);
			for (int neuron = 0; neuron < FC_OUT_NEURONS; neuron++) begin
				if ($fscanf(fd, "%d", b) != 1) $fatal(1, "樣本 %0d 第 %0d 個 fc_update 行的 V̂ 不夠", sample_index, i);
				expected_update_membrane.push_back(b);
			end
		end
		read_states(fd, sample_index, 0, "conv1_state");
		read_states(fd, sample_index, 1, "conv2_state");
		return 1'b1;
	endfunction

	// ---------------------------------------------------------------
	// 每一拍的檢查
	// ---------------------------------------------------------------
	// 整條空下來:三層的管線裡沒有東西、FIFO 沒有事件、轉接模組的暫存器空的、FC 沒有膜電位要送、都不在清除
	function automatic bit net_idle();
		for (int position = 1; position <= PIPELINE_DEPTH; position++) begin
			if (dut.conv1.pipe_valid[position] || dut.conv2.pipe_valid[position] || dut.fc.pipe_valid[position])
				return 1'b0;
		end
		return !dut.conv1.fifo_read_valid && !dut.conv2.fifo_read_valid && !dut.fc.fifo_read_valid
		       && !dut.conv_to_fc.event_valid && !dut.fc.membrane_valid
		       && !dut.conv1.clearing && !dut.conv2.clearing && !dut.fc.clearing;
	endfunction

	// 一個 valid/ready 介面這一拍的檢查:上一拍沒送出去,這一拍 valid 要還是 1、內容不變;
	// 交握成功就跟這個介面的下一筆答案比。previous_* 是上一拍的取樣,呼叫完更新成這一拍
	task automatic check_interface(string where, int interface_index, int unsigned fields [0:3], logic valid,
	                               logic ready, ref bit previous_stalled, ref int unsigned previous [0:3],
	                               ref int event_index);
		string name = interface_name(interface_index);
		bit    unchanged = 1'b1;
		for (int field = 0; field < 4; field++) begin
			if (fields[field] != previous[field]) unchanged = 1'b0;
		end
		if (previous_stalled) begin
			if (!valid) begin
				report_error($sformatf("%s %s:上一拍送不出去,這一拍 valid=0", where, name));
			end else if (!unchanged) begin
				report_error($sformatf("%s %s:上一拍送不出去,這一拍資料變了:(%0d,%0d,%0d,%0d) -> (%0d,%0d,%0d,%0d)",
				                       where, name, previous[0], previous[1], previous[2], previous[3],
				                       fields[0], fields[1], fields[2], fields[3]));
			end
		end
		if (valid && ready) begin
			if (event_index >= event_count[interface_index]) begin
				report_error($sformatf("%s %s 多送了一筆 (%0d,%0d,%0d,%0d)", where, name,
				                       fields[0], fields[1], fields[2], fields[3]));
			end else begin
				bit matched = 1'b1;
				for (int field = 0; field < 4; field++) begin
					if (fields[field] != expected_event[interface_index][field][event_index]) matched = 1'b0;
				end
				if (!matched) begin
					report_error($sformatf("%s %s 第 %0d 筆:expected=(%0d,%0d,%0d,%0d) actual=(%0d,%0d,%0d,%0d)",
					                       where, name, event_index,
					                       expected_event[interface_index][0][event_index],
					                       expected_event[interface_index][1][event_index],
					                       expected_event[interface_index][2][event_index],
					                       expected_event[interface_index][3][event_index],
					                       fields[0], fields[1], fields[2], fields[3]));
				end
			end
			event_check_count[interface_index]++;
			event_index++;
		end
		previous_stalled = valid && !ready;
		previous = fields;
	endtask

	// 兩層 conv 這一拍寫回神經元記憶體的,每個 bank 跟自己佇列的下一筆比
	task automatic check_writes(string where);
		for (int layer = 0; layer < 2; layer++) begin
			for (int row_bank = 0; row_bank < MAX_BANK_COUNT; row_bank++) begin
				for (int col_bank = 0; col_bank < MAX_BANK_COUNT; col_bank++) begin
					if (conv_write_enable[layer][row_bank][col_bank] !== 1'b1) begin
						if ($isunknown(conv_write_enable[layer][row_bank][col_bank]))
							report_error($sformatf("%s %s bank=(%0d,%0d) 寫入開關是 X", where, conv_name(layer),
							                       row_bank, col_bank));
						continue;
					end
					if (expected_write_addr[layer][row_bank][col_bank].size() == 0) begin
						report_error($sformatf("%s %s bank=(%0d,%0d) 多寫了一次:addr=%0d (V̂,t)=(%0d,%0d)", where,
						                       conv_name(layer), row_bank, col_bank,
						                       conv_write_addr[layer][row_bank][col_bank],
						                       conv_write_membrane[layer][row_bank][col_bank],
						                       conv_write_time[layer][row_bank][col_bank]));
					end else begin
						int addr       = expected_write_addr[layer][row_bank][col_bank].pop_front();
						int membrane   = expected_write_membrane[layer][row_bank][col_bank].pop_front();
						int time_value = expected_write_time[layer][row_bank][col_bank].pop_front();
						if (conv_write_addr[layer][row_bank][col_bank] != addr
						    || conv_write_membrane[layer][row_bank][col_bank] != membrane
						    || conv_write_time[layer][row_bank][col_bank] != time_value) begin
							report_error($sformatf("%s %s bank=(%0d,%0d) 更新:expected addr=%0d (V̂,t)=(%0d,%0d) actual addr=%0d (V̂,t)=(%0d,%0d)",
							                       where, conv_name(layer), row_bank, col_bank, addr, membrane, time_value,
							                       conv_write_addr[layer][row_bank][col_bank],
							                       conv_write_membrane[layer][row_bank][col_bank],
							                       conv_write_time[layer][row_bank][col_bank]));
						end
					end
					write_check_count[layer]++;
				end
			end
		end
	endtask

	// update_done 那一拍:10 顆的 V̂、update_time 跟 FC 下一筆更新比
	task automatic check_fc_update(string where, ref int update_index);
		if ($isunknown(update_done)) begin
			report_error($sformatf("%s update_done 是 X", where));
			return;
		end
		if (!update_done) return;
		if (update_index >= event_count[2]) begin
			report_error($sformatf("%s FC 多更新了一次 update_time=%0d", where, update_time));
		end else begin
			if (update_time != TIME_WIDTH'(expected_update_time[update_index])) begin
				report_error($sformatf("%s FC 第 %0d 筆更新 update_time:expected=%0d actual=%0d", where, update_index,
				                       expected_update_time[update_index], update_time));
			end
			for (int neuron = 0; neuron < FC_OUT_NEURONS; neuron++) begin
				int expected = expected_update_membrane[update_index * FC_OUT_NEURONS + neuron];
				int actual   = $signed(membranes[neuron * FC_MEMBRANE_WIDTH +: FC_MEMBRANE_WIDTH]);
				if (actual != expected) begin
					report_error($sformatf("%s FC 第 %0d 筆更新 神經元 %0d:expected=%0d actual=%0d", where, update_index,
					                       neuron, expected, actual));
				end
			end
		end
		update_check_count++;
		update_index++;
	endtask

	task automatic apply_reset();
		@(negedge clk);
		rst_n    = 1'b0;
		in_valid = 1'b0;
		repeat (RESET_CYCLES) @(negedge clk);
		rst_n = 1'b1;
	endtask

	// ---------------------------------------------------------------
	// 一筆樣本
	// ---------------------------------------------------------------
	task automatic run_sample(int sample_index);
		int  in_index     = 0;
		bit  presenting   = 1'b0;
		int  cycle        = 0;
		int  tail_left    = -1;   // 整條空下來之後還要多跑幾拍;-1 是還沒空下來
		int  max_cycles;
		int  update_index = 0;
		int  event_index      [0:INTERFACE_COUNT-1] = '{0, 0, 0};
		bit  previous_stalled [0:INTERFACE_COUNT-1] = '{1'b0, 1'b0, 1'b0};
		int unsigned previous [0:INTERFACE_COUNT-1][0:3];
		// 拍數,定義見檔頭
		int  last_in_cycle = -1;
		int  done_cycle    = -1;
		int  in_blocked    = 0;
		int  conv1_blocked = 0;
		int  conv2_blocked = 0;
		int  fc_in_blocked = 0;
		bit  sampled_in_handshake;
		string where;

		// 一筆事件最多 OC 個 o_c、每個 o_c 最多 M×M 拍;FC 一筆事件最多 n_row 列、每列最多 1 拍(不 fire)。
		// 層與層之間互相擋的拍數另外加一倍
		max_cycles = 2 * (in_count * CONV1_OUT_CHANNELS * CONV1_BANK_COUNT * CONV1_BANK_COUNT
		                  + event_count[0] * CONV2_OUT_CHANNELS * CONV2_BANK_COUNT * CONV2_BANK_COUNT
		                  + event_count[1] * (FC_ROW_COUNT + PIPELINE_DEPTH))
		           + MAX_BANK_DEPTH + 10000;
		reset_driver();
		apply_reset();

		forever begin
			where = $sformatf("sample=%0d cycle=%0d", sample_index, cycle);

			// ---------------- negedge:驅動輸入 ----------------
			if (!presenting && in_index < in_count && input_starts_now()) begin
				presenting = 1'b1;
				in_x       = IN_X_WIDTH'(expected_in_x[in_index]);
				in_y       = IN_Y_WIDTH'(expected_in_y[in_index]);
				in_channel = IN_CHANNEL_WIDTH'(expected_in_c[in_index]);
				in_time    = TIME_WIDTH'(expected_in_t[in_index]);
			end
			in_valid = presenting;
			#1;

			// ---------------- posedge 之前:取樣、檢查 ----------------
			if ($isunknown(in_ready)) report_error($sformatf("%s in_ready 是 X", where));
			if (dut.conv1.clearing && in_ready) report_error($sformatf("%s conv1 清除期間 in_ready=1", where));
			if (dut.conv2.clearing && dut.conv1_out_ready) report_error($sformatf("%s conv2 清除期間 conv1 的輸出被收", where));
			if (dut.fc.clearing && dut.fc_in_ready) report_error($sformatf("%s SaltFC 清除期間轉接模組的輸出被收", where));

			check_interface(where, 0, '{dut.conv1_out_channel, dut.conv1_out_y, dut.conv1_out_x, dut.conv1_out_time},
			                dut.conv1_out_valid, dut.conv1_out_ready, previous_stalled[0], previous[0], event_index[0]);
			check_interface(where, 1, '{dut.conv2_out_channel, dut.conv2_out_y, dut.conv2_out_x, dut.conv2_out_time},
			                dut.conv2_out_valid, dut.conv2_out_ready, previous_stalled[1], previous[1], event_index[1]);
			check_interface(where, 2, '{dut.fc_in_neuron, dut.fc_in_time, 0, 0},
			                dut.fc_in_valid, dut.fc_in_ready, previous_stalled[2], previous[2], event_index[2]);
			check_writes(where);
			check_fc_update(where, update_index);

			if (in_valid && !in_ready && !dut.conv1.clearing) in_blocked++;
			if (dut.conv1_out_valid && !dut.conv1_out_ready) conv1_blocked++;
			if (dut.conv2_out_valid && !dut.conv2_out_ready) conv2_blocked++;
			if (dut.fc_in_valid && !dut.fc_in_ready) fc_in_blocked++;
			sampled_in_handshake = in_valid && in_ready;
			if (sampled_in_handshake) last_in_cycle = cycle;

			// ---------------- posedge ----------------
			@(posedge clk);
			#1;
			cycle++;
			if (sampled_in_handshake) begin
				presenting = 1'b0;
				in_index++;
			end

			if (tail_left < 0 && in_index == in_count && !presenting && net_idle()) begin
				done_cycle = cycle - 1;
				tail_left  = END_CYCLES;
			end
			if (tail_left == 0) break;
			if (tail_left > 0) tail_left--;
			if (cycle > max_cycles) begin
				report_error($sformatf("%s 跑了 %0d 拍還沒結束:in %0d/%0d conv1 out %0d/%0d conv2 out %0d/%0d fc update %0d/%0d",
				                       where, cycle, in_index, in_count, event_index[0], event_count[0],
				                       event_index[1], event_count[1], update_index, event_count[2]));
				break;
			end
			@(negedge clk);
		end

		// 筆數:三個介面、每個 bank 的更新、FC 的更新
		for (int interface_index = 0; interface_index < INTERFACE_COUNT; interface_index++) begin
			if (event_index[interface_index] != event_count[interface_index]) begin
				report_error($sformatf("sample=%0d %s 送了 %0d 筆,答案 %0d 筆", sample_index,
				                       interface_name(interface_index), event_index[interface_index],
				                       event_count[interface_index]));
			end
		end
		for (int layer = 0; layer < 2; layer++) begin
			for (int row_bank = 0; row_bank < MAX_BANK_COUNT; row_bank++) begin
				for (int col_bank = 0; col_bank < MAX_BANK_COUNT; col_bank++) begin
					if (expected_write_addr[layer][row_bank][col_bank].size() != 0) begin
						report_error($sformatf("sample=%0d %s bank=(%0d,%0d) 少寫了 %0d 次,下一筆是 addr=%0d (V̂,t)=(%0d,%0d)",
						                       sample_index, conv_name(layer), row_bank, col_bank,
						                       expected_write_addr[layer][row_bank][col_bank].size(),
						                       expected_write_addr[layer][row_bank][col_bank][0],
						                       expected_write_membrane[layer][row_bank][col_bank][0],
						                       expected_write_time[layer][row_bank][col_bank][0]));
					end
				end
			end
		end
		if (update_index != event_count[2]) begin
			report_error($sformatf("sample=%0d FC 更新 %0d 次,答案 %0d 次", sample_index, update_index, event_count[2]));
		end

		$display("latency sample=%0d in=%0d conv1_out=%0d conv2_out=%0d last_in=%0d done=%0d after_input=%0d in_blocked=%0d conv1_blocked=%0d conv2_blocked=%0d fc_in_blocked=%0d",
		         sample_index, in_count, event_count[0], event_count[1], last_in_cycle, done_cycle,
		         done_cycle - last_in_cycle, in_blocked, conv1_blocked, conv2_blocked, fc_in_blocked);

		// 兩層 conv 樣本結束時的神經元狀態
		-> snapshot_request;
		#1;
		for (int layer = 0; layer < 2; layer++) begin
			for (int i = 0; i < state_count[layer]; i++) begin
				int row_bank = state_row_bank[layer][i];
				int col_bank = state_col_bank[layer][i];
				int addr     = state_addr[layer][i];
				if (snapshot_membrane[layer][row_bank][col_bank][addr] != state_membrane[layer][i]
				    || snapshot_time[layer][row_bank][col_bank][addr] != state_last_time[layer][i]) begin
					report_error($sformatf("sample=%0d %s 最終狀態 bank=(%0d,%0d) addr=%0d:expected=(%0d,%0d) actual=(%0d,%0d)",
					                       sample_index, conv_name(layer), row_bank, col_bank, addr,
					                       state_membrane[layer][i], state_last_time[layer][i],
					                       snapshot_membrane[layer][row_bank][col_bank][addr],
					                       snapshot_time[layer][row_bank][col_bank][addr]));
				end
				state_check_count[layer]++;
			end
		end
		run_count++;
	endtask

	initial begin
		string ref_dir;
		string ref_path;
		int    ref_fd;
		int    sample_index;
		string verdict;

		// 亂數不另外設種子:xsim 不支援 $urandom(seed),用預設的 -sv_seed,每次跑都是同一串
		rst_n    = 1'b0;
		in_valid = 1'b0;
		in_x = '0; in_y = '0; in_channel = '0; in_time = '0;

		if (!$value$plusargs("REF_DIR=%s", ref_dir))
			$fatal(1, "缺少 -testplusarg REF_DIR=<答案檔目錄>");
		ref_path = $sformatf("%s/salt_conv_fc_net_SAT%0d.txt", ref_dir, SATURATE);
		ref_fd = $fopen(ref_path, "r");
		if (ref_fd == 0) $fatal(1, "打不開答案檔 %s(不進 git,先跑 scripts/net/gen_salt_conv_fc_net_ref.py)", ref_path);

		sample_index = 0;
		while (read_sample(ref_fd, sample_index)) begin
			run_sample(sample_index);
			sample_index++;
		end
		$fclose(ref_fd);

		if (error_count == 0 && run_count > 0) verdict = "ALL PASS";
		else verdict = "FAIL";
		$display("%s: sample_count=%0d run_count=%0d conv1_out_check_count=%0d conv2_out_check_count=%0d fc_in_check_count=%0d conv1_write_check_count=%0d conv2_write_check_count=%0d fc_update_check_count=%0d conv1_state_check_count=%0d conv2_state_check_count=%0d error_count=%0d %s",
		         parameter_text(), sample_index, run_count, event_check_count[0], event_check_count[1],
		         event_check_count[2], write_check_count[0], write_check_count[1], update_check_count,
		         state_check_count[0], state_check_count[1], error_count, verdict);
		$finish;
	end
