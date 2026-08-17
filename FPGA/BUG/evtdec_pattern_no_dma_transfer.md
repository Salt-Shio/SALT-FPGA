# Bug:`enable_pattern` 假資料模式收不到資料(真實感測器資料路徑正常)

## 2026-08-17 更新:核心功能已確認正常,問題範圍縮小到 `enable_pattern` 本身

繞過 `enable_pattern`,直接用真實感測器資料測試(把 `REG_CONFIG` 寫回 `0x0`),**整條路徑成功跑通**:

```
genx320 → mipi_csi2_rx_subsystem → axis_tkeep_handler → event_stream_smart_tracker
  → evtdec(FsmEventExtractor 真實解碼)→ axi_dma → evtdec-video driver → /dev/video0 → evt_dump
```

`evt_dump` 印出合理的 `(x,y,type,t)`(`x`/`y` 落在 0~319、`type` 是 0/1、`t` 微秒遞增)。**這證實核心功能(PL 端解碼 GenX320 事件資料、取代 `ps_host_if`)完全正常**,問題只出在 `enable_pattern` 這個除錯用的假資料模式,不影響真正的功能,優先度大幅降低。以下第 1~10 節的查證過程維持原樣保留(當初範圍設定得比較大,查的時候還不知道問題只侷限在 pattern 模式),第 11 節開始是後續針對 pattern 模式本身的查證。

## 症狀

上板測試(`FPGA/app_bundle/deploy_manual.md` 步驟 6a)照順序執行到底:app 載入成功、`media-ctl -p` 顯示整條 media graph 五個 entity 全部 `[ENABLED]`、格式統一 `PSEE_EVT21/320x320`、`REG_CONFIG.enable_pattern` 用 `v4l2_reg` 寫入確認生效。但執行 `evt_dump /dev/video0 20` 後,程式卡住不動,沒有印出任何 `x=... y=... type=... t=...`,一直到手動 `Ctrl+C` 都沒有收到任何一筆資料。

## 查證過程(依時間順序)

### 1. 確認 `evt_dump` 是卡住,不是當掉或跳過

```bash
ps aux | grep evt_dump
```

**結果**:程式仍在執行中(`sudo ./evt_dump /dev/video0 20`),沒有 exit,也沒有印任何錯誤訊息。

**代表**:程式進入了 `select()`+`VIDIOC_DQBUF` 的等待迴圈,持續收不到新 buffer,不是初始化階段(`open`/`REQBUFS`/`STREAMON`)就失敗——那些步驟任何一步失敗都會印出對應的 `perror()` 訊息並結束程式,但沒有。

### 2. 確認 `dmesg` 有沒有新錯誤

**結果**:`dmesg | tail` 沒有任何新訊息,跟 app 剛載入時的內容一樣。

**代表**:沒有 kernel/driver 層級的錯誤被觸發,問題不是「某個步驟報錯」,比較像是「安靜地卡住」。

### 3. 確認暫存器狀態(卡住的當下,不是結束後)

第一次查是在 `Ctrl+C`(觸發 `STREAMOFF`)**之後**才查,`REG_CONTROL(0x0) = 0x4`(`clear` 位元被 `stop_streaming()` 打開、`enable` 已經被關掉),這個結果不能代表卡住當下的真實狀態。

重新在**還在卡住的當下**(開第二個 terminal)查:

```bash
sudo ~/csnn-fpga/v4l2_reg /dev/video0 get 0x0   # REG_CONTROL
sudo ~/csnn-fpga/v4l2_reg /dev/video0 get 0x4   # REG_CONFIG
```

**結果**:`REG_CONTROL = 0x1`(`enable`=1,bit0),`REG_CONFIG = 0x3`(`enable_pattern`=1 bit0、`enable_tlast_timeout`=1 bit1)。

**代表**:`enable` 跟 `enable_pattern` 在真正串流的當下都確認是 1,driver 端該寫的暫存器都寫對了。`enable_tlast_timeout` 被打開不是我們手動設的,推測是 driver 的 V4L2 control(`V4L2_CID_XFER_TIMEOUT_ENABLE`,`FPGA/driver/evtdec-dma.c` 附近定義)在初始化時自己寫的,跟本次問題無關,未深究。

照 RTL(`FPGA/EvtDecoder/EvtDecoder.srcs/sources_1/new/EventProcessor.sv:174`)的邏輯:

```systemverilog
assign M_AXIS_TVALID = cfg_enable_pattern ? cfg_enable : (m_valid_q && cfg_enable);
```

`cfg_enable_pattern=1`、`cfg_enable=1` 時,`M_AXIS_TVALID` 理論上應該恆為 1。

### 4. 確認 DMA channel 實際上有沒有完成過任何一次傳輸

```bash
cat /proc/interrupts
```

**結果**(節錄):

```
70:  0  0  0  0  GICv2 122 Level  xilinx-dma-controller
72: 17485 ...    GICv2 124 Level  a0010000.mipi_csi2_rx_subsystem
```

`70` 這行對應 device tree 裡 `dma@a1000000` 的 `interrupts = <0x00 0x5a 0x04>`(`0x5a`=90,GIC SPI 編號 90+32=122,對得上)。**中斷次數是 0,從開機到現在一次都沒發生過。**

對照 `mipi_csi2_rx_subsystem` 那行(IRQ 124)累積 17485 次,證實**感測器→CSI2 接收這段是活的、真的在收資料**,只有我們自己這條 DMA 完全沒有任何完成事件。

**代表**:不是「傳輸比較慢,要多等一下」——1MB buffer(見下一節)在正常速度下應該是毫秒等級就會填滿,`0` 次代表**這個 DMA channel 從來沒有成功完成過一次傳輸**,是硬邏輯層級的問題,不是軟體邏輯卡住。

### 5. 確認 buffer 大小、`tlast` 在 pattern 模式下的行為

`FPGA/driver/evtdec-dma.c:958`:`dma->transfer_size = DEFAULT_PACKET_LENGTH = (1 << 20)`(1MB)。

`EventProcessor.sv:177`:`M_AXIS_TLAST = cfg_enable_pattern ? 1'b0 : m_last_q`——**pattern 模式下 `tlast` 永遠是 0**,DMA 只能靠「整個 1MB buffer 填滿」才會觸發一次傳輸完成,沒有提前結束的機制。

**代表**:以 125MHz、每 clock 一筆估算,1MB 該在約 1 毫秒內填滿。中斷次數是 0,不是「還沒填滿」,是資料根本沒有真的流進 DMA。

### 6. 檢查 `evtdec-dma.c` 的 `start_streaming()`/`buffer_queue()` 邏輯本身

檔案:`FPGA/driver/evtdec-dma.c:446-575` 左右。

**結果**:`dmaengine_prep_slave_single()` 準備描述子 → `dmaengine_submit()` 送出 → `start_streaming()` 裡 `dma_async_issue_pending()`(在啟動 pipeline、寫 `REG_CONTROL.enable=1` **之前**)啟動 DMA engine → 才寫 `enable=1`。中間有 `verify_format()` 檢查格式是否匹配,若不符會讓 `STREAMON` 直接失敗回傳錯誤。

**代表**:因為 `evt_dump` 的 `VIDIOC_STREAMON` 沒有回傳錯誤(前面第 1 點已確認),代表這整段邏輯(含 `verify_format()`)都執行成功,問題不在這段軟體邏輯,執行順序(先啟動 DMA 引擎、再讓 IP 開始送資料)本身也合理,沒有明顯的競態問題。

### 7. 檢查 Vivado block design 接線

檔案:`FPGA/fpga-projects-1.0.0/build/projects/kv260/kv260.srcs/sources_1/bd/kv260/kv260.bd`

**結果**:第 5796-5799 行確認 `fsm_event_extractor_0/M_AXIS` 接到 `axi_dma/S_AXIS_S2MM`,接線存在。

### 8. 檢查 `axi_dma` IP 設定

檔案:`.../kv260.srcs/sources_1/bd/kv260/ip/kv260_axi_dma_0/kv260_axi_dma_0.xci`

**結果**:`c_include_sg=1`(scatter-gather,跟 driver 假設一致)、`c_include_s2mm=1`、`c_s_axis_s2mm_tdata_width=64`(跟我們模組輸出寬度一致)、`c_include_mm2s=0`(不需要,沒開)。設定上看不出問題。

### 9. 檢查 `FsmEventExtractor.sv` 頂層接線

**結果**:`M_AXIS_TVALID`/`TDATA`/`TSTRB`/`TLAST` 從 `EventProcessor` 直接透傳到頂層對外埠,中間沒有額外邏輯、沒有被其他訊號閘控。

### 10. 檢查 IP 封裝(`component.xml`)的 `M_AXIS` bus interface 定義

檔案:`FPGA/ip_repo/fsm_event_extractor/component.xml`

**結果**:`M_AXIS` 正確標記為 `xilinx.com:interface:axis:1.0` / `axis_rtl:1.0`、`spirit:master`,`TDATA`/`TSTRB`/`TLAST`/`TVALID`/`TREADY` 五個訊號的 `portMap` 都正確對應到 `M_AXIS_TDATA` 等實際埠名。看不出封裝層級的問題。

## 重要參考點:`axi_dma` 本身跟 PS 端這套 DMA 使用模式,已知是能動的

`docs/FPGA/Reference/KV260/kv260_operation_notes/genx320_sensor_startup.md` 記錄過:用**官方** `ps_host_if` + `axi_dma` + 官方 PS driver 這條路徑,曾經成功讓 `metavision_viewer` 即時顯示 320x320 事件畫面。代表 `axi_dma` 這顆 IP、以及「driver 呼叫 `dma_request_chan()`+`dmaengine_prep_slave_single()` 這套標準用法」本身是驗證過可以動的,問題範圍可以縮小到:**我們自己的 `fsm_event_extractor`/`FsmEventExtractor.sv` 這顆 IP,或它跟 `axi_dma` 之間的實際硬體行為,而不是 `axi_dma` 或 driver 的 DMA 處理邏輯本身。**

### 11. 對照官方 `ps_host_if` 的 pattern 模式怎麼做(`axi4s_packetizer.vhd`)

檔案:`FPGA/fpga-projects-1.0.0/ip/ps_host_if_3_0/hdl/axi4s_packetizer.vhd`

**結果**:官方的 pattern 模式**只替換資料內容,不是獨立的資料來源**——`m_axis_tvalid_mux_s <= buffer_valid_q or s_axis_tvalid`(line 105),整個輸出暫存器的更新(含 pattern counter 遞增)都掛在 `m_axis_tvalid_mux_s = '1'` 這個條件下(line 182),也就是說**官方的假資料一樣要靠真實上游輸入才會被觸發輸出**,不是憑空吐資料。而且官方原本想過的優化(「pattern 模式時 ready 強制拉高避免對 MIPI 反壓」,line 97-98)是被**註解掉、沒有採用**的。

對照我們的 `EventProcessor.sv:174`:`M_AXIS_TVALID = cfg_enable_pattern ? cfg_enable : (...)`,是完全獨立於真實輸入的組合邏輯設計,跟官方的「搭真實資料便車」哲學不同。

**代表**:這是一個真實的設計差異,但**沒有解釋這次的卡住**——因為理論上我們的設計應該更寬鬆(不需要真實輸入就該送資料),而且測試當下真實感測器資料其實一直在流動(`mipi_csi2_rx_subsystem` 中斷次數持續增加)。這個發現當下沒有直接定位到 root cause,但保留這個比對記錄。

### 12. 已排除的理論(用既有資料反推,不用重新驗證)

- **時脈沒在動**:`FsmConfigSetter`(AXI-Lite 控制邏輯)、`EventProcessor`(資料通道邏輯)共用同一個 `AXIS_ACLK` 埠(`FsmEventExtractor.sv` 只有一個時脈輸入)。AXI-Lite 讀寫正常運作(`v4l2_reg` 讀回值都對),證實這顆時脈確實有在跳動。
- **`soft_reset` 卡住**:第 3 節查到 `REG_CONTROL = 0x1`,bit1(`soft_reset`)是 0,沒有卡在重置狀態。
- **頂層 `AXIS_ARESETN` 卡住**:`FsmConfigSetter` 的 `S_AXI_ARESETN` 直接接頂層 `AXIS_ARESETN`(不受 `soft_reset` 影響,`FsmEventExtractor.sv:138` 有寫理由),AXI-Lite 正常運作證實這條線沒有卡住,連帶 `EventProcessor` 用的 `rstn_core = AXIS_ARESETN && !cfg_soft_reset` 也不會卡。

### 13. `/sys/kernel/debug/dmaengine/` 即時狀態

**結果**:`summary` 顯示 `dma17 (a1000000.dma): ... dma17chan0 | a0030000.evtdec:port0`——證實 driver 端確實有正確跟 `dmaengine` 框架要到 channel,channel 名稱、掛載都對。`a1000000.dma/` 資料夾底下沒有更細的統計檔案(空的),這個 driver 沒有暴露更詳細的除錯資訊,這條路查到底,沒有更多情報。

### 14. 用真實感測器資料測試(關掉 `enable_pattern`)——問題重現範圍確認

```bash
sudo ~/csnn-fpga/v4l2_reg /dev/video0 set 0x4 0x0
~/csnn-fpga/evt_dump /dev/video0 20
```

**結果**:立刻收到 20 筆合理的事件資料,見本文件最上方「2026-08-17 更新」。

**代表**:M_AXIS→`axi_dma`→driver→V4L2 這整條共用路徑是通的、沒有問題。問題**精確定位在 `enable_pattern=1` 時的輸出邏輯**(`EventProcessor.sv:170-177` 那段 mux),不是更底層、更大範圍的東西。

## 結論(2026-08-17 更新)

**核心功能已驗證正常,不再需要緊急處理。** `enable_pattern` 本身還有 bug 沒修好,但只影響這個除錯用的假資料模式,優先度低,可以之後有空再查。

如果之後要繼續查,範圍已經縮小很多,靜態檢查(讀原始碼)在原本「整條路徑不通」的假設下已經到極限,現在既然知道問題精確侷限在 pattern mode 的 mux 邏輯,值得優先嘗試:
- 用 Vivado ILA 只需要盯 `fsm_event_extractor_0` 內部的 `pattern_ctr_q`、`M_AXIS_TVALID`、`M_AXIS_TREADY`,範圍比原本設想的小很多
- 或者乾脆放棄目前這種「組合邏輯、完全獨立於真實輸入」的 pattern 模式設計,改成跟官方一樣「借用真實輸入的 valid 脈衝,只換內容」的做法——反正真實資料路徑已經證實沒問題,兩種做法擇一改寫都不難

## 尚未查證/可能值得後續檢查的方向(未深入,先記錄)

- `axi_dma` 是否需要先看到至少一個有效的 SG 描述子才會拉高 `S_AXIS_S2MM_TREADY`(如果有此類前提條件,需要跟 `dmaengine_submit`/`dma_async_issue_pending()` 的時序對照)——本次只確認了 driver 呼叫順序看起來合理,沒有實際驗證 `axi_dma` IP 內部的真實時序要求
- `M_AXIS_TSTRB` 沒有對應 `TKEEP`,`axi_dma` 端是否預期 `TKEEP` 而非 `TSTRB`,兩者是否可能被自動視為等價——未查證
- Clock domain:`fsm_event_extractor` 跟 `axi_dma` 是否共用同一個 `AXIS_ACLK`(`.bd` 裡兩者的 clock 訊號連線,本次只確認接線存在,沒有逐一核對是否都接到同一個實體時脈源)
