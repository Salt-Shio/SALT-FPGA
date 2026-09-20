# SNN:CSNN 在 PL 端運算——TODO(未來分支,非目前範圍)

## 要做什麼,為了什麼

`D:\Project\SNN` 訓練出來的 CSNN,之後要讓 PL 端直接跑膜電位更新邏輯,不繞 PS,理由是低延遲、省資源。這個分支要解決的問題:PL 端具體怎麼實作膜電位更新,才能跟訓練出來的模型行為一致,同時功耗打贏對應的 ANN 版本。

**這是未來工作,不是現在要做的事**——現在做的是 [`GENX320/Todo/ps_host_if_replacement_todo.md`](../../GENX320/Todo/ps_host_if_replacement_todo.md)。

## 已經決定的設計(已放棄跟 spikingjelly 精確等效,決策過程見 [`Concept/conv_output_ordering_and_training_pivot.md`](../Concept/conv_output_ordering_and_training_pivot.md))

- 事件驅動、每筆事件到達就立刻用經過的整數 ms 數 $N$ 做解析衰減 + 判斷是否 fire,不等下一筆事件——跟 spikingjelly 逐步更新不是同一個函數,設計見 [`Concept/conv_event_scatter_banking_derivation.md`](../Concept/conv_event_scatter_banking_derivation.md) 第 14 節

## 待決定/待查證事項

1. **`fc_in` 要不要用剪枝版本**:`D:\Project\SNN\main\prune_weights.py` 已有剪枝工具跟版本(`pruned`/`pruned-t1e4`),但目前討論都基於密集版本推演,剪枝對「打贏 ANN」這個目標有沒有必要,還沒結論。**注意**:這一項的前提(拿 `D:\Project\SNN` 當參考)可能隨上面的路線調整而失效。
2. **FPGA 上實際省多少功耗**:運算量少 20 倍不代表功耗少 20 倍,FPGA 有漏電流、clock tree 這些固定成本,需要 Vivado 功耗分析或實測才有數字。
3. **CSNN 模組要不要跟 `ps_host_if` 替換模組融合**:等雙方資源用量(BRAM、LUT、功耗)都出來才能決定。
4. **訓練端怎麼做到真正逐事件訓練**:已經移到獨立專案 `D:\Project\Spiking-Affine-Lazy-Training` 處理(單狀態仿射 LIF + associative scan 平行掃描訓練,conv/FC 都支援,N-MNIST 已訓練驗證,約 92% 準確率)。`docs/SNN/Concept/conv_output_ordering_and_training_pivot.md` 只留排序問題本身的發現過程,不再放訓練端工具查證的細節。
5. **conv 層的事件驅動硬體設計細節**:「單筆事件立刻算完、不用等下一筆」這個規則本身已經確認數學上自洽(同上方文件第 7 節),但還沒有重新走一次完整的 RTL 設計(bank/位址/pipeline 這些第 8~13 節的推導,是否需要因為拿掉「等下一筆事件」這個假設而調整,還沒重新檢查)。

## 查證細節

事件驅動 LIF 現行模型的公式與硬體設計在 [`Concept/conv_event_scatter_banking_derivation.md`](../Concept/conv_event_scatter_banking_derivation.md) 第 14 節。conv 層輸出排序問題的發現過程、訓練端從 spikingjelly 轉向的完整決策脈絡,在 [`Concept/conv_output_ordering_and_training_pivot.md`](../Concept/conv_output_ordering_and_training_pivot.md)。
