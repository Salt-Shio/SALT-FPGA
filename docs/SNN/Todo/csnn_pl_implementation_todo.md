# SNN:CSNN 在 PL 端運算——TODO(未來分支,非目前範圍)

## 要做什麼,為了什麼

`D:\Project\SNN` 訓練出來的 CSNN,之後要讓 PL 端直接跑膜電位更新邏輯,不繞 PS,理由是低延遲、省資源。這個分支要解決的問題:PL 端具體怎麼實作膜電位更新,才能跟訓練出來的模型行為一致,同時功耗打贏對應的 ANN 版本。

**這是未來工作,不是現在要做的事**——現在做的是 [`GENX320/Todo/ps_host_if_replacement_todo.md`](../../GENX320/Todo/ps_host_if_replacement_todo.md)。

## 已經決定的設計

- 事件驅動累加、整數 ms 邊界才充電/發火判斷,已證明跟 spikingjelly 訓練時的逐步更新完全等效,不是近似——設計與完整證明見 [`Concept/event_driven_lif_equivalence_proof.md`](../Concept/event_driven_lif_equivalence_proof.md)
- frame/ms 週期必須精確,不能用 `>>10` 之類的 2 的冪次近似——理由見 [`Concept/csnn_pl_implementation_notes.md`](../Concept/csnn_pl_implementation_notes.md) 的物理模擬 `dt` 小節
- 省電關鍵是輸入稀疏度,不是權重密不密集,事件驅動對 `fc_in` 這種密集層一樣有效——數字對比見 [`Concept/event_driven_lif_equivalence_proof.md`](../Concept/event_driven_lif_equivalence_proof.md)

## 待決定/待查證事項

1. **`fc_in` 要不要用剪枝版本**:`D:\Project\SNN\main\prune_weights.py` 已有剪枝工具跟版本(`pruned`/`pruned-t1e4`),但目前討論都基於密集版本推演,剪枝對「打贏 ANN」這個目標有沒有必要,還沒結論。
2. **FPGA 上實際省多少功耗**:運算量少 20 倍不代表功耗少 20 倍,FPGA 有漏電流、clock tree 這些固定成本,需要 Vivado 功耗分析或實測才有數字。
3. **CSNN 模組要不要跟 `ps_host_if` 替換模組融合**:等雙方資源用量(BRAM、LUT、功耗)都出來才能決定。
4. **conv 層(`lif1`/`lif2`/`lif_comp`)的事件驅動硬體設計細節未展開**:「touched 清單/bitmap 怎麼跟 3×3 kernel 的位址展開邏輯搭配」還沒設計。

## 查證細節

CSNN 模型架構、神經元數量、LIF 公式來源、資料集物理模擬的原始碼引用,都在 [`Concept/csnn_pl_implementation_notes.md`](../Concept/csnn_pl_implementation_notes.md)。事件驅動等效性的完整數學證明在 [`Concept/event_driven_lif_equivalence_proof.md`](../Concept/event_driven_lif_equivalence_proof.md)。
