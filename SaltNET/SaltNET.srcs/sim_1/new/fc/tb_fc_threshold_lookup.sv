`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: tb_fc_threshold_lookup
// Description:
//   FC 門檻 ROM 驗證(FC.md 第 2 節「門檻」):SaltFC 直接例化 lib/ReadOnlyMemory,位址 y,
//   讀出寬字的第 x 段要等於 v_th[y*n_col + x],最後一列空的位置是 0。
//   寬字切段照 SaltFC 的做法(第 x 行從第 x*MEMBRANE_WIDTH bit 起),在這裡切。
//   答案是 scripts/fc/gen_fc_threshold_lookup_ref.py 直接從 v_th 算的,不經過門檻檔的打包。
//   答案檔一行一列,y 由小到大:
//     negedge:送位址 y
//     posedge(READ_LATENCY 次):ReadOnlyMemory 讀出
//     最後一個 posedge 後 #1:比對 n_col 個門檻,含最後一列補 0 的位置
//   參數用 xelab -generic_top 帶入,答案檔目錄用 xsim -testplusarg REF_DIR=<目錄> 帶入,
//   答案檔名照參數組出來,規則跟 gen_fc_threshold_lookup_ref.py 的 ref_file_stem 相同(READ_LATENCY 不影響答案)。
//////////////////////////////////////////////////////////////////////////////////

module tb_fc_threshold_lookup;

	// 預設值是訓練端 out 層的形狀(n_col 先用 4)、繞回版的 w;out 層實際不 fire,門檻是隨機產生的
	parameter integer OUT_NEURONS     = 10;
	parameter integer NEURONS_PER_ROW = 4;
	parameter integer MEMBRANE_WIDTH  = 14;
	parameter integer READ_LATENCY    = 1;
	// 相對路徑以 xsim 的執行目錄 SaltNET.sim/<模擬集>/behav/xsim 為準;run_tb_fc_threshold_lookup.tcl 會改傳絕對路徑
	parameter THRESHOLD_FILE = "../../../../SaltNET.srcs/sim_1/new/fc/ref/fc_threshold_lookup_OUT10_COL4_W14_threshold.mem";

	// 跟 SaltFC 的 localparam 同一套公式,port 位寬要對上才能接
	localparam integer ROW_COUNT      = (OUT_NEURONS + NEURONS_PER_ROW - 1) / NEURONS_PER_ROW;   // n_row
	localparam integer ROW_WIDTH      = (ROW_COUNT > 1) ? $clog2(ROW_COUNT) : 1;
	localparam integer ROW_WORD_WIDTH = NEURONS_PER_ROW * MEMBRANE_WIDTH;

	logic clk = 1'b0;
	always #5 clk = ~clk;

	logic                             read_enable;
	logic        [ROW_WIDTH-1:0]      read_row;    // y
	logic        [ROW_WORD_WIDTH-1:0] row_word;
	logic signed [MEMBRANE_WIDTH-1:0] threshold [0:NEURONS_PER_ROW-1];

	ReadOnlyMemory #(
		.DEPTH       (ROW_COUNT),
		.WORD_WIDTH  (ROW_WORD_WIDTH),
		.READ_LATENCY(READ_LATENCY),
		.INIT_FILE   (THRESHOLD_FILE)
	) memory (
		.clk         (clk),
		.read_enable (read_enable),
		.shift_enable(1'b1),
		.read_addr   (read_row),
		.read_word   (row_word)
	);

	for (genvar column = 0; column < NEURONS_PER_ROW; column++) begin : columns
		assign threshold[column] = row_word[column*MEMBRANE_WIDTH +: MEMBRANE_WIDTH];
	end

	string ref_dir;
	string ref_path;
	int    ref_fd;
	int    check_count;
	int    error_count;

	initial begin
		int expected_row;
		int expected_threshold [0:NEURONS_PER_ROW-1];
		int scan_count;

		check_count = 0;
		error_count = 0;
		read_enable = 1'b1;

		if (!$value$plusargs("REF_DIR=%s", ref_dir))
			$fatal(1, "缺少 -testplusarg REF_DIR=<答案檔目錄>");
		ref_path = $sformatf("%s/fc_threshold_lookup_OUT%0d_COL%0d_W%0d.txt",
		                     ref_dir, OUT_NEURONS, NEURONS_PER_ROW, MEMBRANE_WIDTH);
		ref_fd = $fopen(ref_path, "r");
		if (ref_fd == 0)
			$fatal(1, "打不開答案檔 %s", ref_path);

		for (int row = 0; row < ROW_COUNT; row++) begin
			scan_count = $fscanf(ref_fd, "%d", expected_row);
			if (scan_count != 1 || expected_row != row)
				$fatal(1, "答案檔格式不對:要 y=%0d,讀到 %0d", row, expected_row);
			for (int column = 0; column < NEURONS_PER_ROW; column++) begin
				scan_count = $fscanf(ref_fd, "%d", expected_threshold[column]);
				if (scan_count != 1)
					$fatal(1, "答案檔 y=%0d 第 %0d 行欄位不足", row, column);
			end

			// negedge 送位址;READ_LATENCY 個 posedge 後讀出,#1 後比對
			@(negedge clk);
			read_row = ROW_WIDTH'(row);
			repeat (READ_LATENCY) @(posedge clk);
			#1;

			for (int column = 0; column < NEURONS_PER_ROW; column++) begin
				check_count++;
				if ($isunknown(threshold[column]) || int'(threshold[column]) != expected_threshold[column]) begin
					error_count++;
					$display("MISMATCH y=%0d column=%0d neuron=%0d: expected=%0d actual=%0d",
					         row, column, row * NEURONS_PER_ROW + column, expected_threshold[column], threshold[column]);
				end
			end
		end
		$fclose(ref_fd);

		$display("THRESHOLD_FILE=%s", THRESHOLD_FILE);
		$display("OUT_NEURONS=%0d NEURONS_PER_ROW=%0d MEMBRANE_WIDTH=%0d READ_LATENCY=%0d: check_count=%0d error_count=%0d %s",
		         OUT_NEURONS, NEURONS_PER_ROW, MEMBRANE_WIDTH, READ_LATENCY, check_count, error_count,
		         (error_count == 0) ? "ALL PASS" : "FAIL");
		$finish;
	end

endmodule
