`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: tb_candidate_grid
// Description:
//   CandidateGrid 窮舉比對:out_channel 跑 0~OUT_CHANNELS-1,in_y、in_x 各從 0 跑到 2^寬度-1,
//   跟 scripts/gen_candidate_grid_ref.py 用訓練端 _axis_candidates 算出的答案逐個 bank 比對。
//   valid 一律要相同;valid=1 的 bank 再比 out_y、out_x、tap_y、tap_x、bank_addr。
//   參數用 xelab -generic_top 帶入,答案檔目錄用 xsim -testplusarg REF_DIR=<目錄> 帶入,
//   檔名照參數組出來,規則跟 gen_candidate_grid_ref.py 的 ref_file_name 相同。
//   純組合邏輯,只用一個 initial 流程:設定輸入、等 #1、比對。
//////////////////////////////////////////////////////////////////////////////////

module tb_candidate_grid;

	// 預設值是訓練端 conv1(configs/conv/baseline.yaml)
	parameter integer KERNEL_SIZE  = 3;
	parameter integer STRIDE       = 2;
	parameter integer PADDING      = 1;
	parameter integer OUT_ROWS     = 17;
	parameter integer OUT_COLS     = 17;
	parameter integer OUT_CHANNELS = 8;
	parameter integer Y_WIDTH      = 6;
	parameter integer X_WIDTH      = 6;

	// 跟 CandidateGrid 的 localparam 同一套公式,port 位寬要對上才能接
	localparam integer AXIS_BANK_COUNT   = (KERNEL_SIZE + STRIDE - 1) / STRIDE;
	localparam integer ROW_SLOTS         = (OUT_ROWS + AXIS_BANK_COUNT - 1) / AXIS_BANK_COUNT;
	localparam integer COL_SLOTS         = (OUT_COLS + AXIS_BANK_COUNT - 1) / AXIS_BANK_COUNT;
	localparam integer BANK_DEPTH        = OUT_CHANNELS * ROW_SLOTS * COL_SLOTS;
	localparam integer BANK_ADDR_WIDTH   = (BANK_DEPTH > 1) ? $clog2(BANK_DEPTH) : 1;
	localparam integer OUT_CHANNEL_WIDTH = (OUT_CHANNELS > 1) ? $clog2(OUT_CHANNELS) : 1;
	localparam integer OUT_Y_WIDTH       = (OUT_ROWS > 1) ? $clog2(OUT_ROWS) : 1;
	localparam integer OUT_X_WIDTH       = (OUT_COLS > 1) ? $clog2(OUT_COLS) : 1;
	localparam integer TAP_WIDTH         = (KERNEL_SIZE > 1) ? $clog2(KERNEL_SIZE) : 1;
	localparam integer IN_Y_COUNT        = 2 ** Y_WIDTH;
	localparam integer IN_X_COUNT        = 2 ** X_WIDTH;

	logic [Y_WIDTH-1:0]           in_y;
	logic [X_WIDTH-1:0]           in_x;
	logic [OUT_CHANNEL_WIDTH-1:0] out_channel;
	logic                         valid     [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1];
	logic [BANK_ADDR_WIDTH-1:0]   bank_addr [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1];
	logic [OUT_Y_WIDTH-1:0]       out_y     [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1];
	logic [OUT_X_WIDTH-1:0]       out_x     [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1];
	logic [TAP_WIDTH-1:0]         tap_y     [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1];
	logic [TAP_WIDTH-1:0]         tap_x     [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1];

	CandidateGrid #(
		.X_WIDTH     (X_WIDTH),
		.Y_WIDTH     (Y_WIDTH),
		.OUT_CHANNELS(OUT_CHANNELS),
		.OUT_ROWS    (OUT_ROWS),
		.OUT_COLS    (OUT_COLS),
		.KERNEL_SIZE (KERNEL_SIZE),
		.STRIDE      (STRIDE),
		.PADDING     (PADDING)
	) dut (
		.in_y       (in_y),
		.in_x       (in_x),
		.out_channel(out_channel),
		.valid      (valid),
		.bank_addr  (bank_addr),
		.out_y      (out_y),
		.out_x      (out_x),
		.tap_y      (tap_y),
		.tap_x      (tap_x)
	);

	string ref_dir;
	string ref_path;
	int    ref_fd;
	int    check_count;
	int    error_count;

	// 比對一個欄位,不一致就印出輸入、bank、欄位名稱、預期值、實際值
	task automatic check_field(input int channel, input int coord_y, input int coord_x,
	                           input int row_bank, input int col_bank, input string field_name,
	                           input int expected, input int actual);
		check_count++;
		if (expected != actual) begin
			error_count++;
			$display("MISMATCH out_channel=%0d in_y=%0d in_x=%0d bank=(%0d,%0d) %s: expected=%0d actual=%0d",
			         channel, coord_y, coord_x, row_bank, col_bank, field_name, expected, actual);
		end
	endtask

	initial begin
		int expected_channel;
		int expected_y;
		int expected_x;
		int expected_valid;
		int expected_out_y;
		int expected_out_x;
		int expected_tap_y;
		int expected_tap_x;
		int expected_bank_addr;
		int scan_count;

		check_count = 0;
		error_count = 0;

		if (!$value$plusargs("REF_DIR=%s", ref_dir))
			$fatal(1, "缺少 -testplusarg REF_DIR=<答案檔目錄>");
		ref_path = $sformatf("%s/candidate_grid_K%0d_S%0d_P%0d_R%0d_C%0d_OC%0d_Y%0d_X%0d.txt",
		                     ref_dir, KERNEL_SIZE, STRIDE, PADDING, OUT_ROWS, OUT_COLS, OUT_CHANNELS,
		                     Y_WIDTH, X_WIDTH);
		ref_fd = $fopen(ref_path, "r");
		if (ref_fd == 0)
			$fatal(1, "打不開答案檔 %s", ref_path);

		for (int channel = 0; channel < OUT_CHANNELS; channel++) begin
			for (int coord_y = 0; coord_y < IN_Y_COUNT; coord_y++) begin
				for (int coord_x = 0; coord_x < IN_X_COUNT; coord_x++) begin
					out_channel = OUT_CHANNEL_WIDTH'(channel);
					in_y        = Y_WIDTH'(coord_y);
					in_x        = X_WIDTH'(coord_x);
					#1;

					scan_count = $fscanf(ref_fd, "%d %d %d", expected_channel, expected_y, expected_x);
					if (scan_count != 3 || expected_channel != channel || expected_y != coord_y || expected_x != coord_x)
						$fatal(1, "答案檔格式不對:要 out_channel=%0d in_y=%0d in_x=%0d,讀到 %0d %0d %0d",
						       channel, coord_y, coord_x, expected_channel, expected_y, expected_x);

					for (int row_bank = 0; row_bank < AXIS_BANK_COUNT; row_bank++) begin
						for (int col_bank = 0; col_bank < AXIS_BANK_COUNT; col_bank++) begin
							scan_count = $fscanf(ref_fd, "%d %d %d %d %d %d", expected_valid, expected_out_y,
							                     expected_out_x, expected_tap_y, expected_tap_x, expected_bank_addr);
							if (scan_count != 6)
								$fatal(1, "答案檔 out_channel=%0d in_y=%0d in_x=%0d bank=(%0d,%0d) 欄位不足",
								       channel, coord_y, coord_x, row_bank, col_bank);

							check_field(channel, coord_y, coord_x, row_bank, col_bank, "valid",
							            expected_valid, int'(valid[row_bank][col_bank]));
							if (expected_valid) begin
								check_field(channel, coord_y, coord_x, row_bank, col_bank, "out_y",
								            expected_out_y, int'(out_y[row_bank][col_bank]));
								check_field(channel, coord_y, coord_x, row_bank, col_bank, "out_x",
								            expected_out_x, int'(out_x[row_bank][col_bank]));
								check_field(channel, coord_y, coord_x, row_bank, col_bank, "tap_y",
								            expected_tap_y, int'(tap_y[row_bank][col_bank]));
								check_field(channel, coord_y, coord_x, row_bank, col_bank, "tap_x",
								            expected_tap_x, int'(tap_x[row_bank][col_bank]));
								check_field(channel, coord_y, coord_x, row_bank, col_bank, "bank_addr",
								            expected_bank_addr, int'(bank_addr[row_bank][col_bank]));
							end
						end
					end
				end
			end
		end
		$fclose(ref_fd);

		$display("KERNEL_SIZE=%0d STRIDE=%0d PADDING=%0d OUT_ROWS=%0d OUT_COLS=%0d OUT_CHANNELS=%0d Y_WIDTH=%0d X_WIDTH=%0d: check_count=%0d error_count=%0d %s",
		         KERNEL_SIZE, STRIDE, PADDING, OUT_ROWS, OUT_COLS, OUT_CHANNELS, Y_WIDTH, X_WIDTH,
		         check_count, error_count, (error_count == 0) ? "ALL PASS" : "FAIL");
		$finish;
	end

endmodule
