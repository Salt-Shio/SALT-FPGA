# CSNN-FPGA 專案說明

## 這是什麼專案

把 GenX320 事件相機的資料直連 KV260 的 PL(FPGA),取代官方的 `ps_host_if` + AXI DMA + PS 軟體解碼路徑,目標是低延遲、省資源。這個專案是三個相關目錄裡負責「FPGA 端實作」的那一個。

## 上層應用目標

完整脈絡記在 `D:\Project\SNN\CLAUDE.md`:DVS(事件相機)偵測 Nerf 子彈飛向由馬達控制的攔截板,目標是把 CSNN(脈衝卷積神經網路)搬上 FPGA,即時預測子彈落點並控制馬達移動板子攔截。本專案是這個大目標底下,「感測器資料怎麼從 PL 拿出來」這一段的實作。

## 三個目錄的分工

| 目錄 | 職責 |
|---|---|
| `D:\Project\SNN` | CSNN 模型訓練、量化、剪枝,產出 weight。也是理解 spikingjelly 運算邏輯(LIF 神經元、conv 層行為)的參考實作。**不是**本專案要修改的對象,只讀不寫。 |
| `D:\FPGA\KV260_bringup` | KV260 板子的通用 bring-up 學習記錄(Vivado、PetaLinux、AXI 基礎),含官方 GenX320 pipeline 的原始碼查證筆記。本專案用到的部分已複製到 `docs/FPGA/Reference/KV260/`,見下方說明,不會修改原始目錄。 |
| `D:\Project\CSNN-FPGA`(本專案) | 把 GenX320 事件資料直連 PL、取代官方 `ps_host_if`、送資料給 PS 端這件事的實作與規劃。融合上面兩個專案的內容。 |

## docs/ 資料夾組織

依內容性質分兩個資料夾,不要把兩邊的東西寫混:

| 資料夾 | 內容 |
|---|---|
| `docs/FPGA/` | `ps_host_if` 替換與 PL→PS 傳輸,**目前實際在做的範圍** |
| `docs/SNN/` | CSNN 在 PL 端運算的規劃,**未來分支,理論階段,現在不用做** |

`docs/FPGA/Reference/` 放複製進來的外部原始碼與操作筆記(`kv260_operation_notes`、`openeb`、`fpga-projects-1.0.0`、`zynq-video-drivers`),不用再去 `D:\FPGA\KV260_bringup` 找。

每個資料夾底下再分兩層:`Todo/` 放「要做什麼/卡在哪」,`Concept/` 放查證過程、原始碼引用、數學證明。Todo 檔案只留結論跟待辦,不放大段引用。目前的入口:

- 現在要做的事:[`docs/FPGA/Todo/ps_host_if_replacement_todo.md`](docs/FPGA/Todo/ps_host_if_replacement_todo.md)
- 未來分支規劃:[`docs/SNN/Todo/csnn_pl_implementation_todo.md`](docs/SNN/Todo/csnn_pl_implementation_todo.md)
