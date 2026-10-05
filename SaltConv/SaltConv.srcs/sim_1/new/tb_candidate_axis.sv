`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: tb_candidate_axis
// Description:
//   CandidateAxis 窮舉比對:in_coord 從 0 跑到 2^IN_COORD_WIDTH-1,
//   跟 scripts/gen_candidate_axis_ref.py 用訓練端 _axis_candidates 算出的答案逐個 bank 比對。
//   valid 一律要相同;valid=1 的 bank 再比 out_coord、bank_offset、tap。
//   參數用 xelab -generic_top 帶入,答案檔目錄用 xsim -testplusarg REF_DIR=<目錄> 帶入,
//   檔名照參數組出來,規則跟 gen_candidate_axis_ref.py 的 ref_file_name 相同。
//   純組合邏輯,只用一個 initial 流程:設定輸入、等 #1、比對。
//////////////////////////////////////////////////////////////////////////////////

module tb_candidate_axis;

	parameter integer KERNEL_SIZE    = 3;
	parameter integer STRIDE         = 1;
	parameter integer PADDING        = 1;
	parameter integer OUT_SIZE       = 64;
	parameter integer IN_COORD_WIDTH = 9;

	// 跟 CandidateAxis 的 localparam 同一套公式,port 位寬要對上才能接
	localparam integer BANK_COUNT        = (KERNEL_SIZE + STRIDE - 1) / STRIDE;
	localparam integer BANK_SLOTS        = (OUT_SIZE + BANK_COUNT - 1) / BANK_COUNT;
	localparam integer OUT_COORD_WIDTH   = (OUT_SIZE > 1) ? $clog2(OUT_SIZE) : 1;
	localparam integer BANK_OFFSET_WIDTH = (BANK_SLOTS > 1) ? $clog2(BANK_SLOTS) : 1;
	localparam integer TAP_WIDTH         = (KERNEL_SIZE > 1) ? $clog2(KERNEL_SIZE) : 1;
	localparam integer IN_COORD_COUNT    = 2 ** IN_COORD_WIDTH;

	logic [IN_COORD_WIDTH-1:0]    in_coord;
	logic                         valid       [0:BANK_COUNT-1];
	logic [OUT_COORD_WIDTH-1:0]   out_coord   [0:BANK_COUNT-1];
	logic [BANK_OFFSET_WIDTH-1:0] bank_offset [0:BANK_COUNT-1];
	logic [TAP_WIDTH-1:0]         tap         [0:BANK_COUNT-1];

	CandidateAxis #(
		.KERNEL_SIZE   (KERNEL_SIZE),
		.STRIDE        (STRIDE),
		.PADDING       (PADDING),
		.OUT_SIZE      (OUT_SIZE),
		.IN_COORD_WIDTH(IN_COORD_WIDTH)
	) dut (
		.in_coord   (in_coord),
		.valid      (valid),
		.out_coord  (out_coord),
		.bank_offset(bank_offset),
		.tap        (tap)
	);

	string ref_dir;
	string ref_path;
	int    ref_fd;
	int    check_count;
	int    error_count;

	// 比對一個欄位,不一致就印出 in_coord、bank、欄位名稱、預期值、實際值
	task automatic check_field(input int coord, input int bank, input string field_name,
	                           input int expected, input int actual);
		check_count++;
		if (expected != actual) begin
			error_count++;
			$display("MISMATCH in_coord=%0d bank=%0d %s: expected=%0d actual=%0d",
			         coord, bank, field_name, expected, actual);
		end
	endtask

	initial begin
		int expected_coord;
		int expected_valid;
		int expected_out_coord;
		int expected_bank_offset;
		int expected_tap;
		int scan_count;

		check_count = 0;
		error_count = 0;

		if (!$value$plusargs("REF_DIR=%s", ref_dir))
			$fatal(1, "缺少 -testplusarg REF_DIR=<答案檔目錄>");
		ref_path = $sformatf("%s/candidate_axis_K%0d_S%0d_P%0d_O%0d_W%0d.txt",
		                     ref_dir, KERNEL_SIZE, STRIDE, PADDING, OUT_SIZE, IN_COORD_WIDTH);
		ref_fd = $fopen(ref_path, "r");
		if (ref_fd == 0)
			$fatal(1, "打不開答案檔 %s", ref_path);

		for (int coord = 0; coord < IN_COORD_COUNT; coord++) begin
			in_coord = IN_COORD_WIDTH'(coord);
			#1;

			scan_count = $fscanf(ref_fd, "%d", expected_coord);
			if (scan_count != 1 || expected_coord != coord)
				$fatal(1, "答案檔第 %0d 行格式不對:讀到 in_coord=%0d", coord, expected_coord);

			for (int bank = 0; bank < BANK_COUNT; bank++) begin
				scan_count = $fscanf(ref_fd, "%d %d %d %d", expected_valid, expected_out_coord,
				                     expected_bank_offset, expected_tap);
				if (scan_count != 4)
					$fatal(1, "答案檔 in_coord=%0d bank=%0d 欄位不足", coord, bank);

				check_field(coord, bank, "valid", expected_valid, int'(valid[bank]));
				if (expected_valid) begin
					check_field(coord, bank, "out_coord", expected_out_coord, int'(out_coord[bank]));
					check_field(coord, bank, "bank_offset", expected_bank_offset, int'(bank_offset[bank]));
					check_field(coord, bank, "tap", expected_tap, int'(tap[bank]));
				end
			end
		end
		$fclose(ref_fd);

		$display("K=%0d S=%0d P=%0d OUT_SIZE=%0d IN_COORD_WIDTH=%0d: check_count=%0d error_count=%0d %s",
		         KERNEL_SIZE, STRIDE, PADDING, OUT_SIZE, IN_COORD_WIDTH, check_count, error_count,
		         (error_count == 0) ? "ALL PASS" : "FAIL");
		$finish;
	end

endmodule
