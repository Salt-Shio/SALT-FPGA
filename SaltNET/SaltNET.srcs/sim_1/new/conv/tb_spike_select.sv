`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: tb_spike_select
// Description:
//   CandidateGrid + SpikeSelect 比對,答案由 scripts/gen_spike_select_ref.py 用訓練端 _axis_candidates 的候選、
//   神經元編號的順序產生。
//   SpikeSelect 的 out_y、out_x、top_row_bank、left_col_bank 接 RTL 的 CandidateGrid(依事件座標算),
//   一起測到兩個模組的 bank 編號規則接得起來;pending 由答案檔給。
//   每個 case:
//     先比 CandidateGrid:top_row_bank、left_col_bank、每個 bank 的 valid,valid=1 的 bank 再比 out_y、out_x。
//     再照預期順序一步一步比 SpikeSelect:
//       還有要送的:found=1,selected 只有預期那個 bank 是 1,selected_y、selected_x 是那個 bank 的座標;
//       比完把預期那個 bank 的 pending 清掉(不用 DUT 的 selected 清,錯誤不會一路傳下去)。
//       全部送完:found=0,selected 全 0。
//   參數用 xelab -generic_top 帶入,答案檔目錄用 xsim -testplusarg REF_DIR=<目錄> 帶入,
//   檔名照參數組出來,規則跟 gen_spike_select_ref.py 的 ref_file_name 相同。
//   純組合邏輯,只用一個 initial 流程:設定輸入、等 #1、比對。
//////////////////////////////////////////////////////////////////////////////////

module tb_spike_select;

	// 預設值是訓練端 conv1(configs/conv/baseline.yaml)
	parameter integer KERNEL_SIZE = 3;
	parameter integer STRIDE      = 2;
	parameter integer PADDING     = 1;
	parameter integer OUT_ROWS    = 17;
	parameter integer OUT_COLS    = 17;
	parameter integer Y_WIDTH     = 6;
	parameter integer X_WIDTH     = 6;

	// out_channel 不影響 SpikeSelect 要的輸出,CandidateGrid 只開 1 個 channel
	localparam integer OUT_CHANNELS = 1;

	// 跟 CandidateGrid、SpikeSelect 的 localparam 同一套公式,port 位寬要對上才能接
	localparam integer AXIS_BANK_COUNT   = (KERNEL_SIZE + STRIDE - 1) / STRIDE;
	localparam integer BANK_COUNT        = AXIS_BANK_COUNT * AXIS_BANK_COUNT;
	localparam integer BANK_INDEX_WIDTH  = (AXIS_BANK_COUNT > 1) ? $clog2(AXIS_BANK_COUNT) : 1;
	localparam integer ROW_SLOTS         = (OUT_ROWS + AXIS_BANK_COUNT - 1) / AXIS_BANK_COUNT;
	localparam integer COL_SLOTS         = (OUT_COLS + AXIS_BANK_COUNT - 1) / AXIS_BANK_COUNT;
	localparam integer BANK_DEPTH        = OUT_CHANNELS * ROW_SLOTS * COL_SLOTS;
	localparam integer BANK_ADDR_WIDTH   = (BANK_DEPTH > 1) ? $clog2(BANK_DEPTH) : 1;
	localparam integer OUT_CHANNEL_WIDTH = 1;
	localparam integer OUT_Y_WIDTH       = (OUT_ROWS > 1) ? $clog2(OUT_ROWS) : 1;
	localparam integer OUT_X_WIDTH       = (OUT_COLS > 1) ? $clog2(OUT_COLS) : 1;
	localparam integer TAP_WIDTH         = (KERNEL_SIZE > 1) ? $clog2(KERNEL_SIZE) : 1;

	// CandidateGrid
	logic [Y_WIDTH-1:0]           in_y;
	logic [X_WIDTH-1:0]           in_x;
	logic [OUT_CHANNEL_WIDTH-1:0] out_channel;
	logic                         grid_valid     [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1];
	logic [BANK_ADDR_WIDTH-1:0]   grid_bank_addr [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1];
	logic [OUT_Y_WIDTH-1:0]       grid_out_y     [0:AXIS_BANK_COUNT-1];
	logic [OUT_X_WIDTH-1:0]       grid_out_x     [0:AXIS_BANK_COUNT-1];
	logic [TAP_WIDTH-1:0]         grid_tap_y     [0:AXIS_BANK_COUNT-1];
	logic [TAP_WIDTH-1:0]         grid_tap_x     [0:AXIS_BANK_COUNT-1];
	logic [BANK_INDEX_WIDTH-1:0]  top_row_bank;
	logic [BANK_INDEX_WIDTH-1:0]  left_col_bank;

	// SpikeSelect
	logic                         pending        [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1];
	logic                         found;
	logic                         selected       [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1];
	logic [OUT_Y_WIDTH-1:0]       selected_y;
	logic [OUT_X_WIDTH-1:0]       selected_x;

	CandidateGrid #(
		.X_WIDTH     (X_WIDTH),
		.Y_WIDTH     (Y_WIDTH),
		.OUT_CHANNELS(OUT_CHANNELS),
		.OUT_ROWS    (OUT_ROWS),
		.OUT_COLS    (OUT_COLS),
		.KERNEL_SIZE (KERNEL_SIZE),
		.STRIDE      (STRIDE),
		.PADDING     (PADDING)
	) grid (
		.in_y         (in_y),
		.in_x         (in_x),
		.out_channel  (out_channel),
		.valid        (grid_valid),
		.bank_addr    (grid_bank_addr),
		.out_y        (grid_out_y),
		.out_x        (grid_out_x),
		.tap_y        (grid_tap_y),
		.tap_x        (grid_tap_x),
		.top_row_bank (top_row_bank),
		.left_col_bank(left_col_bank)
	);

	SpikeSelect #(
		.OUT_ROWS   (OUT_ROWS),
		.OUT_COLS   (OUT_COLS),
		.KERNEL_SIZE(KERNEL_SIZE),
		.STRIDE     (STRIDE)
	) dut (
		.pending      (pending),
		.out_y        (grid_out_y),
		.out_x        (grid_out_x),
		.top_row_bank (top_row_bank),
		.left_col_bank(left_col_bank),
		.found        (found),
		.selected     (selected),
		.selected_y   (selected_y),
		.selected_x   (selected_x)
	);

	string ref_dir;
	string ref_path;
	int    ref_fd;
	int    case_count;
	int    step_count;
	int    check_count;
	int    error_count;

	// 比對一個欄位,不一致就印出 case 的事件座標、第幾步、欄位名稱、預期值、實際值;
	// step<0 是 CandidateGrid 的欄位,不印 step
	task automatic check_field(input int coord_y, input int coord_x, input int step, input string field_name,
	                           input int expected, input int actual);
		check_count++;
		if (expected != actual) begin
			error_count++;
			if (step < 0)
				$display("MISMATCH in_y=%0d in_x=%0d grid %s: expected=%0d actual=%0d",
				         coord_y, coord_x, field_name, expected, actual);
			else
				$display("MISMATCH in_y=%0d in_x=%0d step=%0d %s: expected=%0d actual=%0d",
				         coord_y, coord_x, step, field_name, expected, actual);
		end
	endtask

	initial begin
		string kind;
		int    coord_y;
		int    coord_x;
		int    expected_top_row;
		int    expected_left_col;
		int    valid_value;
		int    pending_value;
		int    coord_value_y;
		int    coord_value_x;
		int    expected_valid [0:BANK_COUNT-1];
		int    expected_out_y [0:BANK_COUNT-1];
		int    expected_out_x [0:BANK_COUNT-1];
		int    order_count;
		int    order [0:BANK_COUNT-1];
		int    expected_bank;
		int    expected_case_count;
		int    expected_step_count;
		int    scan_count;
		bit    reached_end;

		case_count  = 0;
		step_count  = 0;
		check_count = 0;
		error_count = 0;
		reached_end = 0;
		out_channel = '0;

		if (!$value$plusargs("REF_DIR=%s", ref_dir))
			$fatal(1, "缺少 -testplusarg REF_DIR=<答案檔目錄>");
		ref_path = $sformatf("%s/spike_select_K%0d_S%0d_P%0d_R%0d_C%0d_Y%0d_X%0d.txt",
		                     ref_dir, KERNEL_SIZE, STRIDE, PADDING, OUT_ROWS, OUT_COLS, Y_WIDTH, X_WIDTH);
		ref_fd = $fopen(ref_path, "r");
		if (ref_fd == 0)
			$fatal(1, "打不開答案檔 %s", ref_path);

		while (!reached_end) begin
			scan_count = $fscanf(ref_fd, "%s", kind);
			if (scan_count != 1)
				$fatal(1, "答案檔在第 %0d 個 case 之後結束,沒有 end 行", case_count);

			if (kind == "end") begin
				scan_count = $fscanf(ref_fd, "%d %d", expected_case_count, expected_step_count);
				if (scan_count != 2)
					$fatal(1, "end 行欄位不足");
				if (expected_case_count != case_count || expected_step_count != step_count)
					$fatal(1, "case 數或步數對不上:答案檔 %0d/%0d,實際跑了 %0d/%0d",
					       expected_case_count, expected_step_count, case_count, step_count);
				reached_end = 1;
			end else if (kind == "case") begin
				scan_count = $fscanf(ref_fd, "%d %d %d %d", coord_y, coord_x, expected_top_row, expected_left_col);
				if (scan_count != 4)
					$fatal(1, "答案檔第 %0d 個 case 開頭欄位不足", case_count);
				in_y = Y_WIDTH'(coord_y);
				in_x = X_WIDTH'(coord_x);

				for (int bank = 0; bank < BANK_COUNT; bank++) begin
					scan_count = $fscanf(ref_fd, "%d %d %d %d", valid_value, pending_value, coord_value_y, coord_value_x);
					if (scan_count != 4)
						$fatal(1, "答案檔 in_y=%0d in_x=%0d bank %0d 欄位不足", coord_y, coord_x, bank);
					if (pending_value && !valid_value)
						$fatal(1, "答案檔 in_y=%0d in_x=%0d bank %0d:pending=1 但 valid=0", coord_y, coord_x, bank);
					expected_valid[bank] = valid_value;
					expected_out_y[bank] = coord_value_y;
					expected_out_x[bank] = coord_value_x;
					pending[bank / AXIS_BANK_COUNT][bank % AXIS_BANK_COUNT] = pending_value[0];
				end

				scan_count = $fscanf(ref_fd, "%d", order_count);
				if (scan_count != 1 || order_count < 0 || order_count > BANK_COUNT)
					$fatal(1, "答案檔 in_y=%0d in_x=%0d 的送出筆數不對", coord_y, coord_x);
				for (int step = 0; step < order_count; step++) begin
					scan_count = $fscanf(ref_fd, "%d", order[step]);
					if (scan_count != 1 || order[step] < 0 || order[step] >= BANK_COUNT)
						$fatal(1, "答案檔 in_y=%0d in_x=%0d 第 %0d 個送出的 bank 不對", coord_y, coord_x, step);
				end

				// CandidateGrid:窗左上角、每個 bank 的 valid,合法的 bank 再比座標
				#1;
				check_field(coord_y, coord_x, -1, "top_row_bank", expected_top_row, int'(top_row_bank));
				check_field(coord_y, coord_x, -1, "left_col_bank", expected_left_col, int'(left_col_bank));
				for (int bank = 0; bank < BANK_COUNT; bank++) begin
					check_field(coord_y, coord_x, -1,
					            $sformatf("valid[%0d][%0d]", bank / AXIS_BANK_COUNT, bank % AXIS_BANK_COUNT),
					            expected_valid[bank], int'(grid_valid[bank / AXIS_BANK_COUNT][bank % AXIS_BANK_COUNT]));
					if (expected_valid[bank]) begin
						check_field(coord_y, coord_x, -1,
						            $sformatf("out_y[%0d][%0d]", bank / AXIS_BANK_COUNT, bank % AXIS_BANK_COUNT),
						            expected_out_y[bank], int'(grid_out_y[bank / AXIS_BANK_COUNT]));
						check_field(coord_y, coord_x, -1,
						            $sformatf("out_x[%0d][%0d]", bank / AXIS_BANK_COUNT, bank % AXIS_BANK_COUNT),
						            expected_out_x[bank], int'(grid_out_x[bank % AXIS_BANK_COUNT]));
					end
				end

				// SpikeSelect:照預期順序一步一步比,每步清掉預期的那個 bank
				for (int step = 0; step <= order_count; step++) begin
					#1;
					if (step < order_count) begin
						expected_bank = order[step];
						check_field(coord_y, coord_x, step, "found", 1, int'(found));
						check_field(coord_y, coord_x, step, "selected_y", expected_out_y[expected_bank], int'(selected_y));
						check_field(coord_y, coord_x, step, "selected_x", expected_out_x[expected_bank], int'(selected_x));
					end else begin
						expected_bank = -1;
						check_field(coord_y, coord_x, step, "found", 0, int'(found));
					end
					for (int bank = 0; bank < BANK_COUNT; bank++) begin
						check_field(coord_y, coord_x, step, $sformatf("selected[%0d][%0d]", bank / AXIS_BANK_COUNT,
						                                              bank % AXIS_BANK_COUNT),
						            int'(bank == expected_bank),
						            int'(selected[bank / AXIS_BANK_COUNT][bank % AXIS_BANK_COUNT]));
					end
					if (step < order_count) begin
						pending[expected_bank / AXIS_BANK_COUNT][expected_bank % AXIS_BANK_COUNT] = 1'b0;
						step_count++;
					end
				end
				case_count++;
			end else begin
				$fatal(1, "答案檔有不認得的指令 %s", kind);
			end
		end
		$fclose(ref_fd);

		$display("KERNEL_SIZE=%0d STRIDE=%0d PADDING=%0d OUT_ROWS=%0d OUT_COLS=%0d Y_WIDTH=%0d X_WIDTH=%0d: case_count=%0d step_count=%0d check_count=%0d error_count=%0d %s",
		         KERNEL_SIZE, STRIDE, PADDING, OUT_ROWS, OUT_COLS, Y_WIDTH, X_WIDTH,
		         case_count, step_count, check_count, error_count, (error_count == 0) ? "ALL PASS" : "FAIL");
		$finish;
	end

endmodule
