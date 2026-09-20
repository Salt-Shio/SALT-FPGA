# conv 層輸出排序問題與訓練端路線討論記錄

記錄「待決定事項:conv 層事件驅動硬體設計細節」怎麼從一個看似單純的 buffer 設計問題,一路推到「要不要放棄跟 spikingjelly 精確等效」這個大決定。只記結論跟每一步的判斷依據,推導過程連回對應章節,不重複寫。

## 1. 起點:N×N 個候選同拍 fire,怎麼塞進單一 write port 的 FIFO

`conv_event_scatter_banking_derivation.md` 第 8、12 節推導完 BRAM banking 之後,發現同一個 $oc$ cycle,$N\times N$(conv1/conv2 是 4)個候選輸出格可能同一拍一起 fire,要塞進只有 1 個 write port 的輸出 FIFO。一開始以為只是「怎麼一拍塞多筆」的硬體 buffer 設計問題,考慮過方向 A(stall 主 pipeline,插入 drain 拍)、方向 B(獨立 staging buffer + 多埠寫入 + 對主 pipeline 反壓),傾向方向 B。

## 2. 發現「怎麼塞」不是唯一問題:吐出去的時間戳記順序本身就不對

原本假設「同一筆輸入事件觸發的所有 fire,共用同一個時間戳記,內部順序不重要」。重新核對第 14.2~14.4 節後,這個假設被推翻:

- fire 吐出去的時間戳記,是神經元自己**更新前**的舊 $m_{cur}$,不是觸發它的新事件的時間、也不是更新後的新 $m_{cur}$(見 14.3 節 E7 例子)。
- 不同神經元(不同 $oc$/不同空間位置)的 $m_{cur}$ 各自獨立,新鮮度不一致——常被摸到的神經元 $m_{cur}$ 比較新,很少被摸到的神經元 $m_{cur}$ 可能停在很久以前。
- 硬體處理到、吐出 fire 事件的先後順序,不等於這些事件吐出去的時間戳記大小順序。後處理的神經元完全可能吐出更小(更早)的時間戳記。

**為什麼這是真的問題,不是理論假設**:conv1 輸出事件 $(oy,ox,oc,t)$ 送給 conv2 當輸入。conv2 決定候選輸出位置只看 $(x,y)$,跟 $ic$(=conv1 的 $oc$)無關——這是卷積對不同 input channel 求和的正常性質。所以兩筆 conv1 輸出,只要空間位置接近、$oc$ 不同,會共用 conv2 的同一個下游神經元。如果這兩筆的時間戳記因為上面的原因倒著送過去,conv2 那個神經元收到的事件序列就會時間倒退,14.2 節「$m>m_{cur}$」的假設直接被打破。

## 3. 嘗試在硬體端解決:touched bitmap + watermark 一次結算

提出的方案:維護一個「目前開著的 ms 視窗」$M_{now}$,以及這個視窗內誰被摸過的 touched bitmap。只要看到任何一筆事件(不用是同一個神經元)帶著 $m\ge M_{now}+1$ 出現,就代表 $M_{now}$ 這個視窗確定結束,把 bitmap 記錄過的神經元一次全部結算、吐出的時間戳記全部是 $M_{now}$(同一批,內部順序不重要,天生是平局)。這是串流系統裡的標準技巧,對應「watermark」概念——「看到時間戳記 $\ge W$ 的資料,代表 $<W$ 的資料都不會再來,可以安全關閉、送出」。

本質上這是「掃描膜電位的優化版」:比純懶惰(等自己被摸到才觸發)更早、更準時結算,但比純 clock-driven(每拍全部神經元都算)省——只掃 touched 過的。

## 4. 質疑根因:為什麼一定要「下一筆觸發前一筆」

重新檢視這個設計的動機,結論:**根因是為了跟 spikingjelly 精確等效,被迫用下一筆事件觸發前一筆的判斷**。

- spikingjelly 的參考模型是「每個整數 $m$,全部神經元同步一起算」(逐步更新),層跟層之間也是整批 tensor 傳遞,同一個 $m$ 的 spike map 一次全部給下一層——這種模型裡不同神經元之間本來就沒有先後順序的問題,因為根本不是事件串流。
- 我們的硬體選擇「懶惰結算」(只在神經元真的被碰到時才結算它的 ms)是為了省電,這件事本身數學上沒問題(等效性證明保證的是單一神經元自己的 $v[m]$、$s[m]$ 序列跟 spikingjelly 一致)。但我們**額外選擇**把結果做成一個一個事件的串流送給下一層,這個「串流」的形式才是排序問題的根源,不是懶惰結算本身。

**文獻查證(ICONS 2022、Sensors 2026 兩篇)**:兩篇都沒有同時具備「神經元完全獨立、非同步地決定何時吐出結果」+「輸出還必須保留精確的舊時間戳」這個組合。Sensors 2026 那篇的 AER 事件格式根本沒有時間欄位、比對用的是硬體全域計數器,天生沒有這個問題,但代價是只驗證統計相似度(BCR>0.92),不是精確等效。ICONS 2022 那篇用 REQ/ACK 建立整層等級的同步屏障,把神經元評估、發火綁在同一個離散時間步上,論文原話:「this mechanism is crucial for high fidelity between software and hardware」——為了保住精確等效,犧牲掉神經元各自獨立非同步這件事。結論:這兩篇都不是「遇到問題但有解法」,是各自從架構源頭避開「逐事件非同步 + 保留精確時間戳」這個組合,文獻裡沒有現成答案。

## 5. 決定放掉 spikingjelly / `D:\Project\SNN` 當參考

使用者表態不介意放掉 `D:\Project\SNN`,轉向查證 EventProp(Wunderlich & Pehle, 2021,`arXiv:2009.08378`)——這篇用 adjoint 法對連續時間 spiking 網路推導出精確梯度,不需要 surrogate gradient,前向模擬用「event queue + root-bracketing」,是真正連續時間、逐事件處理。已有真實硬體部署過的後續工作(DelGrad,BrainScaleS-2 類比神經型態晶片)。

## 6. mlGeNN 裝機驗證,但發現不是答案

找到 mlGeNN(EventProp 論文團隊官方維護的訓練函式庫,底層是 GeNN)。裝機、驗證過程:

- 環境:RTX 5070(Blackwell,sm_120)+ CUDA 12.9 + VS 18,踩到 nvcc 版本檢查表不認得 VS 18 的問題,用官方提供的 `NVCC_APPEND_FLAGS=-allow-unsupported-compiler` 繞過。
- 正確性交叉驗證:CPU(`single_threaded_cpu` backend)vs CUDA(掛 override)算出的準確率在合理浮點誤差範圍內一致(45.1% vs 45.7%,1000 筆、1 epoch、batch=1),確認 override 沒有讓計算跑掉。
- 單層 conv + EventProp 訓練 MNIST:測試集準確率 95.77%(10 epoch),數字合理。
- 雙層 conv 疊加也訓練成功(77.17%,超參數沒重調,準確率較低是預期中的正常現象),證實 EventProp compiler 真的支援多層卷積,不只是官方單層範例。

環境細節、可重現安裝步驟、範例腳本說明全部記在 `D:\Project\ml_genn\CSNN_FPGA_SETUP_NOTES.md`。

**但查證 mlGeNN 的 `LeakyIntegrateFire` 原始碼後,發現這整條路線的前提是錯的**:膜電位更新公式是 `V = Alpha*V + Isyn`,`Alpha = exp(-dt/tau_mem)`,`dt` 是編譯模型時指定的**固定**時間步長(範例裡 `DT = 1.0`)。GeNN 是 GPU 平行模擬框架,所有神經元用**同一個固定步長同步推進**,不是逐神經元各自事件觸發。EventProp 在 mlGeNN 這裡只提供「exact gradient」(不用 surrogate gradient 近似階梯函數的微分),沒有提供「連續時間、逐事件模擬」——這是原始論文自己的自訂模擬器才有的行為,mlGeNN 疊在 GeNN 這個既有的固定網格框架上,沒有繼承這個性質。

**結論**:mlGeNN 沒有解決「事件驅動硬體 vs. 網格訓練」的落差,這段裝機驗證工作對「做到真正逐事件訓練」這個目標是繞了遠路。裝好的 GeNN/CUDA 工具鏈本身(繞過 VS18/CUDA12.9 版本檢查衝突那部分)還有參考價值,但 mlGeNN 這個訓練框架不是答案。

## 7. 目前確認站得住的部分:單筆事件自己就能完整算完,不需要整批

放掉跟 spikingjelly 精確等效這個前提之後,重新檢視「一筆事件來就立刻算完,不用等下一筆」這個硬體行為在數學上站不站得住:

$$
V_{decay} = V_{old}\times e^{-(t_{now}-t_{last})/\tau}
\qquad
V_{new} = V_{decay} + w
\qquad
s = \mathbb{1}[V_{new}\ge v_{th}]
$$

只用這一筆事件的 $t_{now}$、$w$,加上神經元自己記憶體裡已經存好的 $(V_{old}, t_{last})$,不需要看任何其他事件。成立的關鍵引理:兩次事件之間 $V$ 只會衰減、不會自己漲上去(純衰減不可能單獨造成跨過門檻),所以「要不要 fire」永遠只可能發生在**加了新事件的當下**,不需要靠下一筆事件來確認「前一段真的結束了」。

之前覺得「一定要整批」,是把「跟 spikingjelly 對齊」這個特定限制(結論是「同一個 ms 內的所有事件必須先加總、只在 ms 邊界做一次充電與發火判斷——如果改成每個事件各自觸發充電與發火判斷,則不滿足等效性所需的前提」)誤帶到這個已經不需要跟 spikingjelly 對齊的新前提下。這個限制的前提(要對齊 spikingjelly 的同步批次模型)在新方向下不存在,結論不適用。

## 8. 訓練端後續

放掉 spikingjelly 等效性之後,訓練端要換什麼工具,已經移到獨立專案處理,不在這份文件繼續寫——後續的工具查證、可行性判斷都在 `D:\Project\snn-event-training\CLAUDE.md`。

## 參考

| 主題 | 位置 |
|---|---|
| BRAM banking、N×N 候選推導、現行事件驅動 LIF 模型(第 14 節) | `conv_event_scatter_banking_derivation.md` |
| EventProp 原始論文 | Wunderlich & Pehle, *Scientific Reports* 2021,`arXiv:2009.08378` |
| 訓練端工具查證與 conv 可行性判斷 | `D:\Project\snn-event-training\CLAUDE.md` |
