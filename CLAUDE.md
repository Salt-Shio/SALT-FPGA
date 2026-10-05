# SALT-FPGA 專案說明

## 這是什麼專案

把 GenX320 事件相機的資料直連 KV260 的 PL(FPGA),取代官方的 `ps_host_if` + AXI DMA + PS 軟體解碼路徑,目標是低延遲、省資源。這個專案是三個相關目錄裡負責「FPGA 端實作」的那一個。

## 目前目標

不綁定特定下游應用。目前階段的目標是把 Conv 層的事件驅動 RTL 做出來,驗證這個運作方式實際可不可行、邏輯對不對得上,建立一個可用的基礎。

## 三個目錄的分工

| 目錄 | 職責 |
|---|---|
| `D:\Project\Spiking-Affine-Lazy-Training` | CSNN 模型訓練,目前進度是 N-MNIST。事件驅動 LIF 的數學規格參考來源(`docs/SNN/Concept/model_operation_float.md`、`model_operation_quant.md` 要跟這邊保持一致,符號也照訓練端)。**不是**本專案要修改的對象,只讀不寫。舊專案 `D:\Project\SNN` 已棄用(最後 commit 2026-07-17),不再參考。 |
| `D:\FPGA\KV260_bringup` | KV260 板子的通用 bring-up 學習記錄(Vivado、PetaLinux、AXI 基礎),含官方 GenX320 pipeline 的原始碼查證筆記。本專案用到的部分已複製到 `docs/GENX320/Reference/KV260/`,見下方說明,不會修改原始目錄。 |
| `D:\Project\SALT-FPGA`(本專案) | 把 GenX320 事件資料直連 PL、取代官方 `ps_host_if`、送資料給 PS 端這件事的實作與規劃。融合上面兩個專案的內容。 |

## docs/ 資料夾組織

依內容性質分兩個資料夾,不要把兩邊的東西寫混:

| 資料夾 | 內容 |
|---|---|
| `docs/GENX320/` | `ps_host_if` 替換與 PL→PS 傳輸,目前實際在做的範圍之一 |
| `docs/SNN/` | CSNN 在 PL 端運算,Conv 層事件驅動 RTL 已進入 Vivado 實作階段(2026-09-23 起),跟 `docs/GENX320/` 平行進行 |

`docs/GENX320/Reference/` 放複製進來的外部原始碼與操作筆記(`kv260_operation_notes`、`openeb`、`fpga-projects-1.0.0`、`zynq-video-drivers`),不用再去 `D:\FPGA\KV260_bringup` 找。

每個資料夾底下再分兩層:`Todo/` 放「要做什麼/卡在哪」,`Concept/` 放查證過程、原始碼引用、數學證明。Todo 檔案只留結論跟待辦,不放大段引用。目前的入口:

- `ps_host_if` 替換:[`docs/GENX320/Todo/ps_host_if_replacement_todo.md`](docs/GENX320/Todo/ps_host_if_replacement_todo.md)
- Conv 層 RTL 實作(Vivado 專案 `SaltConv`):[`docs/SNN/Todo/csnn_pl_implementation_todo.md`](docs/SNN/Todo/csnn_pl_implementation_todo.md)
