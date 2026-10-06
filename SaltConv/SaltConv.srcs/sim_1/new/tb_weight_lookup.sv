`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: tb_weight_lookup
// Description:
//   WeightMemory + WeightTapSelect 一起驗證:讀出的權重要等於 q[o_c,c,k_y,k_x]。
//   答案是 scripts/gen_weight_lookup_ref.py 用訓練端的候選規則算的:每組 (o_c, c)、每個事件座標 (y, x),
//   每個 bank 的 valid、(k_y, k_x),以及 q[o_c,c,k_y,k_x]。答案不經過權重檔的打包。
//   答案檔一行跑一拍,o_c、c、in_y、in_x 由外到內:
//     negedge:送 (o_c, c),每個 bank 的 tap_y、tap_x 給答案檔的 (k_y, k_x)
//     posedge:WeightMemory 讀進 q[o_c,c]
//     posedge 後 #1:比對 valid=1 的 bank
//   參數用 xelab -generic_top 帶入,答案檔目錄用 xsim -testplusarg REF_DIR=<目錄> 帶入,
//   答案檔名照參數組出來,規則跟 gen_weight_lookup_ref.py 的 ref_file_stem 相同。
//////////////////////////////////////////////////////////////////////////////////

module tb_weight_lookup;

	// 預設值是訓練端 conv1(configs/conv/baseline.yaml)
	parameter integer IN_CHANNEL_WIDTH = 1;
	parameter integer IN_CHANNELS      = 2;
	parameter integer OUT_CHANNELS     = 8;
	parameter integer KERNEL_SIZE      = 3;
	parameter integer STRIDE           = 2;
	parameter integer PADDING          = 1;
	parameter integer OUT_ROWS         = 17;
	parameter integer OUT_COLS         = 17;
	parameter integer Y_WIDTH          = 6;
	parameter integer X_WIDTH          = 6;
	parameter integer WEIGHT_WIDTH     = 7;
	// 相對路徑以 xsim 的執行目錄 SaltConv.sim/<模擬集>/behav/xsim 為準;run_tb_weight_lookup.tcl 會改傳絕對路徑
	parameter WEIGHT_FILE = "../../../../SaltConv.srcs/sources_1/mem/best_val50_b7_fa6_fv0_round_pc_clip100_wrap_g1/conv1_weight.mem";

	// 跟 WeightMemory、WeightTapSelect 的 localparam 同一套公式,port 位寬要對上才能接
	localparam integer KERNEL_WORD_WIDTH = KERNEL_SIZE * KERNEL_SIZE * WEIGHT_WIDTH;
	localparam integer OUT_CHANNEL_WIDTH = (OUT_CHANNELS > 1) ? $clog2(OUT_CHANNELS) : 1;
	localparam integer AXIS_BANK_COUNT   = (KERNEL_SIZE + STRIDE - 1) / STRIDE;
	localparam integer TAP_WIDTH         = (KERNEL_SIZE > 1) ? $clog2(KERNEL_SIZE) : 1;
	localparam integer IN_Y_COUNT        = 2 ** Y_WIDTH;
	localparam integer IN_X_COUNT        = 2 ** X_WIDTH;

	logic clk = 1'b0;
	always #5 clk = ~clk;

	logic                                read_enable;
	logic        [OUT_CHANNEL_WIDTH-1:0] out_channel;
	logic        [IN_CHANNEL_WIDTH-1:0]  in_channel;
	logic        [KERNEL_WORD_WIDTH-1:0] kernel_word;
	logic        [TAP_WIDTH-1:0]         tap_y       [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1];
	logic        [TAP_WIDTH-1:0]         tap_x       [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1];
	logic signed [WEIGHT_WIDTH-1:0]      weight_code [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1];

	WeightMemory #(
		.IN_CHANNEL_WIDTH(IN_CHANNEL_WIDTH),
		.IN_CHANNELS     (IN_CHANNELS),
		.OUT_CHANNELS    (OUT_CHANNELS),
		.KERNEL_SIZE     (KERNEL_SIZE),
		.WEIGHT_WIDTH    (WEIGHT_WIDTH),
		.WEIGHT_FILE     (WEIGHT_FILE)
	) memory (
		.clk        (clk),
		.read_enable(read_enable),
		.out_channel(out_channel),
		.in_channel (in_channel),
		.kernel_word(kernel_word)
	);

	WeightTapSelect #(
		.KERNEL_SIZE (KERNEL_SIZE),
		.STRIDE      (STRIDE),
		.WEIGHT_WIDTH(WEIGHT_WIDTH)
	) tap_select (
		.kernel_word(kernel_word),
		.tap_y      (tap_y),
		.tap_x      (tap_x),
		.weight_code(weight_code)
	);

	string ref_dir;
	string ref_path;
	int    ref_fd;
	int    check_count;
	int    error_count;

	initial begin
		int expected_channel_out;
		int expected_channel_in;
		int expected_y;
		int expected_x;
		int expected_valid  [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1];
		int expected_tap_y  [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1];
		int expected_tap_x  [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1];
		int expected_weight [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1];
		int scan_count;

		check_count = 0;
		error_count = 0;
		read_enable = 1'b1;

		if (!$value$plusargs("REF_DIR=%s", ref_dir))
			$fatal(1, "缺少 -testplusarg REF_DIR=<答案檔目錄>");
		ref_path = $sformatf("%s/weight_lookup_K%0d_S%0d_P%0d_R%0d_C%0d_IC%0d_OC%0d_Y%0d_X%0d_B%0d.txt",
		                     ref_dir, KERNEL_SIZE, STRIDE, PADDING, OUT_ROWS, OUT_COLS, IN_CHANNELS,
		                     OUT_CHANNELS, Y_WIDTH, X_WIDTH, WEIGHT_WIDTH);
		ref_fd = $fopen(ref_path, "r");
		if (ref_fd == 0)
			$fatal(1, "打不開答案檔 %s", ref_path);

		for (int channel_out = 0; channel_out < OUT_CHANNELS; channel_out++) begin
			for (int channel_in = 0; channel_in < IN_CHANNELS; channel_in++) begin
				for (int coord_y = 0; coord_y < IN_Y_COUNT; coord_y++) begin
					for (int coord_x = 0; coord_x < IN_X_COUNT; coord_x++) begin
						scan_count = $fscanf(ref_fd, "%d %d %d %d", expected_channel_out, expected_channel_in,
						                     expected_y, expected_x);
						if (scan_count != 4 || expected_channel_out != channel_out || expected_channel_in != channel_in
						    || expected_y != coord_y || expected_x != coord_x)
							$fatal(1, "答案檔格式不對:要 out_channel=%0d in_channel=%0d in_y=%0d in_x=%0d,讀到 %0d %0d %0d %0d",
							       channel_out, channel_in, coord_y, coord_x,
							       expected_channel_out, expected_channel_in, expected_y, expected_x);
						for (int row_bank = 0; row_bank < AXIS_BANK_COUNT; row_bank++) begin
							for (int col_bank = 0; col_bank < AXIS_BANK_COUNT; col_bank++) begin
								scan_count = $fscanf(ref_fd, "%d %d %d %d", expected_valid[row_bank][col_bank],
								                     expected_tap_y[row_bank][col_bank], expected_tap_x[row_bank][col_bank],
								                     expected_weight[row_bank][col_bank]);
								if (scan_count != 4)
									$fatal(1, "答案檔 out_channel=%0d in_channel=%0d in_y=%0d in_x=%0d bank=(%0d,%0d) 欄位不足",
									       channel_out, channel_in, coord_y, coord_x, row_bank, col_bank);
							end
						end

						// negedge 送 (o_c, c) 跟每個 bank 的 (k_y, k_x);posedge 讀出 q[o_c,c],#1 後比對 valid=1 的 bank
						@(negedge clk);
						out_channel = OUT_CHANNEL_WIDTH'(channel_out);
						in_channel  = IN_CHANNEL_WIDTH'(channel_in);
						for (int row_bank = 0; row_bank < AXIS_BANK_COUNT; row_bank++) begin
							for (int col_bank = 0; col_bank < AXIS_BANK_COUNT; col_bank++) begin
								tap_y[row_bank][col_bank] = TAP_WIDTH'(expected_tap_y[row_bank][col_bank]);
								tap_x[row_bank][col_bank] = TAP_WIDTH'(expected_tap_x[row_bank][col_bank]);
							end
						end
						@(posedge clk);
						#1;

						for (int row_bank = 0; row_bank < AXIS_BANK_COUNT; row_bank++) begin
							for (int col_bank = 0; col_bank < AXIS_BANK_COUNT; col_bank++) begin
								if (!expected_valid[row_bank][col_bank])
									continue;
								check_count++;
								if ($isunknown(weight_code[row_bank][col_bank])
								    || int'(weight_code[row_bank][col_bank]) != expected_weight[row_bank][col_bank]) begin
									error_count++;
									$display("MISMATCH out_channel=%0d in_channel=%0d in_y=%0d in_x=%0d bank=(%0d,%0d) tap_y=%0d tap_x=%0d: expected=%0d actual=%0d",
									         channel_out, channel_in, coord_y, coord_x, row_bank, col_bank,
									         expected_tap_y[row_bank][col_bank], expected_tap_x[row_bank][col_bank],
									         expected_weight[row_bank][col_bank], weight_code[row_bank][col_bank]);
								end
							end
						end
					end
				end
			end
		end
		$fclose(ref_fd);

		$display("WEIGHT_FILE=%s", WEIGHT_FILE);
		$display("IN_CHANNEL_WIDTH=%0d IN_CHANNELS=%0d OUT_CHANNELS=%0d KERNEL_SIZE=%0d STRIDE=%0d PADDING=%0d OUT_ROWS=%0d OUT_COLS=%0d Y_WIDTH=%0d X_WIDTH=%0d WEIGHT_WIDTH=%0d: check_count=%0d error_count=%0d %s",
		         IN_CHANNEL_WIDTH, IN_CHANNELS, OUT_CHANNELS, KERNEL_SIZE, STRIDE, PADDING, OUT_ROWS, OUT_COLS,
		         Y_WIDTH, X_WIDTH, WEIGHT_WIDTH, check_count, error_count, (error_count == 0) ? "ALL PASS" : "FAIL");
		$finish;
	end

endmodule
