`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:
//
// Create Date: 2026/08/10 17:00:38
// Design Name:
// Module Name: FsmConfigSetter
// Project Name:
// Target Devices:
// Tool Versions:
// Description:
//
// 位址對照(word-aligned,32-bit 暫存器):
//   0x00 REG_CONTROL       bit0=enable bit1=soft_reset bit2=fifo_clear
//   0x04 REG_CONFIG        bit0=enable_pattern bit1=tlast_timeout_enable
//   0x08 REG_TLAST_TIMEOUT [15:0]
//   其他                    純讀寫後門,無功能副作用
//
// REG_CONFIG.tlast_timeout_enable 與 REG_TLAST_TIMEOUT 的 reset 預設值是雙重防線,
// 參考官方 ps_host_if_reg_bank 的 CONFIG_TIMEOUT_ENABLE_DEFAULT/TIMEOUT_VALUE_DEFAULT
// 設計:enable 預設關閉(0),TLAST_TIMEOUT 本身也給非 0 的合理預設值,避免 reset 完、
// PS 端還沒來得及設定就發生「flush_timer_q(0) >= cfg_tlast_timeout(0)」恆成立、
// 每筆事件都被迫掛 tlast 的空窗期。
//
// 設計方式:
// - Read channel(AR/R):ARREADY = !axi_rvalid || S_AXI_RREADY,用組合邏輯直接算,
//   不是 latch 住的兩態機。允許「這拍舊資料被 RREADY 拿走,同一拍就接受下一筆新位址」
//   (ARREADY 跟 RVALID 可以同時是 1,只要 RREADY 也同時是 1),達到 back-to-back、
//   每拍一筆的吞吐量;唯一會擋住新位址的情況是「舊資料還沒被拿走」(rvalid=1 且
//   rready=0),不會發生新位址覆蓋掉還沒交出去的舊資料這種卡死/掉資料的問題。
//   （這個公式比官方 ps_host_if_reg_bank 的 pulse 式 ARREADY 實測快一倍,官方那版
//   跟這裡原本的 latch 式寫法吞吐量其實相同,都是每兩拍一筆,已用 xsim 量測驗證。）
// - Write channel(AW/W/B):明確的 idle/busy 兩態 latch,AWREADY/WREADY 跟 BVALID
//   永遠互斥,不可能出現「已經答應收下新請求,但前一筆的 response 還沒交完」這種
//   狀態,不會卡死;AW 跟 W 允許分開拍到,不要求兩者同一拍到齊。這裡沒有比照 read
//   channel 做同樣的 back-to-back 優化——AW/W 分開到達的暫存機制,跟 back-to-back
//   要求的「同一拍解決舊的、順便接受新的」兜在一起會需要額外的 pending 旗標與狀態,
//   複雜度不成比例(config 暫存器寫入本來就不是高頻路徑),故意保持原本的簡單設計。
//
// Dependencies:
//
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
//
//////////////////////////////////////////////////////////////////////////////////


module FsmConfigSetter #(
		parameter integer C_S_AXI_DATA_WIDTH	= 32,
		parameter integer C_S_AXI_ADDR_WIDTH	= 32
	)(
        // CLK and Reset
		input wire  S_AXI_ACLK,
		input wire  S_AXI_ARESETN,

        // Slave AXI4-Lite
		input wire [C_S_AXI_ADDR_WIDTH-1 : 0] S_AXI_AWADDR,
		input wire [2 : 0] S_AXI_AWPROT,
		input wire  S_AXI_AWVALID,
		output wire  S_AXI_AWREADY,
		input wire [C_S_AXI_DATA_WIDTH-1 : 0] S_AXI_WDATA,
		input wire [(C_S_AXI_DATA_WIDTH/8)-1 : 0] S_AXI_WSTRB,
		input wire  S_AXI_WVALID,
		output wire  S_AXI_WREADY,
		output wire [1 : 0] S_AXI_BRESP,
		output wire  S_AXI_BVALID,
		input wire  S_AXI_BREADY,
		input wire [C_S_AXI_ADDR_WIDTH-1 : 0] S_AXI_ARADDR,
		input wire [2 : 0] S_AXI_ARPROT,
		input wire  S_AXI_ARVALID,
		output wire  S_AXI_ARREADY,
		output wire [C_S_AXI_DATA_WIDTH-1 : 0] S_AXI_RDATA,
		output wire [1 : 0] S_AXI_RRESP,
		output wire  S_AXI_RVALID,
		input wire  S_AXI_RREADY,

		// 給 FsmEventExtractor 底下其他模組的控制輸出
		output logic  cfg_enable,
		output logic  cfg_enable_pattern,
		output logic [15:0] cfg_tlast_timeout,
		output logic  cfg_tlast_timeout_enable,
		output logic  cfg_soft_reset,
		output logic  cfg_fifo_clear
	);

	localparam integer ADDR_LSB  = (C_S_AXI_DATA_WIDTH/32) + 1; // 32-bit 資料寬度下 = 2
	localparam integer REG_COUNT = 16;
	localparam integer IDX_W     = $clog2(REG_COUNT);

	logic [C_S_AXI_DATA_WIDTH-1:0] regfile [0:REG_COUNT-1];

	/* ================= Read channel(AR/R) ================= */
	logic [C_S_AXI_ADDR_WIDTH-1:0] axi_araddr; // 純記錄用,方便看波形,不在資料路徑上
	logic axi_rvalid;
	logic [1:0] axi_rresp;
	logic [C_S_AXI_DATA_WIDTH-1:0] axi_rdata;

	// ARREADY 直接算,不 latch:手上沒有還沒被拿走的舊資料,或舊資料這拍剛好被
	// RREADY 拿走,兩種情況都可以接受新位址(後者就是 back-to-back 的關鍵)。
	assign S_AXI_ARREADY = !axi_rvalid || S_AXI_RREADY;
	assign S_AXI_RDATA   = axi_rdata;
	assign S_AXI_RRESP   = axi_rresp;
	assign S_AXI_RVALID  = axi_rvalid;

	always_ff @(posedge S_AXI_ACLK or negedge S_AXI_ARESETN) begin
		if (!S_AXI_ARESETN) begin
			axi_araddr  <= '0;
			axi_rvalid  <= 1'b0;
			axi_rresp   <= 2'b00;
			axi_rdata   <= '0;
		end else if (!axi_rvalid || S_AXI_RREADY) begin
			if (S_AXI_ARVALID) begin
				axi_araddr  <= S_AXI_ARADDR;
				axi_rdata   <= regfile[S_AXI_ARADDR[ADDR_LSB +: IDX_W]];
				axi_rresp   <= 2'b00;
				axi_rvalid  <= 1'b1;
			end else begin
				// 沒有新位址進來,但舊資料被拿走了:回到沒資料狀態
				axi_rvalid  <= 1'b0;
			end
		end
	end

	/* ================= Write channel(AW/W/B):idle/busy 兩態,AW/W 允許分開拍到 ================= */
	logic axi_awready;
	logic axi_wready;
	logic [1:0] axi_bresp;
	logic axi_bvalid;
	logic [C_S_AXI_ADDR_WIDTH-1:0] awaddr_r; // AW 先到、W 還沒到齊時,暫存位址
	logic [C_S_AXI_DATA_WIDTH-1:0] wdata_r;  // W 先到、AW 還沒到齊時,暫存資料
	logic [(C_S_AXI_DATA_WIDTH/8)-1:0] wstrb_r;

	assign S_AXI_AWREADY = axi_awready;
	assign S_AXI_WREADY  = axi_wready;
	assign S_AXI_BRESP   = axi_bresp;
	assign S_AXI_BVALID  = axi_bvalid;

	always_ff @(posedge S_AXI_ACLK or negedge S_AXI_ARESETN) begin
		if (!S_AXI_ARESETN) begin
			for (int i = 0; i < REG_COUNT; i++) regfile[i] <= '0;
			regfile[2] <= 16'd12500; // REG_TLAST_TIMEOUT 非 0 安全預設值:125MHz 下 100us
			axi_awready <= 1'b1;   // reset 完是 idle,可以收新的寫入請求
			axi_wready  <= 1'b1;
			axi_bvalid  <= 1'b0;
			axi_bresp   <= 2'b00;
			awaddr_r    <= '0;
			wdata_r     <= '0;
			wstrb_r     <= '0;
		end else if (!axi_bvalid) begin
			// idle:上一筆的 response 已經被拿走(或還沒發生過),才可以收新請求
			if (S_AXI_AWVALID && axi_awready && S_AXI_WVALID && axi_wready) begin
				// AW、W 同一拍到齊,直接寫
				for (int b = 0; b < (C_S_AXI_DATA_WIDTH/8); b++) begin
					if (S_AXI_WSTRB[b]) regfile[S_AXI_AWADDR[ADDR_LSB +: IDX_W]][b*8 +: 8] <= S_AXI_WDATA[b*8 +: 8];
				end
				axi_awready <= 1'b0;
				axi_wready  <= 1'b0;
				axi_bvalid  <= 1'b1;
				axi_bresp   <= 2'b00; // OKAY,除錯後門不做位址範圍檢查
			end else if (S_AXI_AWVALID && axi_awready) begin
				// 只有 AW 先到
				awaddr_r    <= S_AXI_AWADDR;
				axi_awready <= 1'b0;
				if (!axi_wready) begin
					// W 之前已經先到、存在 wdata_r/wstrb_r 裡了,現在湊齊,直接寫
					for (int b = 0; b < (C_S_AXI_DATA_WIDTH/8); b++) begin
						if (wstrb_r[b]) regfile[S_AXI_AWADDR[ADDR_LSB +: IDX_W]][b*8 +: 8] <= wdata_r[b*8 +: 8];
					end
					axi_bvalid <= 1'b1;
					axi_bresp  <= 2'b00;
				end
			end else if (S_AXI_WVALID && axi_wready) begin
				// 只有 W 先到
				wdata_r    <= S_AXI_WDATA;
				wstrb_r    <= S_AXI_WSTRB;
				axi_wready <= 1'b0;
				if (!axi_awready) begin
					// AW 之前已經先到、存在 awaddr_r 裡了,現在湊齊,直接寫
					for (int b = 0; b < (C_S_AXI_DATA_WIDTH/8); b++) begin
						if (S_AXI_WSTRB[b]) regfile[awaddr_r[ADDR_LSB +: IDX_W]][b*8 +: 8] <= S_AXI_WDATA[b*8 +: 8];
					end
					axi_bvalid <= 1'b1;
					axi_bresp  <= 2'b00;
				end
			end
		end else begin
			// busy:response 已經準備好,等 master 用 BREADY 收走
			if (S_AXI_BREADY) begin
				axi_bvalid  <= 1'b0;
				axi_awready <= 1'b1;   // response 被收走,轉回 idle
				axi_wready  <= 1'b1;
			end
		end
	end

	/* ---------------- 具名暫存器 → 對外控制訊號(組合邏輯,即時反映 regfile 內容) ---------------- */
	assign cfg_enable         = regfile[0][0];
	assign cfg_soft_reset     = regfile[0][1];
	assign cfg_fifo_clear     = regfile[0][2];
	assign cfg_enable_pattern       = regfile[1][0];
	assign cfg_tlast_timeout_enable = regfile[1][1];
	assign cfg_tlast_timeout        = regfile[2][15:0];

endmodule
