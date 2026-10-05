# 訓練端 FC/Conv 層數學運算筆記(整數版)

## 0. 範圍

- 這份是硬體實際要跑的 forward 規格，RTL 實作只看這一份。
- 推論全程只有整數加法、乘法、移位、比較。
    - 浮點數只出現在輸出層最後的讀出，而且可以交給 FPGA 外部做。
- 只記 **forward、逐筆事件處理**，訓練端專屬的技巧不寫。
- 這份只寫參數的「意義、粒度、格式」，不寫某一版的實際數值。
    - 捨入規則、溢位處理都是兩個選項並列，還沒選定。
- 目前進度：第 0~6 節。

## 1. 參數一覽

- **粒度**：
    - 每一層各自一份的：$q$、$A[\Delta t]$、$\hat v_{th}$、$s$、$i_V$
    - 整個網路共用一份的：$f_a$、$f_V$、捨入規則 $r$、溢位處理

| 符號 | 意義 | 每層的份數 | 格式 |
|---|---|---|---|
| $q$ | 權重整數碼 | conv：$OC\times C\times K\times K$；FC：$n_{out}\times n_{in}$ | $b$ 位元有號整數 |
| $A[\Delta t]$ | 衰減查表，$\Delta t=1\sim\Delta t_{\max}$ | $\Delta t_{\max}$ 格 | $f_a$ 位元無號整數 |
| $\hat v_{th}$ | 整數門檻 | 每個輸出 channel 一個；輸出層沒有 | 跟暫存器同格式 |
| $s$ | 權重量化步長 | 每個輸出 channel 一個 | 浮點，只在讀出用 |
| $i_V$ | 暫存器的整數位元(含符號位) | 一個 | 純量 |
| $f_V$ | 暫存器的小數位元 | 全網路一個 | 純量 |
| $f_a$ | 衰減碼的小數位元 | 全網路一個 | 純量 |
| $r$ | 乘法後怎麼捨 | 全網路一個 | `round` 或 `truncate` |
| 溢位處理 | 暫存器超出範圍怎麼辦 | 全網路一個 | `繞回` 或 `飽和` |

### 權重碼 $q$

- 對稱量化，範圍
    $$
    -(2^{b-1}-1)\ \le\ q\ \le\ 2^{b-1}-1
    $$
    - 刻意不用 $-2^{b-1}$，正負兩邊對稱
- conv 層權重碼的索引是 $q[o_c,c,k_y,k_x]$，FC 層是 $q[i,\text{src}]$
- 事件沒有強度：不管是網路輸入事件還是層與層之間的 spike，送到神經元時加的就是那條連接的權重碼 $q$

### 衰減查表 $A[\Delta t]$

- 存的是衰減係數 $(1-1/\tau)^{\Delta t}$ 乘上 $2^{f_a}$ 之後四捨五入的整數碼
    - 值域 $0\sim2^{f_a}-1$，只有小數位元，存不下 $1.0$
- 表從 $\Delta t=1$ 開始，兩種 $\Delta t$ 不在表裡：
    - $\Delta t=0$：不衰減，由更新規則直接跳過乘法
    - $\Delta t>\Delta t_{\max}$：衰減係數已經被捨成 0，直接當 $A=0$
- 表的深度由 $f_a$、$\tau$ 決定，是「衰減係數還沒被捨成 0」的最後一格：
    $$
    \Delta t_{\max}=\left\lfloor\frac{\ln\big(2^{-(f_a+1)}\big)}{\ln(1-\tfrac1\tau)}\right\rfloor
    $$
- $\tau$ 本身不進硬體，只透過這張表出現

### 整數門檻 $\hat v_{th}$、步長 $s$

- 權重量化是逐輸出 channel：同一個 channel 的權重共用一個步長 $s_c$
- 浮點門檻 $v_{th}$ 換到整數尺度要除以 $s_c$，所以整數門檻也是逐 channel 一個：
    $$
    \hat v_{th} = \operatorname{round}\big(v_{th}/s_c\cdot2^{f_V}\big)
    $$
    - 即使浮點 $v_{th}$ 全層共用，$s_c$ 逐 channel 不同，$\hat v_{th}$ 就逐 channel 不同
- $s$ 在推論過程中完全用不到，只在輸出層讀出時乘一次
    - conv 層的 $s$ 硬體不需要存

### 暫存器 $\hat V$：$i_V$、$f_V$

- 每顆神經元的膜電位存成有號整數 $\hat V$，寬度
    $$
    w = i_V+f_V
    $$
    - 範圍
    $$
    -2^{w-1}\ \le\ \hat V\ \le\ 2^{w-1}-1
    $$
- $f_V=0$ 時暫存器就是純整數，權重碼直接加進去

### 捨入規則 $r$、溢位處理

- 這兩個都是硬體行為的選擇，訓練端兩種都有對應的版本
- 實際怎麼作用在單筆事件的更新上，見第 3 節

## 2. 從浮點到整數

### 出發點：浮點的逐筆更新

- 每顆神經元存膜電位 $V$、上次更新的時間 $t_{last}$
- 一筆時間 $t$、權重 $w$ 的事件到達時：
    $$
    \Delta t = t - t_{last}
    \qquad
    a = \left(1-\frac1\tau\right)^{\Delta t}
    \qquad
    V^- = aV + w
    $$
    - $V^-\ge v_{th}$：這顆神經元 fire，膜電位歸零
    - $V^-<v_{th}$：不 fire，膜電位保留 $V^-$
    - 不管有沒有 fire，$t_{last}\leftarrow t$

### 第一步：把步長 $s_c$ 移出遞迴

- **設定**：
    - 權重逐輸出 channel 量化，$w = q\cdot s_c$
    - 一顆神經元只屬於一個輸出 channel，它收到的每一筆權重都來自自己這個 channel，所以整條遞迴只會看到同一個 $s_c$

- **縮放後的膜電位**：定義 $\tilde V := V/s_c$，遞迴式兩邊同除 $s_c$：
    $$
    \tilde V^- = a\tilde V + q
    $$
    - $a$ 只跟 $\Delta t$、$\tau$ 有關，不受 $s_c$ 影響
    - 加進去的直接是整數碼 $q$，每一步都不用乘 $s_c$

- **門檻跟著換算**：
    $$
    V^-\ge v_{th}
    \iff
    \tilde V^-\ge\frac{v_{th}}{s_c}=:\tilde v_{th}
    $$
    - 歸零不受影響：哪個尺度下 0 都是 0

- **推論**：
    - 中間層 fire 送出去的是不帶數值的事件，下一層不需要知道這一層的 $s_c$
    - $s_c$ 只在要把 $\tilde V$ 換回物理量時才出現，整個網路只有輸出層讀出需要
    - 不同 channel 的 $\tilde V$ 尺度不同，不能直接互相比大小

### 第二步：把 $a$、$\tilde V$ 換成定點整數

- **兩個數各自的整數碼**：
    - 衰減係數存成 $f_a$ 位元小數：$A = a\cdot2^{f_a}$，就是第 1 節的查表 $A[\Delta t]$
    - 膜電位存成 $f_V$ 位元小數：$\hat V = \tilde V\cdot2^{f_V}$，就是第 1 節的暫存器
    - 門檻跟膜電位比大小，所以用同一個格式：$\hat v_{th} = \tilde v_{th}\cdot2^{f_V}$ 再四捨五入

- **乘法會多出 $f_a$ 位小數**：
    - $A\cdot\hat V$ 的小數位元是 $f_a+f_V$，比暫存器多 $f_a$ 位
    - 要右移 $f_a$ 位才能回到暫存器的格式，移掉的位元怎麼處理就是捨入規則 $r$，記成 $r(\cdot)$

- **權重碼要對齊小數點**：$q$ 是整數，加進 $f_V$ 位小數的暫存器前要左移 $f_V$ 位

- **整數版的遞迴**：
    $$
    \hat V^- = r\big(A\cdot\hat V\big) + \big(q\ll f_V\big)
    \qquad
    \text{fire}\iff\hat V^-\ge\hat v_{th}
    $$
    - 全部是整數運算，不再出現任何浮點數
    - $r(\cdot)$ 的兩種選項、$\Delta t$ 的邊界情況、暫存器溢位的處理，在第 3 節逐步定義

## 3. 單筆事件的更新

- **每顆神經元存的狀態**：
    - 暫存器 $\hat V$，$w$ 位元有號整數
    - 上次更新的時間 $t_{last}$，整數 ms

- **初始狀態**：
    - 樣本開始時 $\hat V=0$、$t_{last}=0$
    - $t_{last}$ 的基準是 `樣本開始`，不是第一筆事件的時間

- 一筆時間 $t$、權重碼 $q$ 的事件到達時，依序做下面四步

### ① 時間間隔、查衰減碼

$$
\Delta t = t - t_{last}
$$

依 $\Delta t$ 分三種情況：

- **$\Delta t=0$**：同一毫秒內的第二筆以後的事件，不衰減
    - 跳過第 ② 步，直接 $D=\hat V$
    - 不能用查表處理：衰減係數 $1.0$ 的碼是 $2^{f_a}$，要 $f_a+1$ 位元，表存不下
- **$1\le\Delta t\le\Delta t_{\max}$**：查表，$A=A[\Delta t]$
- **$\Delta t>\Delta t_{\max}$**：$A=0$

### ② 衰減乘法再捨回暫存器格式

- 乘積 $A\cdot\hat V$ 多 $f_a$ 位小數，要右移 $f_a$ 位捨回暫存器格式，結果記成 $D$(衰減後的值)：
    $$
    D = r\big(A\cdot\hat V\big)
    \qquad
    r(x) = (x+c)\gg f_a
    $$
- $\gg$ 是有號數的算術右移，效果是無條件捨去到較小的整數(floor)，負數也一樣
    - 跟「向零捨去」不同，負數會往更負的方向捨

捨入規則 $r$ 的兩種選項，差別只在捨入修正量 $c$：

- **`round`**：$c=2^{f_a-1}$
    - 位移前先加半格，結果是四捨五入，剛好卡在一半時往大的方向
    - 多一次加法
- **`truncate`**：$c=0$
    - 直接位移，結果是 floor
    - 不用額外電路

**位元數**：

- $A$ 是 $f_a$ 位元無號、$\hat V$ 是 $w$ 位元有號，乘積要 $f_a+w$ 位元有號才不會先溢位
    - 加上 $c$ 之後也還在這個範圍內
- 位移完的 $D$ 一定落在 $0$ 跟 $\hat V$ 之間(含兩端)，所以 $D$ 放得進 $w$ 位元

**兩個邊界情況代進去**：

- $\Delta t>\Delta t_{\max}$ 時 $A=0$，$r(0)=c\gg f_a=0$，兩種選項都得到 $D=0$
- $\Delta t=0$ 時跳過的乘法，如果硬算成 $A=2^{f_a}$，$r(2^{f_a}\hat V)=\hat V+(c\gg f_a)=\hat V$，兩種選項都跟直接 $D=\hat V$ 一致

### ③ 加權重碼

$$
U = D + \big(q\ll f_V\big)
$$

- $f_V=0$ 時就是 $U=D+q$
- $U$ 是溢位處理之前的真實值，要完整算出來，不能在這一步就先溢位
    - $D$ 是 $w$ 位元有號、$q\ll f_V$ 是 $b+f_V$ 位元有號，相加要 $\max(w,\ b+f_V)+1$ 位元

### ④ 寫回暫存器，再判斷 fire

**先把 $U$ 放回 $w$ 位元**，這個動作記成 $\operatorname{fit}_w(\cdot)$，結果記成 $\hat V'$：

$$
\hat V' = \operatorname{fit}_w(U)
$$

溢位處理 $\operatorname{fit}_w$ 有兩種選項：

- **`繞回`**：取 $U$ 兩補數的低 $w$ 位元
    - 超出範圍時值會翻號：正的變負的、負的變正的
    - 兩補數加法器天生就是這個行為，不用額外電路
- **`飽和`**：$U$ 夾在暫存器範圍內
    $$
    \operatorname{fit}_w(U) = \min\big(\max(U,\ -2^{w-1}),\ 2^{w-1}-1\big)
    $$
    - 超出範圍時值卡在最大或最小，不會翻號
    - 要多一組溢位偵測加選擇器
- $U$ 沒超出範圍時，兩種選項的結果都是 $\hat V'=U$

**再用寫回後的值 $\hat V'$ 判斷 fire**：

- **$\hat V'\ge\hat v_{th}$**：這顆神經元 fire
    - 送出一筆 spike(內容見第 5 節)
    - 暫存器歸零：$\hat V\leftarrow0$
- **$\hat V'<\hat v_{th}$**：不 fire
    - 暫存器保留這次的值：$\hat V\leftarrow\hat V'$
- 判斷用的是溢位處理`之後`的 $\hat V'$，不是 $U$
    - 所以 `繞回` 翻號時可能誤觸發 fire，或讓該 fire 的沒 fire
- 輸出層不判斷 fire，一律 $\hat V\leftarrow\hat V'$

**最後更新時間**：不管有沒有 fire，$t_{last}\leftarrow t$

### 四步合成

- **合成**：
    $$
    D =
    \begin{cases}
    \hat V & \Delta t=0\\
    r\big(A[\Delta t]\cdot\hat V\big) & \Delta t\ge1
    \end{cases}
    \qquad
    \hat V' = \operatorname{fit}_w\big(D+(q\ll f_V)\big)
    \qquad
    \hat V \leftarrow
    \begin{cases}
    0 & \hat V'\ge\hat v_{th}\\
    \hat V' & \hat V'<\hat v_{th}
    \end{cases}
    $$
    - $\Delta t>\Delta t_{\max}$ 時 $A[\Delta t]$ 當成 $0$

### 軟體的收尾衰減，硬體省略

- 軟體的 conv 層在每顆神經元最後一筆事件之後，還會多做一次純衰減(權重碼 $0$)，衰減到這一層最後一筆輸入事件的時間
- 純衰減後的值落在 $0$ 跟 $\hat V$ 之間，不會 fire 也不會溢位，conv 層最後的 $\hat V$ 也沒有任何地方讀
- 所以硬體不做這一步，送往下一層的 spike、輸出層的讀出都跟軟體逐位元相同

## 4. 每筆事件要取出的運算資料

- 第 3 節的更新，對每一顆被這筆事件碰到的神經元，要用到下面這些資料：
    - 權重碼 $q$
    - 這顆神經元的暫存器 $\hat V$、上次更新的時間 $t_{last}$
    - 這顆神經元的整數門檻 $\hat v_{th}$
    - 衰減碼 $A[\Delta t]$，由 $\Delta t=t-t_{last}$ 查表，同一層共用一張表
- 這一節定義：一筆事件碰到哪些神經元，每一顆的資料從哪裡取

### 輸入事件

- **格式**：
    - conv 層的輸入事件是 $(x,y,c,t)$，$x,y$ 是空間座標，$c$ 是輸入 channel
    - FC 層的輸入事件是 $(\text{src},t)$，$\text{src}$ 是來源編號
    - $t$ 是時間戳記，整數 ms
- **順序**：
    - 事件照到達的順序一筆一筆處理，時間不遞減
    - 同一毫秒內的多筆事件，照到達的順序處理，不重排

### conv 層

- **設定**：kernel 大小 $K$、步幅 $S$、padding $P$、輸出 channel 數 $OC$、輸出面 $H_{out}\times W_{out}$

- **每顆神經元存的狀態**：每顆各一份
    $$
    \hat V[o_c,o_y,o_x]
    \qquad
    t_{last}[o_c,o_y,o_x]
    $$
    - 每顆神經元只被自己感受野內的事件碰到，$t_{last}$ 各自不同

- **候選神經元**：事件 $(x,y,c,t)$ 碰到所有輸出 channel $o_c$、以及所有滿足下面條件的空間位置 $(o_y,o_x)$
    $$
    k_y = y - S\,o_y + P
    \qquad
    k_x = x - S\,o_x + P
    \qquad
    0\le k_y,k_x<K
    $$
    - 而且 $0\le o_y<H_{out}$、$0\le o_x<W_{out}$
    - 單軸反推成範圍($u$ 代表 $y$ 或 $x$，$O_{\max}$ 是該軸的輸出維度)：
    $$
    \left\lceil \frac{u+P-K+1}{S} \right\rceil \le o \le \left\lfloor \frac{u+P}{S} \right\rfloor
    \qquad
    0 \le o < O_{\max}
    $$
    - 每軸最多 $M=\lceil K/S\rceil$ 個連續整數，一筆事件最多碰到 $M\times M\times OC$ 顆神經元

- **每個候選 $(o_c,o_y,o_x)$ 取出的資料**：
    $$
    q[o_c,\ c,\ k_y,\ k_x]
    \qquad
    \hat V[o_c,o_y,o_x]
    \qquad
    t_{last}[o_c,o_y,o_x]
    \qquad
    \hat v_{th}[o_c]
    $$
    - $k_y,k_x$ 就是判斷候選時算出來的 kernel tap
    - $\Delta t = t - t_{last}[o_c,o_y,o_x]$，再查 $A[\Delta t]$

- **寫回**：第 3 節算完，結果寫回同一個位置
    $$
    \hat V[o_c,o_y,o_x]\leftarrow\text{第 ④ 步的結果}
    \qquad
    t_{last}[o_c,o_y,o_x]\leftarrow t
    $$

### FC 層

- **設定**：
    - 輸出神經元 $n_{out}$ 顆，編號 $i=0,1,\ldots,n_{out}-1$
    - 輸入事件帶 $(\text{src},t)$，$\text{src}$ 是上一層送出這筆 spike 的神經元編號(第 5 節)

- **每顆神經元存的狀態**：
    $$
    \hat V[i]
    \qquad
    t_{last}
    $$
    - $\hat V$ 每顆各一份
    - 每顆神經元收到的事件、時間完全相同，$t_{last}$ 全部一樣，整層只存一份

- **候選神經元**：不看事件內容，固定是全部
    $$
    \{\,0,1,\ldots,n_{out}-1\,\}
    $$

- **每個候選 $i$ 取出的資料**：
    $$
    q[i,\ \text{src}]
    \qquad
    \hat V[i]
    \qquad
    t_{last}
    \qquad
    \hat v_{th}[i]
    $$
    - $\Delta t = t - t_{last}$ 全部神經元共用，只要算一次、查一次表
    - 輸出層沒有 $\hat v_{th}$，不判斷 fire

- **寫回**：
    $$
    \hat V[i]\leftarrow\text{第 ④ 步的結果}
    \qquad
    t_{last}\leftarrow t
    $$
    - 這筆事件的 $n_{out}$ 顆神經元，算 $\Delta t$ 用的都是更新前的 $t_{last}$

## 5. spike 輸出與多層串接

### 神經元編號

- 每顆神經元依固定規則編成一個整數，用在兩個地方：
    - 同一筆事件讓多顆神經元 fire 時，決定送出的先後
    - 下一層是 FC 時，當作 FC 輸入事件的來源編號 $\text{src}$
- **conv 層**：神經元 $(o_c,o_y,o_x)$ 的編號
    $$
    i = o_c\cdot H_{out}W_{out} + o_y\cdot W_{out} + o_x
    $$
    - 先分 channel，同一個 channel 內先比 $o_y$、再比 $o_x$
- **FC 層**：$i=0,1,\ldots,n_{out}-1$
- 網路最前面的輸入事件 $(x,y,c,t)$ 也照同一條規則編號：$c\cdot H_{in}W_{in}+y\cdot W_{in}+x$

### spike 往下一層送

- **spike 的內容**：一顆神經元在處理某筆事件時 fire，就輸出一筆事件
    - conv 層：$(o_c,o_y,o_x,t)$
    - FC 層：$(i,t)$
    - $t$ 是觸發它的那筆輸入事件的時間
- **送出的順序**：
    - 照觸發事件在輸入事件流裡的先後
    - 同一筆輸入事件讓多顆神經元 fire 時，照神經元編號由小到大
- **下一層**：這串 spike 就是下一層的輸入事件流，照第 4 節取資料、照第 3 節更新
    - conv 接 conv：spike 的 $(o_c,o_y,o_x,t)$ 就是下一層輸入事件的 $(c,y,x,t)$
    - conv 接 FC：spike 的 $(o_c,o_y,o_x)$ 換成編號 $i$，$(i,t)$ 就是 FC 輸入事件的 $(\text{src},t)$
    - FC 接 FC：spike 的 $(i,t)$ 就是 FC 輸入事件的 $(\text{src},t)$
    - 時間 $t$ 原封不動往下傳，每一層都不改寫，只有來源換成這一層的神經元

## 6. 輸出層讀出

- **設定**：網路最後一層是 FC，$n_{out}$ 顆神經元，神經元 $i$ 對應類別 $i$

- **輸出層不 fire**：
    - 沒有 $\hat v_{th}$，第 ④ 步不判斷 fire、不歸零，一律 $\hat V[i]\leftarrow\hat V'$
    - 不送出任何 spike
    - 整個樣本送進來的事件都累積在 $\hat V[i]$ 裡，中間照樣衰減

- **讀出時間點**：
    - 輸出層處理完最後一筆輸入事件之後，當下的 $\hat V[i]$ 就是讀出值
    - 最後一筆事件之後不再補衰減到樣本結束
    - 整個樣本都沒有事件送到輸出層時，$\hat V[i]$ 全部是初始值 $0$

- **換回同一個尺度**：每顆輸出神經元的步長 $s_i$ 不同，$\hat V[i]$ 不能直接比大小，要乘回 $s_i$
    $$
    \text{score}_i = \hat V[i]\cdot s_i
    $$
    - 物理尺度的膜電位是 $\hat V[i]\cdot2^{-f_V}\cdot s_i$，但 $2^{-f_V}$ 是全部神經元共用的正數，不改變 argmax，不用乘
    - 不能用 $\hat V[i]\gg f_V$ 代替：右移會 floor 掉小數位元，乘上不同的 $s_i$ 之後排名可能改變
    - 乘 $s_i$ 是整個推論唯一的浮點運算
    - 放在 FPGA 裡做還是交給外部做，是硬體架構的決定，這份不定

- **預測**：
    $$
    \text{預測} = \arg\max_i\ \text{score}_i
    $$
    - 分數相同時取編號小的

- **換下一個樣本**：所有層的 $\hat V$、$t_{last}$ 回到第 3 節的初始狀態($\hat V=0$、$t_{last}=0$)
