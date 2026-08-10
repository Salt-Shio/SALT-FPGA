# SNN:CSNN 在 PL 端運算——查證筆記

本文件是 [`Todo/csnn_pl_implementation_todo.md`](../Todo/csnn_pl_implementation_todo.md) 的支撐材料:每個結論的原始碼出處、行號、推理過程。TODO 檔案只寫結論跟待辦,細節查證放這裡。

## CSNN 模型的輸入格式

來源:`D:\Project\SNN\main\src\models\net_template.py` 第 36–37 行、`D:\Project\SNN\main\src\models\v16\fused\net.py` 第 48–49 行:

```python
def forward(self, x_seq: torch.Tensor):
    # x_seq: (T, B, 2, 128, 128)
```

CSNN 吃的是 frame(T 個時間步、每步一張 128×128、2 channel 對應事件極性),不是逐事件觸發。這是 `D:\Project\SNN` 訓練端已經定案的模型架構。

**目前實際在訓練的版本**是 `D:\Project\SNN\main\src\models\v16\base\net.py`——這是唯一有對應 `trainer.py` 的版本(`D:\Project\SNN\main\src\models\v16\base\trainer.py`),`v16/fused` 是訓練後把 BatchNorm 融合進 conv 權重的匯出版本,不是獨立訓練的版本。

## 各層神經元數量(用於 BRAM 估算)

從 `v16/base/net.py` 的 layer shape 逐層推算,總和跟 `hardware_platform.md` 已列的 67,841 個膜電位數字對得起來:

| 層 | 輸出 shape | 神經元數 |
|---|---|---|
| `lif1` | 8×64×64 | 32,768 |
| `lif2` | 32×32×32 | 32,768 |
| `lif_comp` | 8×16×16 | 2,048 |
| `lif_hid` | 256 | 256 |
| `lif_out` | 1 | 1 |
| **合計** | | **67,841** |

## LIF 神經元的膜電位更新公式,兩種變體並存

來源:`D:\miniconda3\envs\snn\Lib\site-packages\spikingjelly\activation_based\neuron\`(conda 環境 `snn`)。

| 神經元 | 型別 | 更新公式 | 會不會發火重置 |
|---|---|---|---|
| `lif1`/`lif2`/`lif_comp`/`lif_hid` | `LIFNode`(`lif.py:246-250`) | 充電:$h=v+(x-v)/\tau$;發火:$s=\mathbb{1}[h\ge v_{th}]$;硬重置:發火則 $v\to0$ | 會 |
| `lif_out` | `IFNode`(`integrate_and_fire.py:441-442`) | 充電:$v=v+x$(無衰減項);`v_threshold=inf`,實質不發火 | 幾乎不會 |

完整流程(充電→發火→重置)來源:`base_node.py:54-78`。膜電位更新公式本身**沒有時間變數輸入**,`tau` 是訓練時固定的常數,呼叫一次代表「過了一個固定時間步」。

## `lif_hid`/`lif_out` 是手動時間展開的閉環回饋,不是單純前饋

來源:`v16/base/net.py` 第 118–137 行。CSNN 有兩段不同的執行方式:

- **視覺特徵層**(`conv1→lif1→conv2→lif2→pool→compress→lif_comp`):多步模式,對整個 T 序列平行處理
- **隱藏層+輸出層**(`lif_hid`/`lif_out`):手動 Python for-loop,逐 T 步執行,且**上一步的輸出膜電位會被讀回來,當作下一步的輸入之一**(`fc_fb`)

換子彈時 `lif_out` 的膜電位**不會自動歸零**,會延續上一顆子彈結束時的值,除非明確呼叫 `reset_net()`——這是為了連續即時追蹤多顆子彈時,網路記得上一次估計的落點。

## dataset 生成用真實 1ms 物理模擬,`dt` 不是任意的計步單位

來源:`D:\Project\SNN\data_tool\generate_dataset.py` 第 30 行 `DT = 0.001`;`D:\Project\SNN\data_tool\sim.py` 第 52 行 `vz = (z_impact - start_z) / (n_flight * self.dt)`、第 89 行 `z = start_z + vz * (i * self.dt)`。

子彈的速度、每一幀位置、最終落點標籤,全部是用「每步真的經過 1 毫秒」做運動學積分算出來的。PL 端如果要重建這個時間軸(不管是累積 frame 或做 LIF 更新),週期必須精確等於 1ms,不能用 `>>10` 之類的 2 的冪次近似——近似會讓部署時的時間軸跟訓練時的物理模擬產生系統性偏移(50~90 幀的飛行過程累積 1.2~2.16ms 偏移),直接影響落點預測準確度。

## 參考檔案索引

| 主題 | 路徑 |
|---|---|
| CSNN 目前訓練版本 | `D:\Project\SNN\main\src\models\v16\base\net.py`、`trainer.py` |
| CSNN 匯出版本(BN 已融合) | `D:\Project\SNN\main\src\models\v16\fused\net.py` |
| spikingjelly LIF/IF 神經元原始碼 | `D:\miniconda3\envs\snn\Lib\site-packages\spikingjelly\activation_based\neuron\`(conda 環境 `snn`) |
| DVS 子彈資料集生成(物理模擬 dt) | `D:\Project\SNN\data_tool\generate_dataset.py`、`D:\Project\SNN\data_tool\sim.py` |
| PL 直連架構筆記(資源估算、事件速率規格) | `D:\Project\SNN\dev\references\hardware_platform.md` |
| SNN 專案行為準則 | `D:\Project\SNN\CLAUDE.md` |
| 剪枝工具 | `D:\Project\SNN\main\prune_weights.py` |
| 資源估算工具 | `D:\Project\SNN\main\resource_eval.py` |
