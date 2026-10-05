# SALT-FPGA

把 Prophesee GenX320 事件相機的資料直接接到 KV260 的 PL（FPGA），並在 PL 上做事件驅動的 CSNN 推論。

訓練端是另一個專案 Spiking-Affine-Lazy-Training（SALT）。
本專案負責 FPGA 端的實作，數學規格與符號都跟訓練端保持一致。

## 目標

- 取代官方 `ps_host_if` + AXI DMA + PS 軟體解碼的路徑，降低延遲與資源使用。
- 用事件驅動的方式實作 Conv 層 RTL，驗證這個運作方式可行、邏輯對得上訓練端。
- 設計通用、可參數化，不綁定單一模型或應用場景。

## 目前進度

- **PS 端**：自製 kernel driver（v4l2）與使用者端工具已完成，核心功能已上板驗證。
- **Conv 層 RTL**：Vivado 專案 `SaltConv`，採拆成小 part 逐一實作與驗證。
  - 輸入 EventFIFO 已通過 testbench。
  - 其餘 part 實作中。
- **FC 層**：設計尚未開始。

## 目錄結構

| 目錄 | 內容 |
|---|---|
| `GENX320/` | 事件解碼 PL（`EvtDecoder`）、`ip_repo`、kernel driver、使用者端工具、device tree overlay |
| `SaltConv/` | Conv 層事件驅動 RTL 的 Vivado 專案與 testbench |
| `docs/GENX320/` | `ps_host_if` 替換與 PL→PS 傳輸的待辦與查證筆記 |
| `docs/SNN/` | CSNN 在 PL 端運算的設計推導與待辦 |
| `scripts/` | KV260 連線、事件資料視覺化與統計腳本 |

文件入口：

- [ps_host_if 替換待辦](docs/GENX320/Todo/ps_host_if_replacement_todo.md)
- [Conv 層 RTL 實作待辦](docs/SNN/Todo/csnn_pl_implementation_todo.md)

## 開發環境

- 板子：AMD Kria KV260
- 感測器：Prophesee GenX320
- 工具：Vivado 2025.2

## 第三方程式碼

下列內容不隨本 repo 發布，需要時請自行取得：

- Prophesee `fpga-projects`（放在 `GENX320/fpga-projects-1.0.0/`）
- OpenEB、`zynq-video-drivers` 與 KV260 操作筆記（放在 `docs/GENX320/Reference/`）

文件中引用這些路徑的地方，都是指上述本機複本。
`GENX320/driver/` 的 driver 改寫自 Prophesee `zynq-video-drivers`。

## 授權

本專案預設採用 [Apache License 2.0](LICENSE)。

例外：`GENX320/driver/` 改寫自 Prophesee 的 GPL-2.0 原始碼，維持 GPL-2.0-only，授權文字見 [GENX320/driver/COPYING](GENX320/driver/COPYING)。
