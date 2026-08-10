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
2. **PL→PS 傳輸介面**:AXI DMA,kernel driver 未動工,依賴下方問題 2、3。
3. **bias 設定工具**:獨立小程式,對 sensor subdev 下 `VIDIOC_S_CTRL`,不依賴 `metavision_viewer`。

## 解碼模組實作步驟(依序做,由使用者實作,這裡只列順序跟每步的驗收標準)

1. **建 RTL 專案目錄結構**:`hdl/`(原始碼)、`sim/`(testbench)分開,先決定好放哪裡再開始寫檔案。
2. **bit-scan 組合邏輯**(最小單元,先從這裡開始):輸入 `mask_q`(32-bit),輸出「最低位的 1 在哪個 offset」+「清掉那個 bit 後的新 mask」。純組合邏輯,不含狀態,最容易獨立寫 testbench 驗證。驗收:餵幾組手算過的 `vx_f`(如查證筆記範例 `0x00000003`),offset 序列跟清 bit 後的值要跟手算一致。
3. **展開狀態機主體**(`S_FETCH`/`S_EXPAND`):接上一步的 bit-scan,加上:
   - `type_f` dispatch(`0x0`/`0x1`=TD、`0x8`=TIME_HIGH、其他丟棄)
   - `time_valid_q` guard(reset 後沒收過 TIME_HIGH 之前,TD 事件要丟棄)
   - 暫存器:`time_high_q`、`x_f_q`/`y_f_q`/`type_q`/`t_q`、`mask_q`
   驗收:對照 [`Concept/ps_host_if_replacement_notes.md`](../Concept/ps_host_if_replacement_notes.md)「展開狀態機」那張轉移表,每一列轉移條件都要有對應的 testbench case,包含「reset 後第一筆是 TD、還沒收過 TIME_HIGH」這個邊界情況。
4. **輸入端 FIFO**:深度 16,存原始 64-bit 封包(不是解碼後的資料),接在 ESST 跟展開狀態機之間,標準同步 AXI4-Stream FIFO。
5. **FIFO + 展開狀態機整合**,加上輸出端 `flush_timer_q` + 提前掛 `tlast` 的機制(見 Concept 筆記「定案:不做心跳」那節)。
6. **AXI-Lite slave 介面**:`REG_CONTROL`(enable/reset/clear)、`REG_CONFIG.enable_pattern`(假資料模式)、`REG_TLAST_TIMEOUT`、除錯讀寫後門。
7. **頂層模組**:把 4~6 包成一個對外只留 `s_axis`/`m_axis`/`s_axi_lite` 的模組,對應要接的位置是 `event_stream_smart_t_0/m_axis → [這個模組] → axi_dma/S_AXIS_S2MM`。
8. **Testbench 驗證**:不要等 3~7 全部寫完才測,每步都要有對應 testbench;整合後再跑一次「真實封包序列」測試(TD 混 TIME_HIGH 混 OTHERS、多 bit mask、reset 後首筆該丟棄)。
9. **Vivado block design 整合**:換掉 `ps_host_if_0`,接線見 Concept 筆記「Vivado block design」那節。
10. **上板驗證**:先用 `REG_CONFIG.enable_pattern` 假資料測完「`axi_dma` → kernel driver → PS 軟體」這條路,確認通了再接真感測器,避免同時除錯 RTL 邏輯跟資料路徑兩個問題。
11. **Kernel driver**:仿 `psee-composite.c`(V4L2 media graph)+ `psee-dma.c`(`dma_request_chan` 接 `xilinx_dma`)兩層模式。

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
- FIFO 深度(16 筆)不能做成動態可調——是實體記憶體大小,合成時就決定了,不是邏輯參數

## 查證細節

原始碼引用、行號、完整推理過程都在 [`Concept/ps_host_if_replacement_notes.md`](../Concept/ps_host_if_replacement_notes.md)。
