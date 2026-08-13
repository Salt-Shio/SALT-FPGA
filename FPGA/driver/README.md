# PS 端 kernel driver

現狀:`psee-composite.c`/`psee-dma.c`/對應的 `.h`/`Makefile` 是**原封不動**從 `docs/FPGA/Reference/KV260/zynq-video-drivers` 複製過來的起點,還沒有任何一行改成我們自己的東西——`REG_CONTROL`/`REG_CONFIG`/`REG_TLAST_TIMEOUT*` 這些暫存器位址跟位元定義,現在對應的仍然是官方 `ps_host_if` 的配置,不是 `FsmConfigSetter.sv` 的配置。編過去的檔頭 compatible 字串也還是 `psee,axi4s-packetizer`,尚未決定要不要沿用。

只複製了 `psee-video.ko`(`psee-composite.c` + `psee-dma.c`)這一對,因為只有這一段對應到我們要取代的 `ps_host_if`。`psee-csi2rxss.c`/`psee-tkeep-handler.c`/`psee-event-stream-smart-tracker.c`/`psee-streamer.c` 這幾顆管的是我們**不動**的 IP(CSI-2、tkeep_handler、ESST),繼續用 Prophesee 既有的 driver,不需要在本專案裡維護副本。

`COPYING` 是原始碼帶的 GPL-2.0 授權文字,一併留著。

下一步待辦記在 [`docs/FPGA/Todo/ps_host_if_replacement_todo.md`](../../docs/FPGA/Todo/ps_host_if_replacement_todo.md)。
