# PS 端 kernel driver

現狀:`evtdec-composite.c`/`evtdec-dma.c`(+ 對應的 `.h`)已經從 `zynq-video-drivers` 的 `psee-composite.c`/`psee-dma.c` 改名、改內容成我們自己的版本,對應官方的 `ps_host_if`。改動細節:

- **暫存器對照 `FsmConfigSetter.sv`**(`FPGA/EvtDecoder`),不是官方 `ps_host_if` 的配置:`REG_CONTROL(0x0)` bit 位置沒變,`REG_CONFIG(0x4)` 的 `enable_pattern`/`enable_tlast_timeout` bit 位置往前移一位,`REG_TLAST_TIMEOUT` 位址從 `0x18` 改成 `0x8`
- **移除**:`REG_PACKET_LENGTH`(我們不用固定封包長度框架)、`REG_VERSION`(FsmConfigSetter 沒有版本暫存器)、`REG_TLAST_TIMEOUT_EVT_LSB/MSB` + `DEFAULT_MARKER` 心跳機制(TODO 已定案:完全靜默期一直等沒關係,不合成 filler event)
- **套用了** Prophesee 官方 PetaLinux recipe 裡的 `avoid-descriptor-link-corruption.patch`(`petalinux-projects` repo):`stop_streaming()` 結尾釋放並重新 `dma_request_chan()` 同一個 DMA channel,修「停止串流時 DMA descriptor 偶爾亂序」的已知問題
- **新的 V4L2 pixel format**:`evtdec-format.h` 定義 `V4L2_PIX_FMT_CSNN_XYT`,`__get_format()` 不再像官方那樣把上游 subdev(ESST)的 media bus 格式轉譯成輸出格式(我們的輸出是 PL 端已經解碼好的 `(x,y,type,t)`,跟上游格式完全不同),固定回報這個新格式
- **device tree**:`compatible` 字串改成 `"csnn-fpga,evt-decoder"`,不沿用官方的 `"psee,axi4s-packetizer"`;binding 文件在同目錄的 `csnn-fpga,evt-decoder.yaml`,照官方 binding 格式改寫

只有 `evtdec-video.ko`(`evtdec-composite.c` + `evtdec-dma.c`)這一對,因為只有這一段對應到我們要取代的 `ps_host_if`。`psee-csi2rxss.c`/`psee-tkeep-handler.c`/`psee-event-stream-smart-tracker.c`/`psee-streamer.c` 這幾顆管的是我們**不動**的 IP(CSI-2、tkeep_handler、ESST),繼續用 Prophesee 既有的 driver,不需要在本專案裡維護副本。

`COPYING` 是原始碼帶的 GPL-2.0 授權文字,一併留著——這份程式碼是從 Prophesee 的 GPL-2.0 原始碼改寫的衍生作品,各檔案開頭都留了來源 commit 供追溯。

## 還沒做的事

- 沒編譯過,還沒確認能不能通過語法檢查(需要 WSL 的交叉編譯工具鏈,還沒確認有沒有裝、版本對不對)
- device tree binding 的 example 裡 `clocks = <&zynqmp_clk 71>` 是照抄官方範例的示意數字,不是核對過的真實值,真實值要等板子連上、`dtc -I fs -O dts /proc/device-tree` 核對即時系統
- 還沒真的接進 PetaLinux(`.bb` recipe 還沒寫,可以照 `petalinux-projects` 裡 `psee-video_2.0.0.bb` 的模式改)

下一步待辦記在 [`docs/FPGA/Todo/ps_host_if_replacement_todo.md`](../../docs/FPGA/Todo/ps_host_if_replacement_todo.md)。
