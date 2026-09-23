# SNN:CSNN 在 PL 端運算——TODO(未來分支,非目前範圍)

## 要做什麼,為了什麼

`D:\Project\Spiking-Affine-Lazy-Training` 訓練出來的 CSNN,之後要讓 PL 端直接跑膜電位更新邏輯,不繞 PS,理由是低延遲、省資源。這個分支要解決的問題:PL 端具體怎麼實作膜電位更新,才能跟訓練出來的模型行為一致,同時功耗打贏對應的 ANN 版本。

**這是未來工作,不是現在要做的事**——現在做的是 [`GENX320/Todo/ps_host_if_replacement_todo.md`](../../GENX320/Todo/ps_host_if_replacement_todo.md)。

## 已經決定的設計(已放棄跟 spikingjelly 精確等效)

- 事件驅動、每筆事件到達就立刻用經過的整數 ms 數 $N$ 做解析衰減 + 判斷是否 fire,不等下一筆事件——跟 spikingjelly 逐步更新不是同一個函數,數學規格見 [`Concept/model_operation.md`](../Concept/model_operation.md) 第 2 節
- 層間事件格式統一為攤平索引 $(i,t)$,不是座標三元組 $(x,y,c,t)$;conv 層自己用編譯期已知的 $H_{in},W_{in},C_{in}$ 反推 $(x,y,c)$,FC 層直接拿 $i$ 當權重矩陣 column 索引。`conv1` 前面需要新增一個小型轉換模組,把事件相機原生座標 $(x,y,c,t)$ 換成 $(i,t)$;`EventProcessor.sv`(GENX320 範圍)本身不改動
- conv 分支事件驅動 RTL 設計(候選神經元決定、BRAM banking、LIF 膜電位更新、輸出排序、pipeline 時序)已定案,見 [`Concept/Layer-RTL/Conv.md`](../Concept/Layer-RTL/Conv.md);FC 分支還沒開始,見 [`Concept/Layer-RTL/FC.md`](../Concept/Layer-RTL/FC.md)(目前空檔)

## 待決定/待查證事項

1. **FPGA 上實際省多少功耗**:運算量少 20 倍不代表功耗少 20 倍,FPGA 有漏電流、clock tree 這些固定成本,需要 Vivado 功耗分析或實測才有數字。
2. **CSNN 模組要不要跟 `ps_host_if` 替換模組融合**:等雙方資源用量(BRAM、LUT、功耗)都出來才能決定。
3. **訓練端怎麼做到真正逐事件訓練**:已經移到獨立專案 `D:\Project\Spiking-Affine-Lazy-Training` 處理(單狀態仿射 LIF + associative scan 平行掃描訓練,conv/FC 都支援,N-MNIST 已訓練驗證,約 92% 準確率)。
4. **$V\_WIDTH$(神經元膜電位位寬)未定案**:暫定 12 bits 只是先讓 RTL 骨架能動,不是推導結果。真正數字待補,需要兩塊資訊:`D:\Project\Spiking-Affine-Lazy-Training` 的量化方案(整數位+小數位)、單一事件權重 $w$ 本身要留多少整數位 headroom。
5. **衰減查表 $(1-1/\tau)^N$ 的 ROM 深度數字待補**:截斷條件已有公式依據,但卡在 $F$($V\_WIDTH$ 拆出來的小數位)還沒定案,定案後才能算出實際 ROM 深度。
6. **`FIFO_DEPTH` 數字未定**:反壓、不丟事件的策略已經決定,但實際深度要看目標 clock 頻率、conv2/compress 的實際輸入事件率,這兩個事實還缺。
7. **事件間 pipeline overlap(讓不同 $oc$ 的讀跟算/寫重疊)**:已評估,結論是**目前不做**——省下的量是固定 2~3 拍、不隨 $OC$ 變大,理論吞吐量餘裕已經很大,複雜度換不到有意義的提升。保留當優化方向,等實測吞吐量真的不夠再重新評估。

## 查證細節

conv 分支的完整事件驅動 RTL 推導(候選神經元決定、BRAM banking 位址、LIF 膜電位更新、輸出排序與 tie-break、pipeline 時序)在 [`Concept/Layer-RTL/Conv.md`](../Concept/Layer-RTL/Conv.md);FC 分支還沒開始,之後寫在 [`Concept/Layer-RTL/FC.md`](../Concept/Layer-RTL/FC.md)。訓練端 forward 數學規格(仿射映射、逐筆事件更新、FC/conv 候選規則、多層串接、端到端範例)在 [`Concept/model_operation.md`](../Concept/model_operation.md)。
