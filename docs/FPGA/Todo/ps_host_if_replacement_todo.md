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

1. **解碼模組**(已完成、已上板驗證):輸入 ESST 的 AXI4-Stream(64-bit,EVT2.1),輸出 `(x,y,type,t)`,`t` 微秒。`type_f==0x0/0x1` 是 TD,展開;`0x8` 只更新內部時間、不輸出;`0xE` 丟棄。
2. **PL→PS 傳輸介面**(已完成、已上板驗證):AXI DMA + kernel driver(`FPGA/driver/`),細節見下方項目 11。
3. **bias 設定工具**(**尚未開始**):獨立小程式,對 sensor subdev 下 `VIDIOC_S_CTRL`,不依賴 `metavision_viewer`。`FPGA/tools/` 底下目前只有 `evt_dump`、`v4l2_reg`,還沒有這支。
4. **事件讀取驗證程式**(已完成、已上板驗證):`FPGA/tools/evt_dump/`,`open`/`mmap` V4L2 capture 裝置,依 `EventProcessor.sv:143` 的實際 bit 排列印出 `(x,y,type,t)`,不做 EVT2.1 解碼(PL 端已解碼完)。細節見 `FPGA/tools/evt_dump/README.md`。
5. **evt_dump 資料視覺化**(**已完成,(a)(b)(c) 都驗證過**):原本只 `printf` 純文字,看不出事件在畫面上的空間/時間分布是否合理。已定案:不轉 CSV(PL 端輸出本來就是固定 8 bytes/筆的二進位格式),整塊 buffer 直接 `write()` 存成原始二進位;存檔位置寫 `/tmp`(RAM,tmpfs)不寫 SD 卡(`/home/petalinux` 那個掛載點)——SD 卡實測持續寫入只有 10.6 MB/s,查到的文件極端值(規格上限 10 Meps=80 MB/s、失焦壞情況 13.8 Mev/s=110 MB/s)都超過這個速度,但**子彈飛行這種實際場景會落在哪個量級還沒實測,不能拿極端值當定案依據**——先寫 `/tmp` 這個決定本身成本是零(反正哪裡都要寫),但存檔上限(時間/筆數)、要不要擔心 SD 卡瓶頸,等實測出真實場景事件率再定。視覺化演算法參考 `docs/FPGA/Reference/KV260/openeb` 官方作法(`PeriodicFrameGenerationAlgorithm`:固定時間窗口內累積事件、依極性畫兩色+背景色成一張影像,串起來看軌跡),不用自己從頭設計。查證細節見 Concept 筆記「`evt_dump` 資料視覺化擷取」那節。進度:(b) 已改完 `evt_dump.c`——加 `-o <path>`(整塊 `write()` 存原始二進位)、`-t <seconds>`(時間上限,沿用既有 `-n <count>`)、每秒事件率統計 + 結束總結(events/s、MB/s),WSL 交叉編譯 `-Wall -Wextra` 乾淨無警告,**已上板實測跑過,功能正常**(細節見 `FPGA/tools/evt_dump/README.md`)。

(a) 已量到兩組真實數字:

1. `evt_dump`(2026-08-17,我們自己的 evtdec 管線,**驅動預設 bias**,人在鏡頭前走動,非子彈飛行):`737011 events, 5896088 bytes, 5.270 s elapsed, avg 139859 events/s, avg 1.07 MB/s`。
2. 官方 `metavision_viewer`(2026-08-17,官方 `ps_host_if` 管線,**校準過的低雜訊 bias `genx320es_CD_standard.bias`**,人持續移動):目測「基本上 1M events/s 以下,人一直動也大概幾百 K」。

兩組數字量級一致(數十萬到約 1M events/s,換算 1~8 MB/s),**都在 SD 卡實測寫入速度(10.6 MB/s)範圍內**,確認 SD 卡瓶頸在正常場景下不成立,不需要额外做記憶體緩衝那層。**這兩組都是人體動作、不是子彈飛行**,子彈更小更快、事件會更集中在短暫瞬間,瞬時峰值可能比這裡量到的更高,但已經有兩個獨立管線、不同 bias 條件量到的數字互相印證同一個量級,不算是孤例。之後如果真的用子彈飛行場景驗證,重點看瞬間峰值(`evt_dump` 的 `[rate]` 那行)而不是平均值。

(c) 已完成、使用者已上機確認可用:`scripts/evt_visualize.py`(本機端,`snn` conda 環境)。讀 `evt_dump -o` 存的 `.bin`,numpy 向量化拆 x/y/type/t,依 `--accum-us`(預設 10000,跟官方 `metavision_viewer` 寫死的累積窗口一致)切非重疊時間窗口,同像素多筆事件時間序覆寫(last-write-wins),渲染成 320×320 影像(ON=紅、OFF=藍、背景=白)。播放邏輯照抄 `D:\Project\SNN\main\debug.py` 的 `Slider` + 方向鍵單步 + 空白鍵播放/暫停寫法(不是 `FuncAnimation`),真實時間播放——每張圖停留時間等於它代表的 `accum-us` 長度,總長度等於原始擷取時長。用實際錄到的 7,236,879 筆事件(9.999568 秒)測過,讀檔 0.1 秒、切 1000 張 frame 只要 0.12 秒。MP4 存檔功能討論過,決定先不做,之後真有需要再加(`matplotlib` 已確認能抓到系統 `ffmpeg.exe`,不用額外裝套件)。

## 解碼模組實作步驟(依序做,由使用者實作,這裡只列順序跟每步的驗收標準)

目前進度:1~11 全部完成,已上板驗證通過(含 `enable_pattern` bug 修復)。**核心目標已達成**,剩下的開放項目見「具體任務」第 3 項(bias 設定工具,尚未開始)。

kernel driver 這塊的工作在獨立的 `ps-driver` git 分支上進行,原始碼位置開在 `FPGA/driver/`(跟 PL 端的 `FPGA/EvtDecoder` 平行),已把 `psee-composite.c`/`psee-dma.c` 這對(對應官方 `psee-video.ko`)原封不動複製進去當起點,還沒開始改暫存器配置,細節見 `FPGA/driver/README.md`。編譯規劃:本機(Windows)只寫程式碼,原本規劃實際編譯用 WSL(Ubuntu-22.04)交叉編譯,PetaLinux SDK 目前裝在 KV260 板子上、板子還沒接上。**已查證(2026-08-14)**:WSL 裡有裝 `aarch64-linux-gnu-gcc`,但沒有任何完整 kernel source tree(`/lib/modules/$(uname -r)/build` 不存在、`/usr/src` 是空的、`$KERNEL_SRC` 未設),driver Makefile 是標準 Kbuild 模式(`make -C $(KERNEL_SRC) M=$(SRC)`),沒有 kernel source tree 跑不起來。而且就算裝 Ubuntu 通用的 `linux-headers-$(uname -r)` 也沒用——`evtdec-dma.c` 用到 `<linux/dma/xilinx_dma.h>`,這是 Xilinx `linux-xlnx` fork 專屬的 header,不在主線 kernel 裡。**結論**:WSL 目前這個環境編不出來,語法檢查/編譯得等板子連上、直接用板子上的 PetaLinux SDK,或另外拉一份跟板子版本一致的 `linux-xlnx`(`kv260-2022.2` 對應 tag)在 WSL 裡搭出 Kbuild 環境,兩條路都還沒做。

1. **建 RTL 專案目錄結構**(已完成):`EvtDecoder.srcs/sources_1/new/`(原始碼)、`EvtDecoder.sim/sim_1/new/`(testbench)分開。
2. **bit-scan 組合邏輯**(已完成):`EventProcessor.sv` 裡的 `x_offset` 低位優先編碼器,`tb_event_processor.sv` 驗證過。
3. **展開狀態機主體**(已完成):`EventProcessor.sv` 的 `S_FETCH`/`S_EXPAND` FSM,含 `type_f` dispatch、`time_valid_q` guard,`tb_event_processor.sv` Test 1~8 涵蓋轉移表各種情況與邊界情況(reset 後首筆 TD 該丟棄)。
4. **輸入端 FIFO**(已完成):`axis_data_fifo_0` IP(16 深),接在 `FsmEventExtractor.sv` 裡。
5. **FIFO + 展開狀態機整合 + flush_timer/tlast**(已完成):`FsmEventExtractor.sv` 接線,`EventProcessor.sv` 的 `flush_timer_q`/`tlast_due` 邏輯,`REG_CONFIG.tlast_timeout_enable` + `REG_TLAST_TIMEOUT` 非 0 預設值雙重防線也已補上並測試。
6. **AXI-Lite slave 介面**(已完成):`FsmConfigSetter.sv`,`REG_CONTROL`/`REG_CONFIG`/`REG_TLAST_TIMEOUT`/除錯後門都有,AR/R channel 額外做過 back-to-back 讀取優化(組合邏輯算 `ARREADY`,實測比原始 latch 設計與官方 `ps_host_if_reg_bank` 都快一倍)。
7. **頂層模組**(已完成):`FsmEventExtractor.sv`,對外只留 `s_axis`/`m_axis`/`s_axi_lite`。
8. **Testbench 驗證**(已完成):`tb_fsm_config_setter.sv`(隨機化 master 行為 + protocol checker + reset 預設值檢查)、`tb_event_processor.sv`(隨機事件 + backpressure)、`tb_fsm_event_extractor.sv`(整合測試,真實 EVT2.1 封包序列 + FIFO 反壓驗證)全部 `ALL PASS`。
9. **Vivado block design 整合**(已完成):`FsmEventExtractor` 封裝成 IP(`csnn-fpga.local:ip:fsm_event_extractor:1.0`,位於 `FPGA/ip_repo/fsm_event_extractor`),在 `kv260` block design 裡換掉 `ps_host_if_0`,接線、AXI-Lite 位址(`0xA0030000`,range 128)、clock 關聯都已修正,`validate_bd_design` 與 `Generate Output Products` 皆乾淨通過。細節見 Concept 筆記「Vivado block design 整合(2026-08-12)」那節。
10. **上板驗證**(2026-08-17,核心功能已成功、`enable_pattern` bug 已修復):真實感測器資料**整條路徑成功跑通**:`genx320 → mipi_csi2_rx_subsystem → axis_tkeep_handler → event_stream_smart_tracker → evtdec(FsmEventExtractor 真實解碼)→ axi_dma → evtdec-video driver → /dev/video0 → evt_dump`,印出的 `(x,y,type,t)` 數值合理(`x`/`y` 落在 0~319、`type` 是 0/1、`t` 遞增)。**這是專案核心目標(PL 端直接解碼 GenX320 事件資料取代 `ps_host_if`)首次端到端驗證成功。** `enable_pattern` 假資料模式原本卡住收不到資料,根本原因是 `EventProcessor.sv` 在 pattern 模式下 `M_AXIS_TLAST` 寫死成 0、AXI DMA S2MM 永遠等不到 `TLAST` 無法完成 transfer,已修好(pattern 模式改用 `pattern_ctr_q` 每 2048 筆回捲掛一次 tlast)並重新合成上板驗證通過。細節、完整除錯過程見 `FPGA/BUG/evtdec_pattern_no_dma_transfer.md`。
11. **Kernel driver**(程式碼已改完、已人工 code review 過、**已編譯成功、已通過基本上板 insmod 測試**):`FPGA/driver/evtdec-composite.c`/`evtdec-dma.c`,從 `psee-composite.c`/`psee-dma.c` 改寫——暫存器對照 `FsmConfigSetter.sv`(不是官方 `ps_host_if` 配置)、套用官方 `avoid-descriptor-link-corruption.patch`、新增 `V4L2_PIX_FMT_CSNN_XYT`、DT compatible 改成 `csnn-fpga,evt-decoder`。細節見 `FPGA/driver/README.md`。
    - Code review(2026-08-13)已找到並修好兩個問題:(1) `timeout_threshold_control` 的微秒範圍是照抄官方的,沒配合我們縮小成 16-bit 的 `REG_TLAST_TIMEOUT`,預設值換算後會溢位、且預設就會自動啟用 timeout,已改成配 16-bit 的範圍(`evtdec-dma.c` `timeout_s_ctrl`/`timeout_threshold_control`)。(2) `stop_streaming()` 重新 `dma_request_chan()` 沒檢查失敗(官方 patch 本身就沒檢查),已補上錯誤 log 跟 `start_streaming()`/`buffer_queue()` 兩處的防呆。`evtdec-composite.c` review 過,邏輯跟官方完全一致,只改了字串(`compatible`/`MODULE_*`),沒有新問題。
    - 已 commit(`a55fd6e` 等,`ps-driver` branch)。
    - **已解決(2026-08-14)**:WSL 交叉編譯環境已成功搭建,`FPGA/driver` 已編譯成功。做法:從官方 `Xilinx/meta-xilinx` repo 的 `linux-xlnx_2022.2.bb` recipe 查到板子那顆 kernel(`5.15.36-xilinx-v2022.2`)precise 對應的 `linux-xlnx` commit(`19984dd147fa7fbb7cb14b17400263ad0925c189`,branch `xlnx_rebase_v5.15_LTS`),在 WSL(`/home/salt/petalinux/linux-xlnx`)checkout 這個 commit;板子的 `/proc/config.gz` 複製過來當 `.config`(理由:原始碼樹內建的 `xilinx_defconfig` 只是「未疊加」的通用版,Yocto 建置流程會疊加額外設定片段,只有板子上跑出來的成品 `.config` 才跟實際系統一致);跑 `make olddefconfig`(需要先 `apt install flex bison`)+ `make modules_prepare`(不會生出 `Module.symvers`——官方文件明載這是預期行為,需完整 kernel build 才有,而板子 `CONFIG_MODVERSIONS` 本來就沒開,不影響能不能編)。編譯結果:`evtdec-video.ko` 產出,`modinfo` 確認 `vermagic: 5.15.36-xilinx-v2022.2 SMP mod_unload aarch64` 與板子完全一致;依賴的子系統(`CONFIG_MEDIA_CONTROLLER`/`CONFIG_VIDEO_V4L2`/`CONFIG_VIDEOBUF2_*`/`CONFIG_XILINX_DMA`)在板子上皆為 `=y` 內建,不缺額外 `.ko`。
    - **已解決(2026-08-14)**:板子上 `insmod`/`rmmod` 測試通過。`scp` 把 `evtdec-video.ko` 複製到板子,`sudo insmod` 載入後 `lsmod` 確認 `evtdec_video` 出現、`Used by 0`;`dmesg`(含 `grep -i evtdec` 全域搜尋,board uptime 3h23m 都涵蓋到)完全沒有任何相關訊息,板子全程沒當機。這是預期結果——目前板子跑的是出廠預設 `k26-starter-kits` shell,device tree 裡沒有 `csnn-fpga,evt-decoder` 節點,driver 用 `module_platform_driver()`,`insmod` 只會呼叫 `platform_driver_register()` 登記進 kernel,不會觸發 `probe()`(真正碰硬體暫存器的邏輯),所以這步只驗證了「模組本身沒有讓 kernel 拒絕載入或崩潰」,**還沒驗證 probe 邏輯、還沒接到真正的硬體**。`sudo rmmod evtdec_video` 卸載也確認乾淨(`lsmod` 查不到、`dmesg` 無錯誤)。
    - **已解決(2026-08-17)**:`probe()` 已正常跑起來、驗證通過。自己的 device tree overlay(`FPGA/app_bundle/csnn-fpga-evtdec/`)已生成、打包成 accelerated application bundle 上板,`xmutil loadapp` 切換正常,`media-ctl -p` 顯示完整 media graph `[ENABLED]`。上板驗證結果見項目 10。

## 待解決問題(依序處理)

1. **已解決(2026-08-14,SSH 進板子唯讀確認)**:Devicetree 節點格式已查到(`psee,axi4s-packetizer` binding)。app bundle 實際結構已在板子上直接看到,不用再猜:`/lib/firmware/xilinx/prophesee-kv260-genx320/` 底下只有三個檔案——`prophesee-kv260-genx320.bit.bin`(7.8MB)、`prophesee-kv260-genx320.dtbo`(11970 bytes)、`shell.json`(內容只有 `{"shell_type":"XRT_FLAT","num_slots":"1"}`)。**沒有 `.xclbin`**,證實這個案例不需要它。同目錄下還有 `prophesee-kv260-imx636`(另一個感測器型號,不用管)、`axi_gpio_led`/`base`/`led_shine`/`k26-starter-kits`(廠測小 app)。`xmutil listapps` 需要 root 權限才能執行(見下方「上板環境現況」)。
2. **已解決**:Prophesee 官方 PetaLinux 專案(`github.com/prophesee-ai/petalinux-projects`,分支 `kv260-2022.2`)裡的 `psee-video_2.0.0.bb` 就是真實範例——標準 `inherit module`,`SRC_URI` 指到 `zynq-video-drivers` git repo。額外確認:本地 `docs/FPGA/Reference/KV260/zynq-video-drivers` 版本(`kernel-5.15` 分支)剛好就是這份 recipe 釘死的 commit,版本上跟板子一致,不用擔心對不上;但板子上多疊了一個 `avoid-descriptor-link-corruption.patch`(修 DMA 停止時 descriptor 亂序),我們自己的 `psee-dma.c` 要一併帶上這個修法。細節見 Concept 筆記。
3. **已解決(2026-08-14)**:PL 端真實 device tree 節點內容,不用等 root 權限、不用等切換 app,直接反編譯板子上全域可讀的 `/lib/firmware/xilinx/prophesee-kv260-genx320/prophesee-kv260-genx320.dtbo`(`dtc -I dtb -O dts`)就拿到了。`ps_host_if` 真實節點的 `reg`(`0xa0030000`/range `0x80`)、`clocks`(`<&zynqmp_clk 71>`,雙重確認)、`dmas`/`dma-names`、`ports/port@0/endpoint` 全部跟我們的 block design 設計一致(因為 `fsm_event_extractor` 刻意接在 `ps_host_if_0` 原本的位置,位址、上游、DMA 都沒換)。**結論**:我們自己的 device tree 節點,拿這份反編譯結果當底稿,只改節點名稱跟 `compatible` 字串(`"psee,axi4s-packetizer"` → `"csnn-fpga,evt-decoder"`),其餘照抄,用 `dtc -@ -I dts -O dtb` 重新編譯,原始碼在 `FPGA/app_bundle/csnn-fpga-evtdec/csnn-fpga-evtdec.dts`。**已驗證(2026-08-17)**:編出來的 `.dtbo` 實際上板 `xmutil loadapp` 正常動作,`media-ctl -p` 顯示完整 media graph `[ENABLED]`。額外確認:`__symbols__` 裡的 label(`ps_host_if_0`、`event_stream_smart_t_0`)跟 Vivado block design instance 名稱一致,證實 PL 端節點是工具讀 block design 自動生成,不是手寫。細節、完整反編譯節點內容見 Concept 筆記。

## 上板環境現況

- 板子:`Linux xilinx-kv260-starterkit-20222 5.15.36-xilinx-v2022.2`,PetaLinux `2022.2_release_S10071807 (honister)`
- SD 卡是 32G,根分割區(`mmcblk1p2`)只切了 4G,另外約 23.5G 未分割——image 建置時分割區大小寫死,不影響目前的工作
- 板子上**沒有 `gcc`、沒有 kernel headers**(`/lib/modules/5.15.36-xilinx-v2022.2/build` 不存在),不能在板子上直接編譯,driver 改用 WSL 交叉編譯(見上方 driver 章節)
- **已解決**:root 權限問題已排除,`sudo`/`xmutil loadapp` 等操作已能正常執行,不再是阻塞點

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
- kv260 Vivado 專案的實際建置位置是 `FPGA/fpga-projects-1.0.0/build/projects/kv260`(用 `scripts/kv260_patched_2025_2.tcl` 建出來的),`docs/FPGA/Reference/` 底下那份是純參考副本,不是建置用的
- `FPGA/fpga-projects-1.0.0` 與 `FPGA/ip_repo` 已從 `.gitignore` 移除(原本整個被當「外部參考碼」忽略);`FPGA/fpga-projects-1.0.0/.gitignore`(官方原始碼帶的)裡的 `build/` 規則也已拿掉,改交給外層通用的 Vivado 產物規則(`*.cache/`、`*.gen/`、`*.runs/` 等)過濾,`kv260.bd`、`.xci`、`component.xml` 這類原始碼/設定檔正常進版控

## 查證細節

原始碼引用、行號、完整推理過程都在 [`Concept/ps_host_if_replacement_notes.md`](../Concept/ps_host_if_replacement_notes.md)。
