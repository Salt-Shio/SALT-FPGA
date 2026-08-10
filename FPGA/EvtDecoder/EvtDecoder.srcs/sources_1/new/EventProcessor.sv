`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 2026/08/10 16:58:45
// Design Name: 
// Module Name: EventProcessor
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////

typedef enum logic [0:0] {
	FETCH = 1'b0,
	EXPAND = 1'b1
} FSM_STATE;

typedef enum logic [3:0] {
	TD_NEG = 4'h0,
	TD_POS = 4'h1,
	TIME_HIGH = 4'h8
} EVT_TYPE;


module EventProcessor #(
	parameter integer C_S_AXIS_TDATA_WIDTH	= 64,
	parameter integer C_M_AXIS_TDATA_WIDTH	= 64
)(
	// AXI4-Stream CLK & RSTN
	input logic  AXIS_ACLK,
	input logic  AXIS_ARESETN,

	// AXI4-Stream Slave
	output logic  S_AXIS_TREADY,
	input logic [C_S_AXIS_TDATA_WIDTH-1 : 0] S_AXIS_TDATA,
	input logic [(C_S_AXIS_TDATA_WIDTH/8)-1 : 0] S_AXIS_TSTRB,
	input logic  S_AXIS_TLAST,
	input logic  S_AXIS_TVALID,

	// AXI4-Stream Master
	output logic  M_AXIS_TVALID,
	output logic [C_M_AXIS_TDATA_WIDTH-1 : 0] M_AXIS_TDATA,
	output logic [(C_M_AXIS_TDATA_WIDTH/8)-1 : 0] M_AXIS_TSTRB,
	output logic  M_AXIS_TLAST,
	input logic  M_AXIS_TREADY
);
	/* 內部暫存器 */
	logic state_q;
	logic time_valid_q;
	logic [27:0] time_high_q;
	logic [C_S_AXIS_TDATA_WIDTH-1 : 0] evt_data_q;
	logic m_valid_q;
	logic [C_M_AXIS_TDATA_WIDTH-1 : 0] m_data_q;
	logic [(C_M_AXIS_TDATA_WIDTH/8)-1 : 0] m_strb_q;
	logic m_last_q;

	/* 初步判斷 */
	logic [3:0] fetch_evt_type = S_AXIS_TDATA[63:60]; 
	logic [27:0] time_high = S_AXIS_TDATA[59:32];

	/* 解包 TD EVT */
	logic [3:0] td_type = evt_data_q[63:60];
	logic [5:0] td_time = evt_data_q[59:54];
	logic [10:0] td_x = evt_data_q[53:43];
	logic [10:0] td_y = evt_data_q[42:32];
	logic [31:0] td_mask = evt_data_q[31:0];

	/* 處理 bitmask */
	logic [31:0] mask_next = td_mask & (td_mask - 32'd1);
	logic [4:0] x_offset;
	// 低位 優先編碼器
	always_comb begin
		x_offset = 5'd0;
		for (int i = 31; i >= 0; i--) begin
			if (td_mask[i]) x_offset = i[4:0];
		end
	end

	/* 主要狀態機 */
	assign S_AXIS_TREADY = (state_q == FETCH);
	always_ff @(posedge AXIS_ACLK or negedge AXIS_ARESETN) begin
		if (!AXIS_ARESETN) begin
			state_q <= FETCH;
			evt_data_q <= '0;
			time_valid_q <= '0;
			time_high_q <= '0;

			m_valid_q <= '0;
			m_data_q <= '0;
			m_strb_q <= '0;
			m_last_q <= '0;

		end else begin
			if (state_q == FETCH) begin
				if (S_AXIS_TVALID && S_AXIS_TREADY) begin
					// STATE = FETCH
					evt_data_q <= S_AXIS_TDATA;
					if (fetch_evt_type == TD_NEG || fetch_evt_type == TD_POS) begin
						if (time_valid_q) begin
							state_q <= EXPAND;
						end 
					end else if (fetch_evt_type == TIME_HIGH) begin
						time_valid_q <= 1'b1;
						time_high_q <= time_high;
					end
				end 
			end else begin
				// STATE = EXPAND

				if (M_AXIS_TREADY || !m_valid_q) begin
					// 資料沒人收的話就不准改
					m_data_q <= {td_x + x_offset, td_y, td_type[0], time_high_q, td_time};
					if (td_mask == '0) begin
						m_valid_q <= 1'b0;
						state_q <= FETCH;
					end else begin
						m_valid_q <= 1'b1;
						evt_data_q[31:0] <= mask_next;
					end
				end
			end
		end
	end

	assign M_AXIS_TVALID = m_valid_q;
	assign M_AXIS_TDATA = m_data_q;
	assign M_AXIS_TSTRB = m_strb_q;
	assign M_AXIS_TLAST = m_last_q;
endmodule
