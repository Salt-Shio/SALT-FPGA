`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: tb_fc_weight_lookup
// Description:
//   lib/WeightMemory 用 FC 的參數驗證:送 (y, src),讀出寬字的第 x 段要等於 q[y*n_col + x, src],最後一列空的位置是 0。
//   寬字切段照 SaltFC 的做法(第 x 行從第 x*WEIGHT_WIDTH bit 起),在這裡切。
//   答案是 scripts/fc/gen_fc_weight_lookup_ref.py 直接從 q 算的,不經過權重檔的打包。
//   答案檔一行一個位址,y、src 由外到內窮舉:
//     negedge:送 out_index = y、in_index = src
//     posedge(READ_LATENCY 次):WeightMemory 讀出
//     最後一個 posedge 後 #1:比對 n_col 個權重碼,含最後一列補 0 的位置
//   參數用 xelab -generic_top 帶入,答案檔目錄用 xsim -testplusarg REF_DIR=<目錄> 帶入,
//   答案檔名照參數組出來,規則跟 gen_fc_weight_lookup_ref.py 的 ref_file_stem 相同(READ_LATENCY 不影響答案)。
//////////////////////////////////////////////////////////////////////////////////

module tb_fc_weight_lookup;

	// 預設值是訓練端 out 層,n_col 先用 4
	parameter integer IN_NEURONS      = 1296;
	parameter integer OUT_NEURONS     = 10;
	parameter integer NEURONS_PER_ROW = 4;
	parameter integer WEIGHT_WIDTH    = 7;
	parameter integer READ_LATENCY    = 1;
	// 相對路徑以 xsim 的執行目錄 SaltNET.sim/<模擬集>/behav/xsim 為準;run_tb_fc_weight_lookup.tcl 會改傳絕對路徑
	parameter WEIGHT_FILE = "../../../../SaltNET.srcs/sim_1/new/fc/ref/fc_weight_lookup_IN1296_OUT10_COL4_B7_weight.mem";

	// 跟 SaltFC、WeightMemory 的 localparam 同一套公式,port 位寬要對上才能接
	localparam integer ROW_COUNT       = (OUT_NEURONS + NEURONS_PER_ROW - 1) / NEURONS_PER_ROW;   // n_row
	localparam integer ROW_WIDTH       = (ROW_COUNT > 1) ? $clog2(ROW_COUNT) : 1;
	localparam integer IN_NEURON_WIDTH = (IN_NEURONS > 1) ? $clog2(IN_NEURONS) : 1;
	localparam integer ROW_WORD_WIDTH  = NEURONS_PER_ROW * WEIGHT_WIDTH;

	logic clk = 1'b0;
	always #5 clk = ~clk;

	logic                              read_enable;
	logic        [ROW_WIDTH-1:0]       read_row;      // y
	logic        [IN_NEURON_WIDTH-1:0] read_neuron;   // src
	logic        [ROW_WORD_WIDTH-1:0]  row_word;
	logic signed [WEIGHT_WIDTH-1:0]    weight_code [0:NEURONS_PER_ROW-1];

	WeightMemory #(
		.IN_INDEX_WIDTH(IN_NEURON_WIDTH),
		.IN_COUNT      (IN_NEURONS),
		.OUT_COUNT     (ROW_COUNT),
		.WORD_WIDTH    (ROW_WORD_WIDTH),
		.READ_LATENCY  (READ_LATENCY),
		.WEIGHT_FILE   (WEIGHT_FILE)
	) memory (
		.clk         (clk),
		.read_enable (read_enable),
		.shift_enable(1'b1),
		.out_index   (read_row),
		.in_index    (read_neuron),
		.read_word   (row_word)
	);

	for (genvar column = 0; column < NEURONS_PER_ROW; column++) begin : columns
		assign weight_code[column] = row_word[column*WEIGHT_WIDTH +: WEIGHT_WIDTH];
	end

	string ref_dir;
	string ref_path;
	int    ref_fd;
	int    check_count;
	int    error_count;

	initial begin
		int expected_row;
		int expected_source;
		int expected_weight [0:NEURONS_PER_ROW-1];
		int scan_count;

		check_count = 0;
		error_count = 0;
		read_enable = 1'b1;

		if (!$value$plusargs("REF_DIR=%s", ref_dir))
			$fatal(1, "缺少 -testplusarg REF_DIR=<答案檔目錄>");
		ref_path = $sformatf("%s/fc_weight_lookup_IN%0d_OUT%0d_COL%0d_B%0d.txt",
		                     ref_dir, IN_NEURONS, OUT_NEURONS, NEURONS_PER_ROW, WEIGHT_WIDTH);
		ref_fd = $fopen(ref_path, "r");
		if (ref_fd == 0)
			$fatal(1, "打不開答案檔 %s", ref_path);

		for (int row = 0; row < ROW_COUNT; row++) begin
			for (int source = 0; source < IN_NEURONS; source++) begin
				scan_count = $fscanf(ref_fd, "%d %d", expected_row, expected_source);
				if (scan_count != 2 || expected_row != row || expected_source != source)
					$fatal(1, "答案檔格式不對:要 y=%0d src=%0d,讀到 %0d %0d", row, source, expected_row, expected_source);
				for (int column = 0; column < NEURONS_PER_ROW; column++) begin
					scan_count = $fscanf(ref_fd, "%d", expected_weight[column]);
					if (scan_count != 1)
						$fatal(1, "答案檔 y=%0d src=%0d 第 %0d 行欄位不足", row, source, column);
				end

				// negedge 送 (y, src);READ_LATENCY 個 posedge 後讀出,#1 後比對
				@(negedge clk);
				read_row    = ROW_WIDTH'(row);
				read_neuron = IN_NEURON_WIDTH'(source);
				repeat (READ_LATENCY) @(posedge clk);
				#1;

				for (int column = 0; column < NEURONS_PER_ROW; column++) begin
					check_count++;
					if ($isunknown(weight_code[column]) || int'(weight_code[column]) != expected_weight[column]) begin
						error_count++;
						$display("MISMATCH y=%0d src=%0d column=%0d neuron=%0d: expected=%0d actual=%0d",
						         row, source, column, row * NEURONS_PER_ROW + column,
						         expected_weight[column], weight_code[column]);
					end
				end
			end
		end
		$fclose(ref_fd);

		$display("WEIGHT_FILE=%s", WEIGHT_FILE);
		$display("IN_NEURONS=%0d OUT_NEURONS=%0d NEURONS_PER_ROW=%0d WEIGHT_WIDTH=%0d READ_LATENCY=%0d: check_count=%0d error_count=%0d %s",
		         IN_NEURONS, OUT_NEURONS, NEURONS_PER_ROW, WEIGHT_WIDTH, READ_LATENCY, check_count, error_count,
		         (error_count == 0) ? "ALL PASS" : "FAIL");
		$finish;
	end

endmodule
