`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: tb_fc_neuron_memory
// Description:
//   NeuronMemoryClear + lib/NeuronMemory 用 FC 的參數驗證(FC.md 第 2 節「神經元」):
//   深 n_row、每格一列 n_col 顆的 V̂,第 x 行從第 x*w bit 起;切段寫在這裡(SaltFC 每行的 generate 區塊裡是同一個寫法)。
//   寫入值由 testbench 自己產生(neuron_value),不用答案檔。流程一個 initial,依序:
//     1 reset:negedge 拉低 rst_n,HOLD_CYCLES 拍後在 negedge 放開;每個 posedge 之前 clearing 要是 1,
//       放開後剛好 n_row 個 posedge 之前是 1,之後變 0。整段每拍都送外部寫入(全 1、列號倒著走),清除要忽略。
//     2 每一列讀一遍,n_col 段都要是 0
//     3 每一列寫入 neuron_value,再讀一遍,第 x 段要等於 neuron_value(y, x)
//     4 再 reset 一次(這次記憶體裡不是 0),讀一遍要全部回到 0
//   讀:negedge 送 read_enable=1、列號;READ_LATENCY 個 posedge 後 #1 比對。寫:negedge 送,下一個 posedge 寫入。
//   參數用 xelab -generic_top 帶入。
//////////////////////////////////////////////////////////////////////////////////

module tb_fc_neuron_memory;

	// 預設值是訓練端 out 層繞回版,n_col 先用 4
	parameter integer OUT_NEURONS     = 10;
	parameter integer NEURONS_PER_ROW = 4;
	parameter integer MEMBRANE_WIDTH  = 14;
	parameter integer READ_LATENCY    = 1;

	// 跟 SaltFC 的 localparam 同一套公式,port 位寬要對上才能接
	localparam integer ROW_COUNT      = (OUT_NEURONS + NEURONS_PER_ROW - 1) / NEURONS_PER_ROW;   // n_row
	localparam integer ROW_WIDTH      = (ROW_COUNT > 1) ? $clog2(ROW_COUNT) : 1;
	localparam integer ROW_WORD_WIDTH = NEURONS_PER_ROW * MEMBRANE_WIDTH;
	localparam integer HOLD_CYCLES    = 3;   // rst_n 拉低的拍數

	logic clk = 1'b0;
	always #5 clk = ~clk;

	logic                 rst_n;
	logic                 clearing;
	logic [ROW_WIDTH-1:0] clear_addr;

	NeuronMemoryClear #(
		.BANK_DEPTH(ROW_COUNT)
	) memory_clear (
		.clk       (clk),
		.rst_n     (rst_n),
		.clearing  (clearing),
		.clear_addr(clear_addr)
	);

	logic                             read_enable;
	logic        [ROW_WIDTH-1:0]      read_row;
	logic        [ROW_WORD_WIDTH-1:0] read_word;
	logic signed [MEMBRANE_WIDTH-1:0] read_membrane  [0:NEURONS_PER_ROW-1];
	logic                             write_enable;
	logic        [ROW_WIDTH-1:0]      write_row;
	logic        [ROW_WORD_WIDTH-1:0] write_word;
	logic signed [MEMBRANE_WIDTH-1:0] write_membrane [0:NEURONS_PER_ROW-1];

	NeuronMemory #(
		.DEPTH       (ROW_COUNT),
		.WORD_WIDTH  (ROW_WORD_WIDTH),
		.READ_LATENCY(READ_LATENCY)
	) memory (
		.clk         (clk),
		.clearing    (clearing),
		.clear_addr  (clear_addr),
		.read_enable (read_enable),
		.shift_enable(1'b1),
		.read_addr   (read_row),
		.read_word   (read_word),
		.write_enable(write_enable),
		.write_addr  (write_row),
		.write_word  (write_word)
	);

	for (genvar column = 0; column < NEURONS_PER_ROW; column++) begin : columns
		assign write_word[column*MEMBRANE_WIDTH +: MEMBRANE_WIDTH] = write_membrane[column];
		assign read_membrane[column] = read_word[column*MEMBRANE_WIDTH +: MEMBRANE_WIDTH];
	end

	int check_count;
	int error_count;

	// 第 y 列第 x 行寫入的值:第一格是 w 位元下界、最後一格是上界,其他照編號散開,相鄰兩行一定不同
	function automatic int neuron_value(int row, int column);
		int neuron;
		int low;
		int span;
		neuron = row * NEURONS_PER_ROW + column;
		low    = -(1 << (MEMBRANE_WIDTH - 1));
		span   = 1 << MEMBRANE_WIDTH;
		if (neuron == 0)
			return low;
		if (neuron == ROW_COUNT * NEURONS_PER_ROW - 1)
			return -low - 1;
		return low + (neuron * 37 + 5) % span;
	endfunction

	// reset 跟清除:negedge 送 rst_n 跟要被忽略的外部寫入,#1 後(非同步 reset 已生效)、posedge 之前檢查 clearing
	task automatic reset_and_clear();
		@(negedge clk);
		for (int cycle = 0; cycle < HOLD_CYCLES + ROW_COUNT; cycle++) begin
			rst_n        = (cycle >= HOLD_CYCLES);
			write_enable = 1'b1;
			write_row    = ROW_WIDTH'(ROW_COUNT - 1 - cycle % ROW_COUNT);
			for (int column = 0; column < NEURONS_PER_ROW; column++)
				write_membrane[column] = '1;
			#1;
			check_count++;
			if (clearing !== 1'b1) begin
				error_count++;
				$display("MISMATCH clearing before posedge %0d (rst_n released before posedge %0d): expected=1 actual=%b",
				         cycle, HOLD_CYCLES, clearing);
			end
			@(negedge clk);
		end
		write_enable = 1'b0;
		check_count++;
		if (clearing !== 1'b0) begin
			error_count++;
			$display("MISMATCH clearing after %0d posedges since release: expected=0 actual=%b", ROW_COUNT, clearing);
		end
	endtask

	task automatic write_all_rows();
		for (int row = 0; row < ROW_COUNT; row++) begin
			@(negedge clk);
			write_enable = 1'b1;
			write_row    = ROW_WIDTH'(row);
			for (int column = 0; column < NEURONS_PER_ROW; column++)
				write_membrane[column] = MEMBRANE_WIDTH'(neuron_value(row, column));
		end
		@(negedge clk);
		write_enable = 1'b0;
	endtask

	// expect_written = 0:每段都要是 0;1:第 x 段要等於 neuron_value(y, x)
	task automatic read_all_rows(string phase, bit expect_written);
		int expected;
		for (int row = 0; row < ROW_COUNT; row++) begin
			@(negedge clk);
			read_enable = 1'b1;
			read_row    = ROW_WIDTH'(row);
			repeat (READ_LATENCY) @(posedge clk);
			#1;
			for (int column = 0; column < NEURONS_PER_ROW; column++) begin
				expected = expect_written ? neuron_value(row, column) : 0;
				check_count++;
				if ($isunknown(read_membrane[column]) || int'(read_membrane[column]) != expected) begin
					error_count++;
					$display("MISMATCH %s y=%0d column=%0d neuron=%0d: expected=%0d actual=%0d",
					         phase, row, column, row * NEURONS_PER_ROW + column, expected, read_membrane[column]);
				end
			end
		end
		@(negedge clk);
		read_enable = 1'b0;
	endtask

	initial begin
		check_count  = 0;
		error_count  = 0;
		rst_n        = 1'b1;
		read_enable  = 1'b0;
		read_row     = '0;
		write_enable = 1'b0;
		write_row    = '0;
		for (int column = 0; column < NEURONS_PER_ROW; column++)
			write_membrane[column] = '0;

		reset_and_clear();
		read_all_rows("after first clear", 1'b0);
		write_all_rows();
		read_all_rows("after write", 1'b1);
		reset_and_clear();
		read_all_rows("after second clear", 1'b0);

		$display("OUT_NEURONS=%0d NEURONS_PER_ROW=%0d MEMBRANE_WIDTH=%0d READ_LATENCY=%0d: check_count=%0d error_count=%0d %s",
		         OUT_NEURONS, NEURONS_PER_ROW, MEMBRANE_WIDTH, READ_LATENCY, check_count, error_count,
		         (error_count == 0) ? "ALL PASS" : "FAIL");
		$finish;
	end

endmodule
