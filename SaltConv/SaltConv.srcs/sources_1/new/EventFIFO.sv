`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: EventFIFO
// Description:
//   通用參數化寬度的同步 FIFO,valid/ready 交握,FWFT(first-word-fall-through)輸出。
//   只認 DATA_WIDTH 位寬的資料進出,不管裡面裝的是什麼欄位組合,pack/unpack 是呼叫端的事。
//   full/empty 是根據 push/pop 行為驅動的狀態記憶,不是單看 w,r 當前值的組合邏輯,
//   所以不用預留一格,可以用滿整個 DEPTH。
//////////////////////////////////////////////////////////////////////////////////

module EventFIFO #(
	parameter integer DATA_WIDTH = 32,   // 佔位預設值,實際寬度由例化端決定
	parameter integer DEPTH      = 16    // 佔位預設值,實際深度由例化端決定
)(
	input  logic clk,
	input  logic rst_n,          // active-low,非同步觸發、同步釋放

	// 寫入端(push,接上游)
	input  logic                  wr_valid,
	output logic                  wr_ready,
	input  logic [DATA_WIDTH-1:0] wr_data,

	// 讀出端(pop,接下游)
	output logic                  rd_valid,
	input  logic                  rd_ready,
	output logic [DATA_WIDTH-1:0] rd_data
);

	localparam integer PTR_WIDTH = $clog2(DEPTH);

	logic [PTR_WIDTH-1:0] w, r;
	logic full, empty;
	// 一律用 distributed RAM(LUT 當記憶體),不交給 Vivado 依大小判斷:深度小,讀取要組合邏輯(FWFT),
	// BRAM 讀出要多 1 拍。之後深度開大換 BRAM 時,這裡跟 rd_valid 的對齊一起改
	(* ram_style = "distributed" *) logic [DATA_WIDTH-1:0] mem [0:DEPTH-1];

	logic push, pop;
	logic [PTR_WIDTH-1:0] w_next, r_next;

	assign wr_ready = !full;
	assign rd_valid = !empty;

	assign push = wr_valid && wr_ready;
	assign pop  = rd_valid && rd_ready;

	assign w_next = (w == DEPTH-1) ? '0 : w + 1'b1;
	assign r_next = (r == DEPTH-1) ? '0 : r + 1'b1;

	assign rd_data = mem[r]; // FWFT:直接組合邏輯讀,rd_valid=1 那拍資料就穩定

	// 資料陣列不放進有非同步 reset 的 always_ff:放在一起時 Vivado 報 Synth 8-7137(Set、reset 同優先),
	// 推不出 distributed RAM,整個陣列變成暫存器。reset 期間就算寫進來,w、r、empty 都被 reset,讀不到。
	always_ff @(posedge clk) begin
		if (push) begin
			mem[w] <= wr_data;
		end
	end

	always_ff @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			w     <= '0;
			r     <= '0;
			full  <= 1'b0;
			empty <= 1'b1;
		end else begin
			if (push) begin
				w <= w_next;
			end
			if (pop) begin
				r <= r_next;
			end

			case ({push, pop})
				2'b00:   full <= full;             // 都沒有
				2'b01:   full <= 1'b0;             // 只有 pop
				2'b10:   full <= (w_next == r);    // 只有 push
				2'b11:   full <= full;             // 都有
			endcase

			case ({push, pop})
				2'b00:   empty <= empty;           // 都沒有
				2'b01:   empty <= (r_next == w);   // 只有 pop
				2'b10:   empty <= 1'b0;            // 只有 push
				2'b11:   empty <= empty;           // 都有
			endcase
		end
	end

endmodule
