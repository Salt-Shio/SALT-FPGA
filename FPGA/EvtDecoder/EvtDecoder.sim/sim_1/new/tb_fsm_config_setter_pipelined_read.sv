`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// tb_fsm_config_setter_pipelined_read.sv
//
// 專門重現 FsmConfigSetter read channel 的 deadlock:
//   第二筆 AR(位址 0x04)在第一筆 R(位址 0x00)的資料還沒被 RREADY 收走前就送出。
//   AXI4 協定允許 master 這樣做(AR channel 跟 R channel 是分開的),
//   但 DUT 的 axi_arready 產生邏輯不管 axi_rvalid 有沒有清完就會自動把 ready 收回,
//   導致 read data channel 那邊「axi_arready && ARVALID && !axi_rvalid」這個條件
//   永遠沒有機會同時成立 —— 第二筆讀取的位址已經被協定上判定為「已接受」,
//   但 RVALID 永遠不會為它出現,master 會卡死。
//
// 跟 tb_fsm_config_setter.sv 不共用/不修改;這個檔案獨立驗證同一個 DUT 的
// 這一種特定的時序情境,方便直接開波形看。
//////////////////////////////////////////////////////////////////////////////////

module tb_fsm_config_setter_pipelined_read;

	localparam integer DATA_W = 32;
	localparam integer ADDR_W = 32;

	logic clk = 0;
	logic rstn = 0;

	logic [ADDR_W-1:0] awaddr;
	logic [2:0]         awprot = '0;
	logic                awvalid = 0;
	logic                awready;
	logic [DATA_W-1:0]  wdata;
	logic [(DATA_W/8)-1:0] wstrb;
	logic                wvalid = 0;
	logic                wready;
	logic [1:0]          bresp;
	logic                bvalid;
	logic                bready = 0;
	logic [ADDR_W-1:0]  araddr;
	logic [2:0]          arprot = '0;
	logic                arvalid = 0;
	logic                arready;
	logic [DATA_W-1:0]  rdata;
	logic [1:0]          rresp;
	logic                rvalid;
	logic                rready = 0;

	logic cfg_enable, cfg_enable_pattern, cfg_soft_reset, cfg_fifo_clear;
	logic [15:0] cfg_tlast_timeout;

	FsmConfigSetter #(
		.C_S_AXI_DATA_WIDTH(DATA_W),
		.C_S_AXI_ADDR_WIDTH(ADDR_W)
	) dut (
		.S_AXI_ACLK(clk),
		.S_AXI_ARESETN(rstn),
		.S_AXI_AWADDR(awaddr),
		.S_AXI_AWPROT(awprot),
		.S_AXI_AWVALID(awvalid),
		.S_AXI_AWREADY(awready),
		.S_AXI_WDATA(wdata),
		.S_AXI_WSTRB(wstrb),
		.S_AXI_WVALID(wvalid),
		.S_AXI_WREADY(wready),
		.S_AXI_BRESP(bresp),
		.S_AXI_BVALID(bvalid),
		.S_AXI_BREADY(bready),
		.S_AXI_ARADDR(araddr),
		.S_AXI_ARPROT(arprot),
		.S_AXI_ARVALID(arvalid),
		.S_AXI_ARREADY(arready),
		.S_AXI_RDATA(rdata),
		.S_AXI_RRESP(rresp),
		.S_AXI_RVALID(rvalid),
		.S_AXI_RREADY(rready),
		.cfg_enable(cfg_enable),
		.cfg_enable_pattern(cfg_enable_pattern),
		.cfg_tlast_timeout(cfg_tlast_timeout),
		.cfg_soft_reset(cfg_soft_reset),
		.cfg_fifo_clear(cfg_fifo_clear)
	);

	always #5 clk = ~clk;

	task automatic tick();
		@(posedge clk);
		#1;
	endtask

	// 除錯後門位址 0x04 存的值,用來確認第二筆讀取如果真的拿到資料,內容有沒有對
	localparam logic [DATA_W-1:0] READ1_EXPECT = 32'h0000_0001; // regfile[0]
	localparam logic [DATA_W-1:0] READ2_EXPECT = 32'h0000_0002; // regfile[1]

	task automatic axi_write(input logic [ADDR_W-1:0] addr, input logic [DATA_W-1:0] data);
		bit aw_done, w_done, b_done;
		awaddr = addr; awvalid = 1'b1;
		wdata  = data; wstrb = '1; wvalid = 1'b1;
		aw_done = 1'b0; w_done = 1'b0;
		while (!aw_done || !w_done) begin
			if (awvalid && awready) aw_done = 1'b1;
			if (wvalid && wready)   w_done  = 1'b1;
			tick();
			if (aw_done) awvalid = 1'b0;
			if (w_done)  wvalid  = 1'b0;
		end
		bready = 1'b1;
		b_done = 1'b0;
		while (!b_done) begin
			if (bvalid && bready) b_done = 1'b1;
			tick();
		end
		bready = 1'b0;
	endtask

	int unsigned wait_count;
	bit ar1_done, ar2_done, r1_done, r2_done;
	logic [DATA_W-1:0] r1_data, r2_data;

	initial begin
		rstn = 0;
		repeat (5) tick();
		rstn = 1;
		tick();

		// --- 準備兩個具名位址的資料,順序 write,跟 bug 無關,只是先鋪好內容 ---
		axi_write(32'h00, READ1_EXPECT);
		axi_write(32'h04, READ2_EXPECT);

		$display("[%0t] === 開始重現情境:read1(0x00) 的資料還沒被 RREADY 收走,就送出 read2(0x04) 的 AR ===", $time);

		// --- 第一筆:送出 read1 的 AR,等 handshake(arvalid && arready 同一拍成立) ---
		araddr = 32'h00;
		arvalid = 1'b1;
		ar1_done = 1'b0;
		while (!ar1_done) begin
			if (arvalid && arready) begin
				ar1_done = 1'b1;
				$display("[%0t] read1 AR handshake:araddr=0x%0h 被 DUT 收下", $time, araddr);
			end
			tick();
		end

		// --- 關鍵:不把 arvalid 收回,直接把位址換成 read2 的 0x04,
		//     模擬 master 在 R 通道還沒收到 read1 資料前,就先把 read2 的 AR 準備好 ---
		araddr = 32'h04;
		$display("[%0t] 不等 read1 的 RVALID/RREADY,直接把 ARADDR 換成 0x04,ARVALID 繼續撐著 1", $time);

		// rready 保持 0,讓 read1 的 rvalid 卡住不被收走,製造 arready/rvalid 對不上拍的窗口。
		// 只送「一次」read2 的請求:一收到 arready&&arvalid 的 handshake,馬上把 arvalid 收回,
		// 避免 arvalid 撐著不放、被 DUT 誤當成好幾筆獨立請求重複接受。
		ar2_done = 1'b0;
		while (!ar2_done) begin
			if (arvalid && arready) begin
				ar2_done = 1'b1;
				$display("[%0t] read2 AR handshake(只有這一次):araddr=0x%0h 被 DUT 收下(此時 DUT 內部 axi_rvalid=%b,還卡著 read1 的資料沒被收走)",
					$time, araddr, dut.axi_rvalid);
			end
			tick();
		end
		arvalid = 1'b0;

		$display("[%0t] DUT 內部 axi_araddr=0x%0h(應該已經被蓋成 0x04)", $time, dut.axi_araddr);

		// --- 現在才放行,把 read1 的資料收走 ---
		rready = 1'b1;
		r1_done = 1'b0;
		while (!r1_done) begin
			if (rvalid && rready) begin
				r1_data = rdata;
				r1_done = 1'b1;
				$display("[%0t] read1 RVALID 出現,rdata=0x%0h", $time, rdata);
			end
			tick();
		end

		if (r1_data !== READ1_EXPECT) begin
			$display("[%0t] 錯誤:read1 資料不對,got=0x%0h expect=0x%0h", $time, r1_data, READ1_EXPECT);
		end

		// --- 觀察 read2(0x04)的 RVALID 有沒有出現,設一個上限,避免真的卡死模擬本身 ---
		r2_done = 1'b0;
		for (wait_count = 0; wait_count < 50 && !r2_done; wait_count = wait_count + 1) begin
			if (rvalid && rready) begin
				r2_data = rdata;
				r2_done = 1'b1;
			end
			tick();
		end
		rready = 1'b0;

		$display("");
		if (r2_done) begin
			if (r2_data === READ2_EXPECT)
				$display("[%0t] === 沒有卡死:read2(0x04) 的 RVALID 有出現,資料正確(0x%0h)===", $time, r2_data);
			else
				$display("[%0t] === 沒有卡死,但資料不對:read2(0x04) 的 RVALID 出現,rdata=0x%0h,expect=0x%0h ===", $time, r2_data, READ2_EXPECT);
		end else begin
			$display("[%0t] === 卡死重現成功:read2(0x04) 的 AR 已被 DUT 接受(ar2_done=%0d),但等了 %0d 個 clock cycle,RVALID 從未為它出現 ===",
				$time, ar2_done, wait_count);
		end

		repeat (5) tick();
		$finish;
	end

endmodule
