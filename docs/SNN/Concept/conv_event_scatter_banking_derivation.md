# 事件驅動卷積:單一事件反推輸出位置,與 BRAM Bank 無衝突分配的推導

支撐 [`Todo/csnn_pl_implementation_todo.md`](../Todo/csnn_pl_implementation_todo.md) 第 4 項(conv 層的事件驅動硬體設計細節)。本文件推公式、bank 分配規則,以及單一事件對應到哪個 kernel tap($k$);不涉及 channel 序列化順序、權重的實際硬體儲存/定址方式等尚未展開的部分,見文末「尚待展開」。

## 1. 目標

CSNN 的 conv 層吃的是稀疏事件流,不是完整影像。硬體收到單一事件 $(x_i,y_i,i_c)$(座標+輸入 channel/polarity)後,要能:

1. 算出這個事件會更新哪些輸出神經元 $(oc,o_y,o_x)$ 的膜電位,以及該用哪個權重
2. 把這些更新平行分配到多個 BRAM,不互相衝突

## 2. 符號定義

- $K$:kernel size(方形,$H,W$ 兩軸共用同一個 $K$)
- $S$:stride(兩軸共用)
- $P$:padding(兩軸共用)
- $i$:輸入座標(單軸,通用符號);$x_i,y_i$:$i$ 在 $x,y$ 兩軸的具體實例,即事件座標
- $o$:對應輸出座標(單軸,通用符號);$o_y,o_x$:$o$ 在 $y,x$ 兩軸的具體實例
- $k$:kernel 內的 tap 索引(單軸,通用符號),$k\in[0,K-1]$;$k_y,k_x$:$k$ 在兩軸的具體實例
- $oc$:輸出 channel;$ic$:輸入 channel(=事件的 polarity)
- $W[oc,ic,k_y,k_x]$:卷積權重(第 3 節公式用。注意跟「寬度」不同符號——本文件用 $L$ 代表區間寬度,避免跟權重的 $W$ 混淆)
- $X[\cdot]$:輸入張量(事件在該位置的值)
- $V[oc,o_y,o_x]$:輸出膜電位累加器,也就是要更新的目標
- $H_{out},W_{out}$:$y,x$ 軸個別的輸出神經元數量
- $N$:單軸最大扇出數(第 6 節推導出來的結果,$N=\lceil K/S\rceil$),第 8、9 節的 bank 數與 bank 內定址都基於這個值

前提:本文件的推導只涵蓋標準 2D 卷積(無 dilation)、正方形 kernel、$H,W$ 兩軸用同一組 $K,S,P$——目前 CSNN 的 `conv1`/`conv2`/`compress` 三層都符合這個前提。

## 3. 標準卷積公式(gather 方向)回顧

$$
V[oc,o_y,o_x] = \sum_{ic}\sum_{k_y=0}^{K-1}\sum_{k_x=0}^{K-1} W[oc,ic,k_y,k_x]\cdot X[ic,\;o_yS-P+k_y,\;\;o_xS-P+k_x]
$$

這是「輸出去收集輸入」的方向。事件驅動硬體收到的是一筆一筆的輸入,需要反過來:已知輸入座標,找輸出。

## 4. 反推方向:已知輸入座標,求合法輸出範圍

輸出 $o$ 的窗口,涵蓋的輸入座標範圍是 $[oS-P,\;oS-P+K-1]$(把 $k$ 跑滿 $0$ 到 $K-1$ 展開出的區間)。事件座標 $i$ 要落在這個窗口內:

$$
oS-P \;\le\; i \;\le\; oS-P+K-1
$$

拆成兩個不等式各自解 $o$:

$$
oS-P\le i \;\Rightarrow\; o\le\frac{i+P}{S}
\qquad\qquad
i\le oS-P+K-1 \;\Rightarrow\; o\ge\frac{i+P-K+1}{S}
$$

合起來:

$$
\boxed{\;\frac{i+P-K+1}{S} \;\le\; o \;\le\; \frac{i+P}{S}\;}
\tag{1}
$$

$o$ 必須是落在 $[0,H_{out}-1]$ 內的整數,合法解就是這個區間裡的所有整數(下界取 ceil、上界取 floor,再跟 $[0,H_{out}-1]$ 取交集)。

## 5. 引理:合法的 $o$ 恆為連續整數

式 (1) 是**單一連續區間**的不等式,不是分段條件的聯集。連續實數區間內的整數解必然連號(例如 $\{5,6,7\}$,不會跳成 $\{5,7,9\}$)。這個性質跟 $K,S,P$ 的具體數值無關,只要合法條件長成式 (1) 這種單一區間的形式就一定成立。

## 6. 定理:單軸最大扇出數

### 6.1 通用規則:寬度 $L$ 的區間最多塞進幾個整數

$n$ 個連續整數(如 $0,1,\dots,n-1$)頭尾距離是 $n-1$,所以要塞進 $n$ 個整數,區間至少要寬 $n-1$。反過來,寬度 $L$ 的區間最多能塞進的整數個數:

$$
n_{max} = \lfloor L \rfloor + 1
\tag{2}
$$

驗證(數線上直接數):寬度 $0.5$($n_{max}=1$)、寬度 $1.0$($n_{max}=2$,對齊時如 $[0,1]$ 恰好含 $\{0,1\}$;不對齊時如 $[0.5,1.5]$ 只含 $\{1\}$,故 $2$ 是上限而非恆定值)。

### 6.2 代入卷積的區間寬度

式 (1) 的區間寬度:

$$
L = \frac{i+P}{S} - \frac{i+P-K+1}{S} = \frac{K-1}{S}
$$

代入式 (2),單軸最大扇出數:

$$
\boxed{\;N = \left\lfloor \frac{K-1}{S} \right\rfloor + 1\;}
\tag{3}
$$

（對正整數 $K,S$,式 (3) 等於 $\lceil K/S \rceil$,是標準的 floor/ceil 換算恆等式。）

### 6.3 驗證(conv1/conv2 實際參數 $K=3,S=2$)

$N=\lfloor(3-1)/2\rfloor+1=\lfloor1\rfloor+1=2$。對應前面對 $y_i=0,1,2,3,4,5$($P=1$)逐一驗證過的表格:個數在 $\{1,2\}$ 之間交替,最大值 $2$,與 $N=2$ 相符。

### 6.4 其他 $K,S$ 的對照(未使用於本專案,列出來確認公式普適性)

- $K=3,S=1$:$N=\lfloor2/1\rfloor+1=3$,對應「stride=1 時扇出固定等於 $K$」
- $K=1,S=1$(`compress` 層):$N=\lfloor0/1\rfloor+1=1$,對應「1×1 kernel 恆為 1 對 1,無需 banking」
- $K=3,S=3$(僅作教學驗證,未用於本專案):$N=\lfloor2/3\rfloor+1=1$,對應「stride=kernel size 時不重疊、恆為 1 對 1」

## 7. 2D 推廣

$y$ 軸、$x$ 軸各自獨立套用式 (1)~(3),因為 $H,W$ 共用同一組 $K,S,P$,兩軸的 $N$ 相同,記為 $N$。單一事件的最壞空間扇出數(觸及的 $(o_y,o_x)$ 組合數)是兩軸的 cartesian product:

$$
n_{spatial,max} = N \times N
$$

conv1/conv2 實例:$N=2 \Rightarrow n_{spatial,max}=4$,已用 $y_i=x_i=1$ 的事件實例驗證過(觸及 $2\times2=4$ 個輸出位置)。

## 8. BRAM banking 規則

**規則**:單軸分成 $N$ 個 bank,bank 編號 $=o \bmod N$。因為合法的 $o$ 恆為連續整數(第 5 節)、個數不超過 $N$(第 6 節),連續的 $\le N$ 個整數對 $N$ 取餘數,必然落在 $N$ 個不同的餘數——這對任意 $K,S,P$ 都成立,不需要每組新參數重新驗證。

2D 情況:bank 編號 $=(o_y\bmod N,\;o_x\bmod N)$,共 $N\times N$ 個 bank,同一事件的所有候選位置必然分散在不同 bank,平行存取無衝突。

### 8.1 conv1/conv2 實例($N=2$)

$$
\text{bank}(o_y,o_x) = (o_y \bmod 2,\; o_x \bmod 2) = (o_y[0],\, o_x[0])
$$

$N=2$ 剛好是 2 的冪,取餘數退化成直接接最低位元,不需要額外電路。若之後遇到 $N$ 不是 2 的冪(例如 $K=5,S=2 \Rightarrow N=\lceil5/2\rceil=3$),bank 選擇跟位址計算就需要真正的取餘數電路(對小 $N$ 仍然便宜,但不再是純接線)。

## 9. Bank 內部定址

同一個 bank 內還有多個神經元,需要把 $(o_y,o_x)$ 攤平成一維位址。跟第 8 節選 bank 一樣的邏輯:先把「已經被拿去選 bank 的部分」($o_y\bmod N$、$o_x\bmod N$)扣掉,剩下的部分才是 bank 內部的座標:

$$
\text{row} = \left\lfloor \frac{o_y}{N} \right\rfloor \qquad \text{col} = \left\lfloor \frac{o_x}{N} \right\rfloor
$$

再用標準 row-major 攤平成一維位址:

$$
\text{addr} = \text{row} \times \frac{W_{out}}{N} + \text{col}
$$

### 9.1 conv1/conv2 實例($N=2$):$\lfloor o_y/2\rfloor$ 剛好等於位移

$$
\left\lfloor \frac{o_y}{2} \right\rfloor = o_y \gg 1
$$

conv1/conv2 的 $H_{out},W_{out}$ 皆為 2 的冪次(64、32),$N=2$ 時 $\dfrac{W_{out}}{2}$ 也是 2 的冪,乘法退化成位元串接:

$$
\text{addr} = \{\,o_y[\log_2 H_{out}-1:1],\;\; o_x[\log_2 W_{out}-1:1]\,\}
$$

**這只是 $N=2$ 的特例,不是通用公式**——$N$ 不是 2 的冪次時(例如 $K=5,S=2\Rightarrow N=3$),$\lfloor o_y/N\rfloor$ 不能用位移算,是真正的除法。但只要 $o_y$ 位寬落在單顆 LUT 容量內(conv1/conv2 這個規模,$\le6$ bit),$\lfloor o_y/N\rfloor$ 仍然只是「$o_y$ 幾個 bit 決定出的一個有界函式」,合成工具會直接映射成幾顆原生 LUT——跟第 8 節算 bank id 遵守同一條規則,不需要另外設計除法電路(常數除法本身也是合成工具成熟支援的優化,見對話記錄)。

### 9.2 驗證(conv1,$H_{out}=W_{out}=64$)

事件算出 $o_y=5,o_x=3$。

- 公式:$\text{addr}=(5\gg1)\times32+(3\gg1)=2\times32+1=65$
- 位元串接:$o_y[5:1]=00010$,$o_x[5:1]=00001$,串接 $=0001000001_2=65$

兩者一致。

### 9.3 疊上輸出 channel $oc$

前面 9.1、9.2 只算了空間位址,沒有算 $oc$。因為 $oc$ 序列化處理(同一時間只存取一個 $oc$),不需要每個 $oc$ 各開一組 bank——bank 數量維持 $N\times N$(第 8 節的結論不變),$oc$ 只需要疊到 addr 裡當一個額外的高位偏移:

$$
\text{addr} = oc \times \frac{H_{out}}{N}\times\frac{W_{out}}{N} \;+\; \text{row}\times\frac{W_{out}}{N} + \text{col}
$$

意思是同一個 bank 裡,依序把 $oc=0,1,\dots,OC-1$ 各自的一整張 $\dfrac{H_{out}}{N}\times\dfrac{W_{out}}{N}$ 平面疊在不同的位址區段,不是另外開新的 bank。

**驗證(conv1,$OC=8$)**:延續 9.2 的例子($\text{row}\times32+\text{col}=65$),取 $oc=3$:

$$
\text{addr} = 3 \times (32\times32) + 65 = 3\times1024+65 = 3137
$$

每個 bank 的位址空間大小 $=OC\times\dfrac{H_{out}}{N}\times\dfrac{W_{out}}{N}=8\times1024=8192$,對應 13-bit 位址寬度。

### 9.4 疊上時間欄位 $m_{cur}$

第 14 節確定每個神經元要多存 $m_{cur}$,跟 $V$ 打包在同一個 addr。這件事**不動 addr 公式**(9.1~9.3 定的 bank/row/col/addr 全部維持原樣),只讓每個 addr 底下的 word 變寬:

$$
\text{WORD\_WIDTH} = V\_WIDTH + \text{MCUR\_WIDTH}
$$

$\text{MCUR\_WIDTH}$ 已由第 15 節第 1 項的公式定出(隨除數參數 $D$ 而定,conv1/conv2/compress 目前都是 25 bits)。$V\_WIDTH$(整數位+小數位)**暫定 12 bits**,先讓參數接口能動,不是推導結果——真正的數字待補,來自 `D:\Project\SNN` 的量化方案,以及第 15 節第 3 項「一個 ms 內最多幾筆事件累加同一神經元」的整數位需求,兩者都還沒有數字。

word 內部的切法(跟第 11.2 節 tap 的 bit_offset 手法相同,先用參數表示,不寫死數字):

$$
V = \text{word}[\,V\_WIDTH+\text{MCUR\_WIDTH}-1 : \text{MCUR\_WIDTH}\,]
\qquad
m_{cur} = \text{word}[\,\text{MCUR\_WIDTH}-1 : 0\,]
$$

若 $\text{WORD\_WIDTH}$ 超過單顆 BRAM primitive 上限,套用第 11.3 節同樣的做法(多顆並聯拼寬度),不是新問題。

## 10. 從輸入到權重 tap:$k$ 的推導與完整更新列表

### 10.1 每個合法 $o$ 對應哪個 kernel tap $k$

輸出 $o$ 的卷積窗口,在輸入座標上是從 $oS-P$ 開始、往後數 $K$ 格。事件座標 $i$ 落在這個窗口裡的第幾格,就是 tap 索引 $k$:

$$
i = oS - P + k
\qquad\Longrightarrow\qquad
k = i - oS + P
$$

這條式子把「kernel 中心」這個特例推廣成任意 tap:早期用 $\text{center}(o)=oS-P+c$ 判斷 $i$ 是否落在 kernel 中心附近,其中 $c$ 是固定值(kernel 正中心那個 tap 的索引,例如 $K=3$ 時 $c=\frac{K-1}{2}=1$)。$k=i-oS+P$ 把 $c$ 換成跑遍 $0$ 到 $K-1$ 的變數 $k$,對每個 tap 都能反查「$i$ 落在這個 tap 上嗎」。當 $k=c$ 時,$k=i-oS+P$ 退化回 $\text{center}(o)=oS-P+c$,兩者一致。

### 10.2 單軸範例(conv1,$K=3,S=2,P=1$,$y_i=1$)

第 4 節算出 $y_i=1$ 時合法 $o\in\{0,1\}$。對每個 $o$ 代入 $k=i-oS+P$、$\text{bank}=o\bmod2$、$\text{row}=\lfloor o/2\rfloor$:

| $o$ | $k=1-2o+1$ | bank | row |
|---|---|---|---|
| $0$ | $2$ | $0$ | $0$ |
| $1$ | $0$ | $1$ | $0$ |

這個事件會產生兩筆平行更新:一筆用 tap $k=2$ 的權重,寫進 bank $0$;另一筆用 tap $k=0$ 的權重,寫進 bank $1$。

### 10.3 2D 範例(事件 $(x_i,y_i)=(1,1)$)

$x,y$ 兩軸共用同一組 $K,S,P$,$x_i=1$ 算出的表跟 10.2 的 $y$ 軸表完全一樣:

| $o_x$ | $k_x=1-2o_x+1$ | bank$_x$ | col |
|---|---|---|---|
| $0$ | $2$ | $0$ | $0$ |
| $1$ | $0$ | $1$ | $0$ |

把兩軸的表做 cartesian product($2\times2=4$ 組合),每一組給出這個事件實際要做的一筆平行更新——用哪個 tap 的權重、寫進哪個 bank 的哪個位址:

| $(o_y,o_x)$ | $(k_y,k_x)$ | $bank(o_y\bmod2,\,o_x\bmod2)$ | $(\text{row},\text{col})$ |
|---|---|---|---|
| $(0,0)$ | $(2,2)$ | $(0,0)$ | $(0,0)$ |
| $(0,1)$ | $(2,0)$ | $(0,1)$ | $(0,0)$ |
| $(1,0)$ | $(0,2)$ | $(1,0)$ | $(0,0)$ |
| $(1,1)$ | $(0,0)$ | $(1,1)$ | $(0,0)$ |

四筆是同時(平行)發生:第 8 節已證過這 4 個 $o$ 落在 4 個不同 bank,不會衝突。每一列各自代表「用 $W[oc,ic,k_y,k_x]$ 當權重,加到 bank/位址算出的那個 $V[oc,o_y,o_x]$」。

## 11. 權重儲存與定址

### 11.1 Row 位址:$(oc,ic)$ 選一整塊 $K\times K$ 權重

固定一個 $(oc,ic)$ 組合,對應一整塊 $K\times K$ 權重(標準 CNN 權重張量 $W[oc,ic,k_y,k_x]$ 的定義本來就是這樣切的)。這一塊當成記憶體的一個 row,用線性位址選:

$$
\text{row} = oc \times IC + ic
$$

$IC$(該層輸入 channel 數)是編譯期常數。事件處理時 $ic$ 固定(事件的 polarity),$oc$ 依序跑過 $0\ldots OC-1$(已決定序列化),所以 row 位址只需要每步 $+IC$ 累加,不需要乘法器。

### 11.2 Row 內部:tap 位置固定接線,選哪個 tap 是跑時 mux

Row 內部把 $K\times K$ 個 tap(各 $B$ bits)打包成一個寬字,tap $(k_y,k_x)$ 在 row 裡的位元位置是設計時就排好的固定接線:

$$
\text{bit\_offset}(k_y,k_x) = (k_y \times K + k_x) \times B
$$

$K=3,B=8$ 範例:

```
bit  71..64 | 63..56 | 55..48 | 47..40 | 39..32 | 31..24 | 23..16 | 15..8 | 7..0
tap  (2,2)  | (2,1)  | (2,0)  | (1,2)  | (1,1)  | (1,0)  | (0,2)  | (0,1) | (0,0)
```

讀出整個 row 之後,挑哪個 tap 是跑時才知道($k_y,k_x$ 是第 10 節算出來的),所以這一步是一個 $K^2$-to-1 的 mux。

### 11.3 單顆 BRAM 寬度限制,以及超過時怎麼辦

單顆 BRAM primitive 的寬度有其硬體規格上限(精確數字視配置模式而定,需要查 Xilinx UG573 確認,這裡先講原理)。超過單顆上限時,多顆 BRAM 共用同一組位址線平行擺,各自輸出一部分位元、拼成更寬的字——這是標準做法,行為跟一顆一樣(仍是 1-cycle 同步讀出延遲),只是換成「用幾顆湊寬度」。

$K=5$ 範例:$25$ 個 tap $\times 8$ bits $=200$ bits,若單顆 BRAM 撐不到這麼寬,就用多顆平行拼接。

### 11.4 conv1 範例:$IC=2,OC=8$ 的權重塊排列

$\text{row}=oc\times2+ic$,每格是一整塊 $K^2\times B$ bits,不再往下拆:

| | $i_0$($ic=0$) | $i_1$($ic=1$) |
|---|---|---|
| $o_0$ | row 0 | row 1 |
| $o_1$ | row 2 | row 3 |
| $o_2$ | row 4 | row 5 |
| $o_3$ | row 6 | row 7 |
| $o_4$ | row 8 | row 9 |
| $o_5$ | row 10 | row 11 |
| $o_6$ | row 12 | row 13 |
| $o_7$ | row 14 | row 15 |

共 $OC\times IC=16$ 塊,對應第 10 節「$2\times8=16$ 塊」的確認。

### 11.5 不同層各自獨立一份

每層的 $K,IC,OC$ 不同,各自 instantiate 一份獨立的權重記憶體:

| 層 | $K$ | $IC$ | $OC$ | row 數 $=OC\times IC$ | row 寬 $=K^2\times8$ |
|---|---|---|---|---|---|
| conv1 | 3 | 2 | 8 | 16 | 72 bits |
| conv2 | 3 | 8 | 32 | 256 | 72 bits |
| compress | 1 | 32 | 8 | 256 | 8 bits |

## 12. $V$/$W$ 讀寫 Pipeline 時序

### 12.1 BRAM 讀寫的基本時序模型

BRAM 是同步記憶體,讀出/寫入都跟一般 `always_ff` 暫存器同一套規則,不是組合邏輯那種「給位址馬上拿到值」:

- **讀取**:位址在某個 cycle 準備好 → 下一個 clock edge,BRAM 內部的讀取暫存器把 `mem[addr]` 捕捉出來 → 資料在再下一個 cycle 才穩定
- **寫入**:寫入資料/位址/write-enable 在某個 cycle 準備好 → 下一個 clock edge,BRAM 才真正把資料寫進那個位址 → 內容要到再下一個 cycle 才算數

讀跟寫延遲的方向一致,都是「這一拍準備、下一個 edge 才生效」。

### 12.2 單一 bank 的穩態 pipeline(1 clk 一個 $oc$)

$W$ 的位址($\text{row}=oc\times IC+ic$)跟 $V$ 的位址(第 9.3 節的 $\text{addr}$)都吃 $oc$,同一個 $oc$ 同時發給兩邊,兩邊的讀取延遲一樣(都是 1-cycle),資料會同時到齊,可以接起來管線化:

| 訊號 | clk 0 | clk 1 | clk 2 | clk 3 | clk 4 |
|---|---|---|---|---|---|
| W_addr | row(oc=0) | row(oc=1) | row(oc=2) | row(oc=3) | row(oc=4) |
| W_data | X | W[oc=0] | W[oc=1] | W[oc=2] | W[oc=3] |
| V_addr | addr(oc=0) | addr(oc=1) | addr(oc=2) | addr(oc=3) | addr(oc=4) |
| V_data | X | V_old[oc=0] | V_old[oc=1] | V_old[oc=2] | V_old[oc=3] |
| V_write(這拍準備好,assert) | - | $V_{new}$[oc=0]→addr(oc=0) | $V_{new}$[oc=1]→addr(oc=1) | $V_{new}$[oc=2]→addr(oc=2) | $V_{new}$[oc=3]→addr(oc=3) |
| V_commit(下一拍真正寫入,生效) | - | - | $V_{new}$[oc=0] 生效 | $V_{new}$[oc=1] 生效 | $V_{new}$[oc=2] 生效 |

要點:

- clk1 同時發生「讀出 oc=1 的位址」跟「把 oc=0 算完的 $V_{new}$ 接上寫入埠」——1 個 read + 1 個 write,剛好等於 true dual-port BRAM 一個 clock 的上限(第 9 節提過的「max 2 concurrent accesses/cycle」),不超支
- $V_{new}[oc=0]$ 雖然在 clk1 就準備好、接上寫入埠,但實際寫進 BRAM 的內容要到 clk2(下一個 edge 之後)才生效,跟讀取「位址準備好、下一拍資料才穩定」是同一條規則
- 因為每個 $oc$ 用不同位址(第 9.3 節的 $oc$ 偏移),寫入(舊 $oc$)跟讀取(新 $oc$)不會撞同一個位址,不需要額外仲裁
- 穩態下每個 clock 處理 1 個 $oc$,一筆事件跑完 $OC$ 個 channel 總共要 $OC+2$ 個 clock(見第 13.2 節推導)

### 12.3 推廣到 $N\times N$ 個 bank

以上只畫了一個空間候選位置(一個 bank)的 pipeline。第 10.3 節的例子裡,一個事件有 $N\times N$ 個空間候選,各自落在不同 bank——因為 $W$ 的 row 只跟 $(oc,ic)$ 有關、跟空間位置無關,$N\times N$ 個候選共用同一次 $W$ row 讀取,只是各自用 mux 切出自己的 $(k_y,k_x)$ tap(第 11.2 節);而 $V$ 的讀寫因為各自在不同的物理 BRAM bank,可以各自獨立跑上面同一套 pipeline,互不衝突。

## 13. Channel 序列化 FSM

### 13.1 兩狀態 FSM(IDLE/RUN)

```
        FIFO 非空 且 目前 IDLE(不忙)
IDLE ──────────────────────────────► RUN
  ▲                                    │
  │                                    │ oc_cnt 從 0 開始,
  │                                    │ 每個 clock +1
  │                                    │
  └────────────────────────────────────┘
     oc_cnt 跑完 OC 個 channel,
     且最後一筆的 V 寫入也生效後,才回 IDLE
```

- **IDLE**:等待中。FIFO 非空時,把事件 $(x_i,y_i,ic)$ 讀出來鎖存,同時把 $o_y,o_x,k_y,k_x$(第 10 節)鎖存,$oc\_cnt$ 歸零,轉到 RUN
- **RUN**:每個 clock 用 $oc\_cnt$ 當第 12 節位址的 $oc$,用完就 $+1$;跑完後還要多等幾拍(第 13.2 節),最後一筆真正寫入生效才回 IDLE

### 13.2 RUN 要跑幾拍:$oc\_cnt$ 發位址 + drain 計數器

$oc\_cnt$ 的值只在 $0\ldots OC-1$ 這 $OC$ 拍內有意義(用來發位址)。發完最後一個位址($oc=OC-1$)之後,第 12.1 節的讀寫延遲還沒走完:那筆資料要再 1 拍才 valid、寫入 assert,寫入還要再 1 拍才 commit。這 2 拍不需要知道現在是哪個 $oc$,所以不硬把 $oc\_cnt$ 撐出無意義的值,改用一個獨立的小 drain 計數器(數 0、1 共 2 拍)接手計時。

具體例子($OC=3$,cycle-by-cycle,拆成讀/寫兩個 port 分別在忙什麼):

| cycle | $oc\_cnt$ | 讀位址(port 用量) | 資料 valid | 寫 assert | 寫 commit |
|---|---|---|---|---|---|
| 0 | 0 | oc=0 | – | – | – |
| 1 | 1 | oc=1 | oc=0 | oc=0 | – |
| 2 | 2(最後一個合法值) | oc=2 | oc=1 | oc=1 | oc=0 |
| 3 | 停止,drain=0 | **閒置** | oc=2 | oc=2 | oc=1 |
| 4 | 停止,drain=1 | **閒置** | – | **閒置** | oc=2(最後一筆生效)→ 回 IDLE |

總拍數:

$$
\text{RUN 拍數} = OC + 2
$$

套三層的 $OC$:

| 層 | $OC$ | RUN 拍數 |
|---|---|---|
| conv1 | 8 | 10 |
| conv2 | 32 | 34 |
| compress | 8 | 10 |

### 13.3 事件間 pipeline overlap 評估(結論:目前不做)

**動機**:目前設計嚴格序列化——前一筆事件的 drain(最後 2 拍)還沒走完,下一筆事件不會開始。drain 期間讀取 port 是閒置的(見下表),理論上可以提前讓下一筆事件開始讀取。

**drain 期間的 port 使用狀況**($OC=3$ example,cycle 從這筆事件自己的第一次讀取算起):

| cycle | 讀位址 port | 寫 assert | 寫 commit |
|---|---|---|---|
| 0 | oc=0 | – | – |
| 1 | oc=1 | oc=0 | – |
| 2 | oc=2(最後) | oc=1 | oc=0 |
| 3(drain=0) | **閒置** | oc=2 | oc=1 |
| 4(drain=1) | **閒置** | – | oc=2(最後)→ 回 IDLE |

**兩種 overlap 方案**,都要讓下一筆事件($B$)的 $(o_y,o_x,k_y,k_x)$ 提前鎖存,差在提前多少、代價多大:

| 方案 | $B$ 的 $(o_y,o_x,k_y,k_x)$ 何時鎖存 | $B$ 第一次讀取(相對 $A$ 自己的 cycle0) | 額外硬體 |
|---|---|---|---|
| 不 overlap(現況) | $A$ 完全回 IDLE 後 | $OC+3$ | 無 |
| cycle4 方案 | $A$ 的 drain=0 那拍(暫存器已空出) | $OC+1$ | 觸發條件從「IDLE」改成「drain=0」,加 1 拍並行計數 |
| cycle3 方案 | $A$ 自己最後一次讀取同一拍(暫存器還在用) | $OC$ | 上面之外,再加一組 $(o_y,o_x,k_y,k_x)$ 暫存器 + mux,並行計數延長到 2 拍 |

**省下的量是固定的(2~3 拍),不會隨 $OC$ 變大而變多**——因為省下的部分只發生在固定 2 拍的 drain 尾巴,跟 $OC$ 個讀取那段(全程 port 滿載,沒有空檔)無關。$OC$ 越大,這固定的節省量占比越小。

**吞吐量headroom 檢查**(假設 clock $=100\text{MHz}$、輸入速率 $=200\text{k events/s}$,兩者都是還沒定案的假設值,只算量級):

| 層($OC$) | 不 overlap 每事件 cycle 數 | @100MHz 最大吞吐量 | 對 200k events/s 的餘裕 |
|---|---|---|---|
| conv1($OC=8$) | $OC+3=11$ | ≈9.09M events/s | 約 45 倍 |
| conv2($OC=32$) | $OC+3=35$ | ≈2.86M events/s | (conv2 實際輸入速率未知,只算處理能力上限) |

conv1 在完全不 overlap 的情況下,處理能力就已經是 200k events/s 需求的 45 倍,overlap 省下的 2~3 拍在這個負載量級下感覺不到差異。

**結論**:目前不實作 overlap——複雜度(尤其 cycle3 方案的雙緩衝 + mux + 雙計數器並行)換不到有意義的吞吐量提升。保留成第 15 節的優化方向,等實際跑起來發現真的吞吐量不夠、且 `FIFO_DEPTH`(第 15 節第 3 項)撐不住時再重新評估。

## 14. Spike/Fire 機制:事件驅動 LIF 結算

### 14.1 訓練端的真實運算(spikingjelly `LIFNode`)

確認自 `lif.py` 的 `neuronal_charge_decay_input_reset0`(完整路徑見第 16 節)。

對應 `net.py` 實際用法:$\tau=16.0$。
$v_{th}$ 依層而定,conv1/conv2 為 0.2,compress 為 0.1。
預設 `decay_input=True`,硬重置 $v_{reset}=0$。

$$
h[t] = v[t-1] + \frac{x[t]-v[t-1]}{\tau} = v[t - 1] \cdot (1-\frac1\tau) + \frac{x[t]}{\tau}
$$

$$
s[t] = \mathbb{1}[h[t]\ge v_{th}]
\qquad\qquad
v[t] = (1-s[t])\cdot h[t]
$$

`LIFNode` 本身**沒有時間概念**。
多步版本內部是 `for t in range(T)` 逐格算,$t$ 只是張量索引,不是真實時間。
$\tau$ 是相對「一步」的無因次常數。

「一步 = 真實 1ms」是訓練資料端(`sim.py`)的產生方式決定的慣例。
`LIFNode` 自己不知道、也不檢查這個對應關係。

`LIFNode.__init__` 沒有 refractory period 參數,`net.py` 也沒有另外實作。
**本設計不需要 refractory 機制**,不是要不要啟用的選擇題。

### 14.2 事件驅動等效程序(已證明,見第 16 節索引的等價性證明文件)

每個神經元只需要 $V$(累加中的膜電位相關值)與 $m_{cur}$(目前累加到哪個 ms)兩個欄位,不需要額外的第三格存原始總和。

除以 $\tau$ 是線性運算,「整個 ms 累加完才除一次 $\tau$」跟「每筆事件先除 $\tau$、直接累加」結果相同:

$$
\frac{w_1+w_2+\cdots}{\tau}=\frac{w_1}{\tau}+\frac{w_2}{\tau}+\cdots
$$

只要每次跨 ms 時,把上一個 ms 的 decay、threshold、reset 一次做完、再把結果當成新 ms 的起點,$V$ 就會一直等於「目前 ms 累加到現在的 $h$」,不需要另外存一份還沒套用公式的原始總和。

事件抵達,算 $m=\lfloor t_{us}/1000\rfloor$:

- 若 $m=m_{cur}$(同一 ms):

$$
V \leftarrow V + \frac{w}{\tau}
$$

- 若 $m>m_{cur}$(跨過 ms 邊界),$N=m-m_{cur}-1$:

$$
s=\mathbb1[V\ge v_{th}]
\qquad\qquad
V \leftarrow (s\,?\,0:V)\times\left(1-\frac1\tau\right)^{N+1} + \frac{w}{\tau}
$$

$m_{cur}\leftarrow m$。若 $s=1$,依 14.4 節規則對外送出 spike。

不能改成「每筆事件各自觸發充放電判斷」(把每筆事件都當成獨立的跨 ms 處理)。
會導致同一 ms 內的事件被多套用 decay,結果偏離訓練模型(見 14.3 驗證)。

### 14.3 具體例子驗證

$\tau=4$($1/\tau=0.25$)、$v_{th}=1.0$,單一神經元,依序抵達 7 筆事件(初始 $V=0$,$m_{cur}$ 視同已結算到 0 之前)。

| # | $m_{evt}$ | $w$ | 動作前 $m_{cur}$ | 動作前 $V$ | 類型 | $s$ | $N$ | 動作後 $m_{cur}$ | 動作後 $V$ |
|---|---|---|---|---|---|---|---|---|---|
| E1 | 3 | 0.6 | – | 0 | 跨界(初始) | 0 | – | 3 | $0.15$ |
| E2 | 3 | 0.6 | 3 | 0.15 | 同 ms,只累加 | – | – | 3 | $0.30$ |
| E3 | 4 | 0.5 | 3 | 0.30 | 跨界 | 0 | 0 | 4 | $0.35$ |
| E4 | 7 | 0.9 | 4 | 0.35 | 跨界(空 5、6) | 0 | 2 | 7 | $0.37265625$ |
| E5 | 7 | 0.9 | 7 | 0.37265625 | 同 ms,只累加 | – | – | 7 | $0.59765625$ |
| E6 | 7 | 2.0 | 7 | 0.59765625 | 同 ms,只累加 | – | – | 7 | $1.09765625$ |
| E7 | 9 | 0.4 | 7 | 1.09765625 | 跨界(空 8) | **1,fire** | 1 | 9 | $0.1$ |

E7 判斷 spiking 用的是跨界前的 $V=1.09765625$(ms=7 累加完的最終值)。
fire 後 reset 為 0,才對 0 做 $N=1$ 格空 ms 的 decay(結果仍是 0),再加上 E7 自己的 $0.4/4$。

fire 對外送出 spike,時間戳記直接是 $m_{cur}=7$(屬於 ms=7,不是 E7 的 ms=9;詳見 14.4 節的層間時間格式規則)。

**反例**:若把 E1、E2 當成兩次獨立的跨界處理(即使沒有真的跨 ms),E2 會多套一次 decay:

$$
0.15\times0.75+0.15=0.2625 \;\ne\; 0.30(\text{正確的批次結果})
$$

這就是 14.2 節規則不能省略的原因。

### 14.4 跨層 spike 的時間標記

確認自 `net.py` 的 `forward()`(完整路徑見第 16 節)。

`lif1` 輸出的完整 spike 序列(所有 $T$ 步)直接原封不動傳給 `conv2`。
`conv2` 在索引 $t$ 用的輸入,就是 `lif1` 在**同一個** $t$ 算出來的 spike,中間沒有位移。

也就是說,一顆神經元 fire 這件事,「屬於」剛結算的那個 $m_{cur}$。
不屬於任何觸發結算的單一事件——觸發事件本身屬於下一個 ms(見 14.3 表格第 3 步)。

**規則**:fire 時,輸出 spike(送給下一層當輸入事件)的時間戳記直接設為 $m_{cur}$(ms 單位),不換算回 µs:

$$
t_{\text{輸出}} = m_{cur}
$$

下一層(下一個 conv IP)收到後直接拿這個值當自己的 $m_{evt}$,不需要再做除法。

14.1、14.2 節的公式只用到「同 ms/跨 ms」的判斷跟 $N$(跨了幾個 ms),從來不需要 ms 以下的精度,所以層間沒有必要維持 µs 精度。

只有 **EvtDecoder→conv1** 這一段輸入需要真正的 $m=\lfloor t_{us}/1000\rfloor$ 轉換(感測器原生時間戳是 µs);conv1→conv2、conv2→compress 這些層間介面全部是 ms 傳 ms,直接接龍,也不需要除法電路。

時間單位轉換做成除數參數 $D$:conv1 的輸入 $D=1000$(µs→ms),conv2/compress 的輸入 $D=1$(已經是 ms,直接透傳)。$D$ 是編譯期參數,$m_{cur}$ 的位寬由 $D$ 推出來(見第 15 節第 1 項)。

### 14.5 $\left(1-\frac1\tau\right)^{N+1}$ 衰減查表的硬體設計

目標:$N$ 太大時,衰減係數已經小到在 $V$ 的定點精度下等於 0,直接輸出 0,不用查表也不用乘法。

$F$ 是 $V$ 的小數位(位寬拆出來的一部分,見第 15 節第 1 項)。當衰減係數小於最小可表示單位 $2^{-F}$,乘出來的結果一定捨入成 0:

$$
\left(1-\frac1\tau\right)^{N+1} < 2^{-F}
$$

解這個不等式(兩邊取 $\ln$,除以負數 $\ln\left(1-\frac1\tau\right)$ 時不等號翻轉):

$$
\boxed{\;N+1 > \dfrac{F\ln2}{\ln\dfrac{\tau}{\tau-1}}\;}
$$

$\tau$、$F$ 都當參數,不代入具體數字——這條公式本身不需要等 $\tau$、$F$ 的實際值才能定案。

**電路結構**(結構本身不受 $\tau$、$F$ 影響,只有下面兩個數字隨參數變):

- ROM 深度 $=\left\lceil\dfrac{F\ln2}{\ln\frac{\tau}{\tau-1}}\right\rceil$,存 $\left(1-\frac1\tau\right)^{j}$,$j=1,\ldots,\text{該深度}$($\tau$ 是編譯期常數,整張表在合成時就固定)
- 比較器:$N+1$ 超過這個深度就直接輸出常數 0,不進入下面兩步

**流程**:事件跨界抵達 → 算出 $N+1$ → 比較器判斷是否超過截斷門檻 → 沒超過:用 $N+1$ 查 ROM 拿係數,乘上 $(s\,?\,0:V)$;超過:直接輸出 0。

## 15. 尚待展開(不在本文件範圍內)

依重要性排序(由上而下):

1. $V$ 的位寬($V\_WIDTH$)未定案。
   - 暫定 12 bits,先讓 RTL 骨架/參數接口能動,不是推導結果。
   - 真正數字待補,需要兩塊資訊:`D:\Project\SNN` 的量化方案(整數位+小數位)、第 15 節第 3 項「一個 ms 內最多幾筆事件累加同一神經元」。
   - 後者決定整數位要留多少 headroom——第 14.2 節「同 ms 內只累加、不檢查門檻」,累加期間沒有煞車,有溢位風險。
   - $m_{cur}$ 的位寬已解決:$\text{MCUR\_WIDTH}=\lceil\log_2(\lfloor(2^{T\_WIDTH}-1)/D\rfloor+1)\rceil$。
   - conv1($D=1000$,GenX320 原生 $T\_WIDTH=34$-bit µs)算出 25 bits,conv2/compress($D=1$,透傳)承接同一範圍,也是 25 bits。
2. $\left(1-\frac1\tau\right)^{N+1}$ 的查表截斷公式、電路結構已定案(見第 14.5 節,$\tau$、$F$ 都當參數)。ROM 深度的具體數字待補——卡在 $F$(第 15 節第 1 項的 $V\_WIDTH$ 拆出來的小數位)還沒定案
3. `FIFO_DEPTH` 數字未定:反壓、不丟事件的策略已經決定(見 `csnn_fpga_survey.md`),但實際深度要看目標 clock 頻率、conv2/compress 的實際輸入事件率,這兩個事實還缺
4. 事件間 pipeline overlap:已評估,結論是**目前不做**(見第 13.3 節)——省下的量是固定 2~3 拍、不隨 $OC$ 變大,而 conv1 在假設 100MHz/200k events/s 下處理能力已有約 45 倍餘裕,複雜度換不到有意義的提升。保留當優化方向,等實測吞吐量真的不夠再重新評估

## 16. 參考檔案索引

| 主題 | 路徑 |
|---|---|
| 本文件支撐的 TODO 項目 | [`Todo/csnn_pl_implementation_todo.md`](../Todo/csnn_pl_implementation_todo.md) 第 4 項 |
| CSNN 網路架構(conv1/conv2/compress 實際參數來源) | `D:\Project\SNN\main\src\models\v16\base\net.py` |
| GENX320 事件輸出格式(這顆 IP 的上游介面) | `D:\Project\CSNN-FPGA\GENX320\EvtDecoder\EvtDecoder.srcs\sources_1\new\EventProcessor.sv` |
| CSNN-FPGA 架構調查(惰性 decay、FIFO 反壓等外部文獻查證) | `docs/SNN/Concept/csnn_fpga_survey.md` |
| 事件驅動 LIF 與 spikingjelly 逐步更新的等價性證明(第 14 節依據) | `docs/SNN/Concept/event_driven_lif_equivalence_proof.md` |
| spikingjelly `LIFNode` 原始碼(第 14.1 節引用) | `D:\miniconda3\envs\snn\Lib\site-packages\spikingjelly\activation_based\neuron\lif.py` |
