`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: tb_fc_spike_select
// Description:
//   FCSpikeSelect 比對(FC.md 第 4 節 ②③),答案由 scripts/fc/gen_fc_spike_select_ref.py 用訓練端
//   salt_core.stream.extract_output_events_fc 排出的送出順序產生。
//   每個 case 是第 y 列(row_base = y*n_col)、這一列還沒送的 bitmask,照預期順序一步一步比:
//     還有要送的:found=1,selected 只有預期那一行(i - row_base)是 1,selected_neuron = 預期的 i;
//     比完把預期那一行的 pending 清掉(不用 DUT 的 selected 清,錯誤不會一路傳下去)。
//     全部送完:found=0,selected 全 0。
//   參數用 xelab -generic_top 帶入,答案檔目錄用 xsim -testplusarg REF_DIR=<目錄> 帶入,
//   檔名照參數組出來,規則跟 gen_fc_spike_select_ref.py 的 ref_file_name 相同。
//   純組合邏輯,只用一個 initial 流程:設定輸入、等 #1、比對。
//////////////////////////////////////////////////////////////////////////////////

module tb_fc_spike_select;

	// 預設值是訓練端 out 層的形狀(n_col 先用 4)
	parameter integer OUT_NEURONS     = 10;
	parameter integer NEURONS_PER_ROW = 4;

	// 跟 FCSpikeSelect 的 localparam 同一套公式,port 位寬要對上才能接
	localparam integer OUT_NEURON_WIDTH = (OUT_NEURONS > 1) ? $clog2(OUT_NEURONS) : 1;

	logic [NEURONS_PER_ROW-1:0]  pending;
	logic [OUT_NEURON_WIDTH-1:0] row_base;
	logic                        found;
	logic [NEURONS_PER_ROW-1:0]  selected;
	logic [OUT_NEURON_WIDTH-1:0] selected_neuron;

	FCSpikeSelect #(
		.OUT_NEURONS    (OUT_NEURONS),
		.NEURONS_PER_ROW(NEURONS_PER_ROW)
	) dut (
		.pending        (pending),
		.row_base       (row_base),
		.found          (found),
		.selected       (selected),
		.selected_neuron(selected_neuron)
	);

	string ref_dir;
	string ref_path;
	int    ref_fd;
	int    case_count;
	int    step_count;
	int    check_count;
	int    error_count;

	// 比對一個欄位,不一致就印出 case 的 row_base、bitmask、第幾步、欄位名稱、預期值、實際值
	task automatic check_field(input int case_row_base, input int case_pending, input int step,
	                           input string field_name, input int expected, input int actual);
		check_count++;
		if (expected != actual) begin
			error_count++;
			$display("MISMATCH row_base=%0d pending=%b step=%0d %s: expected=%0d actual=%0d",
			         case_row_base, case_pending[NEURONS_PER_ROW-1:0], step, field_name, expected, actual);
		end
	endtask

	initial begin
		string kind;
		int    case_row_base;
		int    case_pending;
		int    order_count;
		int    order [0:NEURONS_PER_ROW-1];
		int    expected_column;
		int    expected_case_count;
		int    expected_step_count;
		int    scan_count;
		bit    reached_end;

		case_count  = 0;
		step_count  = 0;
		check_count = 0;
		error_count = 0;
		reached_end = 0;

		if (!$value$plusargs("REF_DIR=%s", ref_dir))
			$fatal(1, "缺少 -testplusarg REF_DIR=<答案檔目錄>");
		ref_path = $sformatf("%s/fc_spike_select_OUT%0d_COL%0d.txt", ref_dir, OUT_NEURONS, NEURONS_PER_ROW);
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
				scan_count = $fscanf(ref_fd, "%d %d %d", case_row_base, case_pending, order_count);
				if (scan_count != 3)
					$fatal(1, "答案檔第 %0d 個 case 開頭欄位不足", case_count);
				if (case_pending < 0 || case_pending >= (1 << NEURONS_PER_ROW) || order_count < 0 || order_count > NEURONS_PER_ROW)
					$fatal(1, "答案檔 row_base=%0d 的 pending 或送出筆數超出範圍", case_row_base);
				for (int step = 0; step < order_count; step++) begin
					scan_count = $fscanf(ref_fd, "%d", order[step]);
					if (scan_count != 1 || order[step] < case_row_base || order[step] >= case_row_base + NEURONS_PER_ROW)
						$fatal(1, "答案檔 row_base=%0d 第 %0d 個送出的神經元不在這一列", case_row_base, step);
				end
				row_base = OUT_NEURON_WIDTH'(case_row_base);
				pending   = NEURONS_PER_ROW'(case_pending);

				for (int step = 0; step <= order_count; step++) begin
					#1;
					if (step < order_count) begin
						expected_column = order[step] - case_row_base;
						check_field(case_row_base, case_pending, step, "found", 1, int'(found));
						check_field(case_row_base, case_pending, step, "selected_neuron", order[step], int'(selected_neuron));
					end else begin
						expected_column = -1;
						check_field(case_row_base, case_pending, step, "found", 0, int'(found));
					end
					for (int column = 0; column < NEURONS_PER_ROW; column++) begin
						check_field(case_row_base, case_pending, step, $sformatf("selected[%0d]", column),
						            int'(column == expected_column), int'(selected[column]));
					end
					if (step < order_count) begin
						pending[expected_column] = 1'b0;
						step_count++;
					end
				end
				case_count++;
			end else begin
				$fatal(1, "答案檔有不認得的指令 %s", kind);
			end
		end
		$fclose(ref_fd);

		$display("OUT_NEURONS=%0d NEURONS_PER_ROW=%0d: case_count=%0d step_count=%0d check_count=%0d error_count=%0d %s",
		         OUT_NEURONS, NEURONS_PER_ROW, case_count, step_count, check_count, error_count,
		         (error_count == 0) ? "ALL PASS" : "FAIL");
		$finish;
	end

endmodule
