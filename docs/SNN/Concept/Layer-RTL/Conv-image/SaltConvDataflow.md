# SaltConv 資料流程圖

對照 `SaltConv/SaltConv.srcs/sources_1/new/SaltConv.sv`。
框裡的「第 N 段」是那個檔案檔頭目錄的段落：

| 段 | 內容 |
|---|---|
| 0 | 共用控制：5 個控制訊號的宣告（設定在第 6 段） |
| 1 | 事件進來：清除記憶體、FIFO、事件暫存器 |
| 2 | 下一個 o_c 是誰、讀位址、`current_channel` |
| 3 | 下一個 o_c 碰到哪些神經元（CandidateGrid） |
| 4 | 開始下一個 o_c 時存候選暫存器 |
| 5 | 讀出、算、寫回：權重、門檻、NeuronMemory + NeuronUpdate |
| 6 | 送出、做完沒、換不換 |

圖畫的是「一拍」裡發生的事，由上往下分成三排：
- 最上面：這一拍開始時已經在暫存器裡的東西（上一個時脈邊緣存的）。
- 中間：同一拍裡同時做的兩件事，「讀下一個 o_c」和「算這個 o_c」。
- 最下面：這一拍結束的時脈邊緣存起來的東西，下一拍就變成最上面那一排。

例子：算 o_c=0 的那一拍，同時已經在送 o_c=1 的讀位址。
o_c=0 沒有 fire 的話，下一拍就直接算 o_c=1，中間不空拍。

```mermaid
flowchart TD
    subgraph NOW["這一拍開始時已經在的（上一個時脈邊緣存的）"]
        direction LR
        FIFO["EventFIFO（第 1 段）<br/>看得到最前面那筆事件"]
        EVREG["事件暫存器（第 1 段）<br/>event_x/y/channel/time"]
        CUR["current_channel（第 2 段）<br/>這個 o_c"]
        CTRL["oc_in_progress、compute_cycle<br/>（第 6 段）"]
        CAND["候選暫存器（第 4 段）<br/>神經元位置、bank 位址、權重 tap"]
        BM["bitmask（第 6 段）<br/>之前沒送出的 fire"]
        RDATA["上一拍讀出的資料<br/>膜電位、上次更新時間、整組權重"]
    end

    subgraph READ["讀下一個 o_c"]
        ADDR["選讀位址（第 2 段）<br/>最後一個 o_c 或沒事做：FIFO 那筆事件，o_c=0<br/>否則：事件暫存器那筆事件，o_c+1"]
        GRID["CandidateGrid（第 3 段）<br/>這筆事件碰到哪幾顆神經元<br/>各在哪個 bank 的哪個位址"]
        RDREQ["送讀位址（第 5 段）<br/>NeuronMemory、WeightMemory"]
    end

    subgraph CALC["算這個 o_c"]
        TAP["WeightTapSelect（第 5 段）<br/>從整組權重挑出每顆神經元的那一個"]
        UPD["NeuronUpdate（第 5 段）<br/>衰減、加權重<br/>算新膜電位、有沒有 fire"]
        WB["寫回 NeuronMemory（第 5 段）<br/>只在 compute_cycle=1"]
        PEND["挑 fire 的來源 pending（第 6 段）<br/>compute_cycle=1：剛算出的 fire<br/>compute_cycle=0：bitmask"]
        SS["SpikeSelect（第 6 段）<br/>挑 o_y、o_x 最小的一個"]
        OUT["送出 out_valid、out_x、out_y<br/>out_channel、out_time（第 6 段）"]
        READY["out_ready（下游）"]
        LEFT["送出後還剩的 fire<br/>pending_left（第 6 段）"]
        DONE["oc_done（第 6 段）<br/>一個都沒剩才算做完<br/>OC=1 時算的那一拍一律不算做完"]
        BEGIN["begin_next_oc（第 6 段）<br/>做完，而且下一個 o_c 有東西可做"]
    end

    subgraph NEXT["時脈邊緣存起來，下一拍變成最上面那一排"]
        direction LR
        N_RDATA["讀出的資料"]
        N_REGS["begin_next_oc=1 時才存<br/>候選暫存器、current_channel<br/>compute_cycle=1"]
        N_EV["開始新事件時<br/>事件暫存器存 FIFO 那筆<br/>FIFO 拿走那筆"]
        N_BM["bitmask"]
    end

    FIFO --> ADDR
    EVREG --> ADDR
    CUR --> ADDR
    CTRL --> ADDR
    ADDR --> GRID
    GRID --> RDREQ
    ADDR --> RDREQ
    RDREQ --> N_RDATA
    GRID -->|"候選"| N_REGS

    RDATA --> TAP
    CAND --> TAP
    TAP --> UPD
    RDATA --> UPD
    EVREG -->|"事件時間"| UPD
    CUR -->|"門檻"| UPD
    UPD -->|"新膜電位"| WB
    CAND -->|"寫回位址"| WB
    UPD -->|"有沒有 fire"| PEND
    BM --> PEND
    CTRL --> PEND
    PEND --> SS
    CAND -->|"o_y、o_x"| SS
    SS --> OUT
    SS --> LEFT
    READY --> LEFT
    LEFT -->|"有剩"| N_BM
    LEFT --> DONE
    DONE --> BEGIN
    BEGIN --> N_REGS
    BEGIN --> N_EV
```

## 看圖的重點

- 讀位址只看最上面那排暫存器和 FIFO（第 2 段），不等同一拍的 `begin_next_oc`：下一個 o_c 是誰，這一拍一開始就知道。
- 讀出的資料要下一拍才出來，所以候選、o_c、事件也要在同一個時脈邊緣存起來，下一拍才對得上。
- 讀用中間「讀下一個 o_c」那塊的 `grid_*`，寫用最上面的 `candidate_*`：同一拍讀的跟寫的是不同的 o_c。
- 沒開始下一個 o_c 的拍子（還在送剩下的 fire、下游不收），下一拍讀出的資料不用，再讀一次。
  下一個 o_c 的神經元在它被算之前不會被寫，重讀拿到的值一樣。
- 下游 `out_ready=0` 時，挑出的那個沒送出去，就留在「送出後還剩的 fire」裡，這個 o_c 不算做完，不會換下一個 o_c。
- 控制訊號怎麼算、每拍的值，見 [SaltConvControl.md](SaltConvControl.md)。
