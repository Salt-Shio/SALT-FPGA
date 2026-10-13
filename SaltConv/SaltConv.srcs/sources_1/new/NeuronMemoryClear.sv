`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Module Name: NeuronMemoryClear
// Description:
//   神經元記憶體的清除計數器(Conv.md 第 2 節「清除」),一層只有一份,接進每個 NeuronMemory bank。
//   rst_n=0 期間 clearing=1、clear_addr=0;釋放後每個 posedge clear_addr 加 1,
//   bank 在第 n 個 posedge 寫位址 n-1,寫完位址 BANK_DEPTH-1 的那個 posedge 之後 clearing 變 0。
//   所有 bank 同一拍清同一個位址,所以共用這一份。
//////////////////////////////////////////////////////////////////////////////////

module NeuronMemoryClear #(
	parameter integer BANK_DEPTH = 1024,   // 佔位預設值,實際深度由例化端決定(每個 bank 的格數)

	// 推導出來的位寬($clog2(1)=0 時至少保留 1 bit)
	localparam integer BANK_ADDR_WIDTH = (BANK_DEPTH > 1) ? $clog2(BANK_DEPTH) : 1
)(
	input  logic                       clk,
	input  logic                       rst_n,        // active-low,非同步觸發、同步釋放
	output logic                       clearing,     // 1:還在清,上層不能收事件,bank 忽略外部寫入
	output logic [BANK_ADDR_WIDTH-1:0] clear_addr    // 這一拍要清的位址
);

	always_ff @(posedge clk or negedge rst_n) begin
		if (!rst_n) begin
			clearing   <= 1'b1;
			clear_addr <= '0;
		end else if (clearing) begin
			if (clear_addr == BANK_ADDR_WIDTH'(BANK_DEPTH - 1)) begin
				clearing <= 1'b0;
			end else begin
				clear_addr <= clear_addr + 1'b1;
			end
		end
	end

endmodule
