`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: tb_neuron_memory
// Description:
//   CandidateGrid + NeuronMemory 一起驗證:每顆神經元讀出的 (V̂, t_last) 要等於最後寫進去的值,清除後要回到 0。
//   讀寫位址都由 CandidateGrid 算,跟實際電路同一條路;上一拍的 valid、bank_addr 存起來當這一拍的寫入位址。
//   答案是 scripts/gen_neuron_memory_ref.py 用訓練端的候選規則排出的每一拍操作跟預期讀出值,格式見那支腳本。
//   reset 行:
//     negedge 拉低 rst_n,hold_cycles 拍後在 negedge 放開;每個 posedge 之前 clearing 都要是 1,
//     放開後剛好 clear_cycles 個 posedge 之前是 1,之後變 0。
//     整段期間每個 bank 都送外部寫入(全 1、位址倒著走),清除要忽略它們;沒忽略的話,之後的全部讀一遍會讀到非 0。
//   cycle 行:
//     negedge:寫 port 接上一拍存的 valid、bank_addr 跟這行的寫入值;CandidateGrid 輸入這一步的 (in_y, in_x, o_c)
//     negedge 後 #1:CandidateGrid 算完,read_enable 接 valid、read_addr 接 bank_addr,比對 valid 跟答案
//     posedge 後 #1:比對 check=1 的 bank 讀出值
//   參數用 xelab -generic_top 帶入,答案檔目錄用 xsim -testplusarg REF_DIR=<目錄> 帶入,
//   答案檔名照參數組出來,規則跟 gen_neuron_memory_ref.py 的 ref_file_name 相同。
//////////////////////////////////////////////////////////////////////////////////

module tb_neuron_memory;

	// 預設值是訓練端 conv1(configs/conv/baseline.yaml)繞回版
	parameter integer KERNEL_SIZE    = 3;
	parameter integer STRIDE         = 2;
	parameter integer PADDING        = 1;
	parameter integer OUT_ROWS       = 17;
	parameter integer OUT_COLS       = 17;
	parameter integer OUT_CHANNELS   = 8;
	parameter integer Y_WIDTH        = 6;
	parameter integer X_WIDTH        = 6;
	parameter integer MEMBRANE_WIDTH = 12;
	parameter integer TIME_WIDTH     = 16;

	// 跟 CandidateGrid、NeuronMemory 的 localparam 同一套公式,port 位寬要對上才能接
	localparam integer AXIS_BANK_COUNT   = (KERNEL_SIZE + STRIDE - 1) / STRIDE;
	localparam integer ROW_SLOTS         = (OUT_ROWS + AXIS_BANK_COUNT - 1) / AXIS_BANK_COUNT;
	localparam integer COL_SLOTS         = (OUT_COLS + AXIS_BANK_COUNT - 1) / AXIS_BANK_COUNT;
	localparam integer BANK_DEPTH        = OUT_CHANNELS * ROW_SLOTS * COL_SLOTS;
	localparam integer BANK_ADDR_WIDTH   = (BANK_DEPTH > 1) ? $clog2(BANK_DEPTH) : 1;
	localparam integer OUT_CHANNEL_WIDTH = (OUT_CHANNELS > 1) ? $clog2(OUT_CHANNELS) : 1;
	localparam integer OUT_Y_WIDTH       = (OUT_ROWS > 1) ? $clog2(OUT_ROWS) : 1;
	localparam integer OUT_X_WIDTH       = (OUT_COLS > 1) ? $clog2(OUT_COLS) : 1;
	localparam integer TAP_WIDTH         = (KERNEL_SIZE > 1) ? $clog2(KERNEL_SIZE) : 1;

	logic clk = 1'b0;
	always #5 clk = ~clk;

	logic rst_n;
	logic clearing;

	// CandidateGrid
	logic        [Y_WIDTH-1:0]           in_y;
	logic        [X_WIDTH-1:0]           in_x;
	logic        [OUT_CHANNEL_WIDTH-1:0] out_channel;
	logic                                grid_valid      [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1];
	logic        [BANK_ADDR_WIDTH-1:0]   grid_bank_addr  [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1];
	logic        [OUT_Y_WIDTH-1:0]       grid_out_y      [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1];
	logic        [OUT_X_WIDTH-1:0]       grid_out_x      [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1];
	logic        [TAP_WIDTH-1:0]         grid_tap_y      [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1];
	logic        [TAP_WIDTH-1:0]         grid_tap_x      [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1];

	// NeuronMemory
	logic                                read_enable     [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1];
	logic        [BANK_ADDR_WIDTH-1:0]   read_addr       [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1];
	logic signed [MEMBRANE_WIDTH-1:0]    read_membrane   [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1];
	logic        [TIME_WIDTH-1:0]        read_last_time  [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1];
	logic                                write_enable    [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1];
	logic        [BANK_ADDR_WIDTH-1:0]   write_addr      [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1];
	logic signed [MEMBRANE_WIDTH-1:0]    write_membrane  [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1];
	logic        [TIME_WIDTH-1:0]        write_last_time [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1];

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
		.in_y       (in_y),
		.in_x       (in_x),
		.out_channel(out_channel),
		.valid      (grid_valid),
		.bank_addr  (grid_bank_addr),
		.out_y      (grid_out_y),
		.out_x      (grid_out_x),
		.tap_y      (grid_tap_y),
		.tap_x      (grid_tap_x)
	);

	NeuronMemory #(
		.OUT_CHANNELS  (OUT_CHANNELS),
		.OUT_ROWS      (OUT_ROWS),
		.OUT_COLS      (OUT_COLS),
		.KERNEL_SIZE   (KERNEL_SIZE),
		.STRIDE        (STRIDE),
		.MEMBRANE_WIDTH(MEMBRANE_WIDTH),
		.TIME_WIDTH    (TIME_WIDTH)
	) memory (
		.clk            (clk),
		.rst_n          (rst_n),
		.clearing       (clearing),
		.read_enable    (read_enable),
		.read_addr      (read_addr),
		.read_membrane  (read_membrane),
		.read_last_time (read_last_time),
		.write_enable   (write_enable),
		.write_addr     (write_addr),
		.write_membrane (write_membrane),
		.write_last_time(write_last_time)
	);

	string ref_dir;
	string ref_path;
	int    ref_fd;
	int    line_number;
	int    cycle_count;
	int    check_count;
	int    error_count;

	// 上一拍讀的那一步,這一拍寫回用
	logic                       previous_did_read;
	logic                       previous_valid [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1];
	logic [BANK_ADDR_WIDTH-1:0] previous_addr  [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1];

	task automatic disable_all_ports();
		for (int row_bank = 0; row_bank < AXIS_BANK_COUNT; row_bank++) begin
			for (int col_bank = 0; col_bank < AXIS_BANK_COUNT; col_bank++) begin
				read_enable[row_bank][col_bank]     = 1'b0;
				read_addr[row_bank][col_bank]       = '0;
				write_enable[row_bank][col_bank]    = 1'b0;
				write_addr[row_bank][col_bank]      = '0;
				write_membrane[row_bank][col_bank]  = '0;
				write_last_time[row_bank][col_bank] = '0;
			end
		end
	endtask

	// 清除期間每個 bank 都送外部寫入(全 1),清除要忽略它們
	task automatic drive_ignored_writes(int unsigned addr);
		for (int row_bank = 0; row_bank < AXIS_BANK_COUNT; row_bank++) begin
			for (int col_bank = 0; col_bank < AXIS_BANK_COUNT; col_bank++) begin
				read_enable[row_bank][col_bank]     = 1'b0;
				write_enable[row_bank][col_bank]    = 1'b1;
				write_addr[row_bank][col_bank]      = BANK_ADDR_WIDTH'(addr);
				write_membrane[row_bank][col_bank]  = '1;
				write_last_time[row_bank][col_bank] = '1;
			end
		end
	endtask

	task automatic check_clearing(logic expected, string when);
		if (clearing !== expected) begin
			error_count++;
			$display("MISMATCH line=%0d clearing %s: expected=%0d actual=%0d", line_number, when, expected, clearing);
		end
	endtask

	task automatic run_reset(int hold_cycles, int clear_cycles);
		@(negedge clk);
		rst_n = 1'b0;
		drive_ignored_writes(BANK_DEPTH - 1);
		for (int cycle = 0; cycle < hold_cycles; cycle++) begin
			#1;
			check_clearing(1'b1, $sformatf("during reset cycle %0d", cycle));
			@(negedge clk);
		end
		rst_n = 1'b1;
		for (int cycle = 0; cycle < clear_cycles; cycle++) begin
			// 位址倒著走,跟清除的位址錯開
			drive_ignored_writes(BANK_DEPTH - 1 - (cycle % BANK_DEPTH));
			#1;
			check_clearing(1'b1, $sformatf("before clear posedge %0d", cycle + 1));
			@(negedge clk);
		end
		#1;
		check_clearing(1'b0, "after clear");
		disable_all_ports();
		previous_did_read = 1'b0;
	endtask

	initial begin
		string kind;
		int    scan_count;
		int    hold_cycles;
		int    clear_cycles;
		int    phase;
		int    do_read;
		int    step_y;
		int    step_x;
		int    step_channel;
		int    do_write;
		int    expected_cycle_count;
		int    expected_check_count;
		int    expected_valid          [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1];
		int    expected_check          [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1];
		int    expected_membrane       [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1];
		int    expected_last_time      [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1];
		int    written_membrane        [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1];
		int    written_last_time       [0:AXIS_BANK_COUNT-1][0:AXIS_BANK_COUNT-1];

		line_number = 0;
		cycle_count = 0;
		check_count = 0;
		error_count = 0;
		rst_n = 1'b1;
		in_y = '0;
		in_x = '0;
		out_channel = '0;
		previous_did_read = 1'b0;
		disable_all_ports();

		if (!$value$plusargs("REF_DIR=%s", ref_dir))
			$fatal(1, "缺少 -testplusarg REF_DIR=<答案檔目錄>");
		ref_path = $sformatf("%s/neuron_memory_K%0d_S%0d_P%0d_R%0d_C%0d_OC%0d_Y%0d_X%0d_W%0d_T%0d.txt",
		                     ref_dir, KERNEL_SIZE, STRIDE, PADDING, OUT_ROWS, OUT_COLS, OUT_CHANNELS,
		                     Y_WIDTH, X_WIDTH, MEMBRANE_WIDTH, TIME_WIDTH);
		ref_fd = $fopen(ref_path, "r");
		if (ref_fd == 0)
			$fatal(1, "打不開答案檔 %s", ref_path);

		forever begin
			line_number++;
			scan_count = $fscanf(ref_fd, "%s", kind);
			if (scan_count != 1)
				$fatal(1, "答案檔第 %0d 行讀不到種類欄位,檔案沒有 end 行", line_number);

			if (kind == "end") begin
				scan_count = $fscanf(ref_fd, "%d %d", expected_cycle_count, expected_check_count);
				if (scan_count != 2)
					$fatal(1, "答案檔第 %0d 行 end 欄位不足", line_number);
				break;
			end

			if (kind == "reset") begin
				scan_count = $fscanf(ref_fd, "%d %d", hold_cycles, clear_cycles);
				if (scan_count != 2)
					$fatal(1, "答案檔第 %0d 行 reset 欄位不足", line_number);
				run_reset(hold_cycles, clear_cycles);
				continue;
			end

			if (kind != "cycle")
				$fatal(1, "答案檔第 %0d 行種類 '%s' 不認得", line_number, kind);

			scan_count = $fscanf(ref_fd, "%d %d %d %d %d %d", phase, do_read, step_y, step_x, step_channel, do_write);
			if (scan_count != 6)
				$fatal(1, "答案檔第 %0d 行 cycle 欄位不足", line_number);
			for (int row_bank = 0; row_bank < AXIS_BANK_COUNT; row_bank++) begin
				for (int col_bank = 0; col_bank < AXIS_BANK_COUNT; col_bank++) begin
					scan_count = $fscanf(ref_fd, "%d %d %d %d %d %d",
					                     expected_valid[row_bank][col_bank], expected_check[row_bank][col_bank],
					                     expected_membrane[row_bank][col_bank], expected_last_time[row_bank][col_bank],
					                     written_membrane[row_bank][col_bank], written_last_time[row_bank][col_bank]);
					if (scan_count != 6)
						$fatal(1, "答案檔第 %0d 行 bank=(%0d,%0d) 欄位不足", line_number, row_bank, col_bank);
				end
			end
			if (do_write && !previous_did_read)
				$fatal(1, "答案檔第 %0d 行 do_write=1,但上一拍沒有讀", line_number);

			// negedge:寫 port 接上一拍的 valid、bank_addr,CandidateGrid 輸入這一步
			@(negedge clk);
			for (int row_bank = 0; row_bank < AXIS_BANK_COUNT; row_bank++) begin
				for (int col_bank = 0; col_bank < AXIS_BANK_COUNT; col_bank++) begin
					write_enable[row_bank][col_bank]    = do_write && previous_valid[row_bank][col_bank];
					write_addr[row_bank][col_bank]      = previous_addr[row_bank][col_bank];
					write_membrane[row_bank][col_bank]  = MEMBRANE_WIDTH'(written_membrane[row_bank][col_bank]);
					write_last_time[row_bank][col_bank] = TIME_WIDTH'(written_last_time[row_bank][col_bank]);
				end
			end
			if (do_read) begin
				in_y        = Y_WIDTH'(step_y);
				in_x        = X_WIDTH'(step_x);
				out_channel = OUT_CHANNEL_WIDTH'(step_channel);
			end

			// CandidateGrid 是組合邏輯,#1 後才算完
			#1;
			for (int row_bank = 0; row_bank < AXIS_BANK_COUNT; row_bank++) begin
				for (int col_bank = 0; col_bank < AXIS_BANK_COUNT; col_bank++) begin
					read_enable[row_bank][col_bank] = do_read && grid_valid[row_bank][col_bank];
					read_addr[row_bank][col_bank]   = grid_bank_addr[row_bank][col_bank];
					if (do_read && grid_valid[row_bank][col_bank] !== 1'(expected_valid[row_bank][col_bank])) begin
						error_count++;
						$display("MISMATCH line=%0d phase=%0d in_y=%0d in_x=%0d out_channel=%0d bank=(%0d,%0d) valid: expected=%0d actual=%0d",
						         line_number, phase, step_y, step_x, step_channel, row_bank, col_bank,
						         expected_valid[row_bank][col_bank], grid_valid[row_bank][col_bank]);
					end
				end
			end

			@(posedge clk);
			#1;
			for (int row_bank = 0; row_bank < AXIS_BANK_COUNT; row_bank++) begin
				for (int col_bank = 0; col_bank < AXIS_BANK_COUNT; col_bank++) begin
					if (!expected_check[row_bank][col_bank])
						continue;
					check_count++;
					if ($isunknown(read_membrane[row_bank][col_bank]) || $isunknown(read_last_time[row_bank][col_bank])
					    || int'(read_membrane[row_bank][col_bank]) != expected_membrane[row_bank][col_bank]
					    || int'(read_last_time[row_bank][col_bank]) != expected_last_time[row_bank][col_bank]) begin
						error_count++;
						$display("MISMATCH line=%0d phase=%0d do_read=%0d in_y=%0d in_x=%0d out_channel=%0d bank=(%0d,%0d) valid=%0d: expected=(%0d, %0d) actual=(%0d, %0d)",
						         line_number, phase, do_read, step_y, step_x, step_channel, row_bank, col_bank,
						         expected_valid[row_bank][col_bank], expected_membrane[row_bank][col_bank],
						         expected_last_time[row_bank][col_bank], read_membrane[row_bank][col_bank],
						         read_last_time[row_bank][col_bank]);
					end
				end
			end

			previous_did_read = do_read;
			for (int row_bank = 0; row_bank < AXIS_BANK_COUNT; row_bank++) begin
				for (int col_bank = 0; col_bank < AXIS_BANK_COUNT; col_bank++) begin
					previous_valid[row_bank][col_bank] = do_read && grid_valid[row_bank][col_bank];
					previous_addr[row_bank][col_bank]  = grid_bank_addr[row_bank][col_bank];
				end
			end
			cycle_count++;
		end
		$fclose(ref_fd);

		if (cycle_count != expected_cycle_count || check_count != expected_check_count) begin
			error_count++;
			$display("MISMATCH cycle_count=%0d check_count=%0d, end 行要 cycle_count=%0d check_count=%0d",
			         cycle_count, check_count, expected_cycle_count, expected_check_count);
		end

		$display("KERNEL_SIZE=%0d STRIDE=%0d PADDING=%0d OUT_ROWS=%0d OUT_COLS=%0d OUT_CHANNELS=%0d Y_WIDTH=%0d X_WIDTH=%0d MEMBRANE_WIDTH=%0d TIME_WIDTH=%0d: cycle_count=%0d check_count=%0d error_count=%0d %s",
		         KERNEL_SIZE, STRIDE, PADDING, OUT_ROWS, OUT_COLS, OUT_CHANNELS, Y_WIDTH, X_WIDTH, MEMBRANE_WIDTH,
		         TIME_WIDTH, cycle_count, check_count, error_count, (error_count == 0) ? "ALL PASS" : "FAIL");
		$finish;
	end

endmodule
