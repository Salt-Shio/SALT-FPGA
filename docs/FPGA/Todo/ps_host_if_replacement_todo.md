# FPGA:ps_host_if 替換——TODO

## 要做什麼

寫 RTL 模組取代官方 `ps_host_if`,讓 GenX320 事件資料在 PL 端直接解碼成 `(x, y, type, t)`,送 PS。CSNN 是未來分支,現在不用管、不用預留介面([`csnn_pl_implementation_todo.md`](../../SNN/Todo/csnn_pl_implementation_todo.md))。

## 資料路徑

```
GenX320 → MIPI CSI-2 RX → axis_tkeep_handler → ESST →
[新模組] 解碼 → (x, y, type, t) →
[新模組] PL→PS 傳輸介面 → PS 端軟體
```

前三顆保留不動,不解讀事件內容。只換 `ps_host_if` 那一段。

## 具體任務

1. **解碼模組**:輸入 ESST 的 AXI4-Stream(64-bit,EVT2.1),輸出 `(x,y,type,t)`,`t` 微秒。`type_f==0x0/0x1` 是 TD,展開;`0x8` 只更新內部時間、不輸出;`0xE` 丟棄。
2. **PL→PS 傳輸介面**:AXI DMA,kernel driver 未動工,依賴下方問題 1、2。
3. **bias 設定工具**:獨立小程式,對 sensor subdev 下 `VIDIOC_S_CTRL`,不依賴 `metavision_viewer`。

## 解碼模組實作步驟(依序做,由使用者實作,這裡只列順序跟每步的驗收標準)

目前進度:1~8(RTL 邏輯 + 模擬驗證)已完成,全部在 xsim 上跑過 testbench 確認 PASS。**下一步是 9(Vivado block design 整合)**,9~11(上板、kernel driver)都還沒開始,這些需要接觸實體硬體/PetaLinux 環境,模擬驗證不能取代。

1. **建 RTL 專案目錄結構**(已完成):`EvtDecoder.srcs/sources_1/new/`(原始碼)、`EvtDecoder.sim/sim_1/new/`(testbench)分開。
2. **bit-scan 組合邏輯**(已完成):`EventProcessor.sv` 裡的 `x_offset` 低位優先編碼器,`tb_event_processor.sv` 驗證過。
3. **展開狀態機主體**(已完成):`EventProcessor.sv` 的 `S_FETCH`/`S_EXPAND` FSM,含 `type_f` dispatch、`time_valid_q` guard,`tb_event_processor.sv` Test 1~8 涵蓋轉移表各種情況與邊界情況(reset 後首筆 TD 該丟棄)。
4. **輸入端 FIFO**(已完成):`axis_data_fifo_0` IP(16 深),接在 `FsmEventExtractor.sv` 裡。
5. **FIFO + 展開狀態機整合 + flush_timer/tlast**(已完成):`FsmEventExtractor.sv` 接線,`EventProcessor.sv` 的 `flush_timer_q`/`tlast_due` 邏輯,`REG_CONFIG.tlast_timeout_enable` + `REG_TLAST_TIMEOUT` 非 0 預設值雙重防線也已補上並測試。
6. **AXI-Lite slave 介面**(已完成):`FsmConfigSetter.sv`,`REG_CONTROL`/`REG_CONFIG`/`REG_TLAST_TIMEOUT`/除錯後門都有,AR/R channel 額外做過 back-to-back 讀取優化(組合邏輯算 `ARREADY`,實測比原始 latch 設計與官方 `ps_host_if_reg_bank` 都快一倍)。
7. **頂層模組**(已完成):`FsmEventExtractor.sv`,對外只留 `s_axis`/`m_axis`/`s_axi_lite`。
8. **Testbench 驗證**(已完成):`tb_fsm_config_setter.sv`(隨機化 master 行為 + protocol checker + reset 預設值檢查)、`tb_event_processor.sv`(隨機事件 + backpressure)、`tb_fsm_event_extractor.sv`(整合測試,真實 EVT2.1 封包序列 + FIFO 反壓驗證)全部 `ALL PASS`。
9. **Vivado block design 整合**(尚未開始):換掉 `ps_host_if_0`,接線見 Concept 筆記「Vivado block design」那節。
10. **上板驗證**(尚未開始):先用 `REG_CONFIG.enable_pattern` 假資料測完「`axi_dma` → kernel driver → PS 軟體」這條路,確認通了再接真感測器,避免同時除錯 RTL 邏輯跟資料路徑兩個問題。
11. **Kernel driver**(尚未開始):仿 `psee-composite.c`(V4L2 media graph)+ `psee-dma.c`(`dma_request_chan` 接 `xilinx_dma`)兩層模式。

## 待解決問題(依序處理)

1. Device tree / `xmutil loadapp` 打包格式未查。
2. Kernel driver 編譯/部署環境(PetaLinux/Yocto)未查。

## 已定案,不用重問

- 解碼模組只輸出一個 `(x,y,type,t)` 串流,不分流給 CSNN,以後要接 CSNN 是重新接線的事
- `t` 用微秒
- bias 設定獨立於 `ps_host_if`,走不同裝置節點
- PL→PS 傳輸走 **AXI DMA**;解碼模組**內部**另有一個 FIFO(見下),兩者不衝突
- TD 事件 type 是 `0x0`(負極性)/`0x1`(正極性),不是 `0x0`/`0x4`
- `0xE`(OTHERS)不併入輸出,直接丟棄
- 架構:`ESST → 同步 AXI4-Stream FIFO(存原始封包)→ 展開狀態機(每 clk 最多吐一筆)→ axi_dma`
- 展開演算法:找最低位的 1 → 吐一筆 → 清 bit → 重複到 mask 歸零(對照 PS 端 `evt21_decoder.h`)
- `time_high` race 靠「一筆處理完才拿下一筆」這個規則避免,不用額外 latch
- 輸出端不需要額外 FIFO,標準 `tvalid`/`tready` 就夠
- clock 是 `pl_clk0`(~125MHz),ESST/展開狀態機/`axi_dma` 同一個 domain
- 新模組接在 `event_stream_smart_t_0/m_axis → ps_host_if_0` 原本的位置,輸出接現成的 `axi_dma/S_AXIS_S2MM`,不用重新設計 DMA 子系統
- Kernel driver 仿 `psee-composite.c`(建 V4L2 media graph)+ `psee-dma.c`(`dma_request_chan()` 接標準 `xilinx_dma` dmaengine driver)的兩層模式
- `evt21_smart_drop` 掉包門檻:離新模組最近的內部 FIFO 填 5/64 筆就觸發「只留 TIME_HIGH」,填到 11/16 筆才「全部丟」。數字是 ESST generic(可調),新模組幾乎不能對 ESST 反壓超過幾個 cycle
- 展開狀態機 FSM 定案:2 個狀態(`S_FETCH`/`S_EXPAND`,1 bit 編碼),含 `time_valid_q` 防止 reset 後第一筆 TD 事件用到未初始化的 `time_high_q`。FIFO 深度定案 16 筆(0~15,4-bit 指標)。完整轉移規則、暫存器列表、圖見 [`Concept/ps_host_if_replacement_notes.md`](../Concept/ps_host_if_replacement_notes.md)
- 輸出端 flush 機制定案:不做心跳、不合成 filler event(PS 端可以接受完全靜默時一直等)。只用一顆逾時計時器,吐真事件時如果計時器超過門檻就在那筆事件上掛 `tlast=1` 提前結束這次 DMA 傳輸,沒超過正常送。完全沒事件時計時器繼續累加但不做任何事,下一筆真事件出現時會立刻被掛 `tlast`
- 新模組需要 AXI-Lite slave 介面,不是只有 AXI4-Stream。最少要有 `REG_CONTROL`(enable/reset/clear,對照 `psee-dma.c` 實際用法:`reset` 只在 driver 初始化用一次、`enable` 對應 `STREAMON`/`STREAMOFF`、`clear` 在 `STREAMOFF` 時一起用來清空 FIFO 裡的舊資料)。逾時門檻做成 `REG_TLAST_TIMEOUT` 這種 PS 可調的暫存器,不寫死——理由:AXI-Lite 介面反正都要做,多一個暫存器成本很低,寫死的話以後要調數字得重新合成整個 FPGA,划不來
- 額外加兩個除錯用暫存器,理由同上(AXI-Lite 已經在,多開成本低):`REG_CONFIG.enable_pattern`(吐假 `(x,y,type,t)`,不用等解碼邏輯寫完、不用接真感測器就能測 DMA→kernel driver→PS 軟體這條路,對照 `ps_host_if` 同名機制)、原始暫存器讀寫後門(`g_register`/`s_register`,對照 ESST/`ps_host_if` 的 `CONFIG_VIDEO_ADV_DEBUG` 模式)
- `REG_CONFIG` 新增 `bit1=tlast_timeout_enable`,reset 預設 0(關閉);`REG_TLAST_TIMEOUT` reset 預設值改成非 0(125MHz 下 100us,即 `16'd12500`)。兩者是雙重防線,理由:對照官方 `ps_host_if_reg_bank` 的 `CONFIG_TIMEOUT_ENABLE_DEFAULT`(預設關閉)+ `TIMEOUT_VALUE_DEFAULT`(非 0),避免我們原本的設計(沒有 enable 位元、`REG_TLAST_TIMEOUT` reset 為 0)在 reset 完、PS 端還沒來得及寫入設定值之前,`flush_timer_q(0) >= cfg_tlast_timeout(0)` 恆成立,導致每一筆事件都被迫掛 `tlast`。PS 端驅動要記得在 `STREAMON`(`REG_CONTROL.enable=1`)之前或同時把這個位元跟門檻值設好,避免踩到同樣的空窗期。
- FIFO 深度(16 筆)不能做成動態可調——是實體記憶體大小,合成時就決定了,不是邏輯參數

## 查證細節

原始碼引用、行號、完整推理過程都在 [`Concept/ps_host_if_replacement_notes.md`](../Concept/ps_host_if_replacement_notes.md)。
