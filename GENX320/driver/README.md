# PS 端 kernel driver

現狀:`evtdec-composite.c`/`evtdec-dma.c`(+ 對應的 `.h`)已經從 `zynq-video-drivers` 的 `psee-composite.c`/`psee-dma.c` 改名、改內容成我們自己的版本,對應官方的 `ps_host_if`。改動細節:

- **暫存器對照 `FsmConfigSetter.sv`**(`GENX320/EvtDecoder`),不是官方 `ps_host_if` 的配置:`REG_CONTROL(0x0)` bit 位置沒變,`REG_CONFIG(0x4)` 的 `enable_pattern`/`enable_tlast_timeout` bit 位置往前移一位,`REG_TLAST_TIMEOUT` 位址從 `0x18` 改成 `0x8`
- **移除**:`REG_PACKET_LENGTH`(我們不用固定封包長度框架)、`REG_VERSION`(FsmConfigSetter 沒有版本暫存器)、`REG_TLAST_TIMEOUT_EVT_LSB/MSB` + `DEFAULT_MARKER` 心跳機制(TODO 已定案:完全靜默期一直等沒關係,不合成 filler event)
- **套用了** Prophesee 官方 PetaLinux recipe 裡的 `avoid-descriptor-link-corruption.patch`(`petalinux-projects` repo):`stop_streaming()` 結尾釋放並重新 `dma_request_chan()` 同一個 DMA channel,修「停止串流時 DMA descriptor 偶爾亂序」的已知問題
- **新的 V4L2 pixel format**:`evtdec-format.h` 定義 `V4L2_PIX_FMT_CSNN_XYT`,`__get_format()` 不再像官方那樣把上游 subdev(ESST)的 media bus 格式轉譯成輸出格式(我們的輸出是 PL 端已經解碼好的 `(x,y,type,t)`,跟上游格式完全不同),固定回報這個新格式
- **device tree**:`compatible` 字串改成 `"csnn-fpga,evt-decoder"`,不沿用官方的 `"psee,axi4s-packetizer"`;binding 文件在同目錄的 `csnn-fpga,evt-decoder.yaml`,照官方 binding 格式改寫

只有 `evtdec-video.ko`(`evtdec-composite.c` + `evtdec-dma.c`)這一對,因為只有這一段對應到我們要取代的 `ps_host_if`。`psee-csi2rxss.c`/`psee-tkeep-handler.c`/`psee-event-stream-smart-tracker.c`/`psee-streamer.c` 這幾顆管的是我們**不動**的 IP(CSI-2、tkeep_handler、ESST),繼續用 Prophesee 既有的 driver,不需要在本專案裡維護副本。

`COPYING` 是原始碼帶的 GPL-2.0 授權文字,一併留著——這份程式碼是從 Prophesee 的 GPL-2.0 原始碼改寫的衍生作品,各檔案開頭都留了來源 commit 供追溯。

## 編譯環境:WSL 交叉編譯(2026-08-14 搭好)

板子(KV260)上沒有 `gcc`、沒有 kernel headers,不能直接編。改在 WSL(`Ubuntu-22.04`)搭一份跟板子完全對應的環境。**以下路徑是開發機本機路徑,不是專案通用設定,換一台機器要重做這套環境**。

**要準備的東西跟理由**

- `aarch64-linux-gnu-gcc`:交叉編譯器,`apt install gcc-aarch64-linux-gnu` 裝的通用版本即可,跟板子廠牌無關
- 跟板子完全一致的 kernel 原始碼(`linux-xlnx`):不能隨便抓 tag 或 branch 最新版,因為 kernel 內部很多 `struct` 的欄位排列由編譯時的設定(`.config`)決定,版本、設定沒對齊,編出來的 `.ko` 裝不上去或會讓板子當機
- 板子真正在用的 `.config`:不能用 `linux-xlnx` 原始碼裡內建的 `arch/arm64/configs/xilinx_defconfig`,那只是「沒疊加過」的通用版——PetaLinux/Yocto 建置流程會在這份底稿上疊加板子專屬、Prophesee 感光元件驅動需要的額外設定片段,疊加結果不會寫回原始碼 repo。只有板子上真的跑起來那份成品 `.config` 才跟系統一致

**版本怎麼查到的**(不是用板子 `uname -r` 猜 tag,是查官方 recipe 拿到精確 commit):

板子回報 `5.15.36-xilinx-v2022.2`。官方 `Xilinx/meta-xilinx` repo(`rel-v2022.2` branch)的 `meta-xilinx-core/recipes-kernel/linux/linux-xlnx_2022.2.bb` 寫死:

```
LINUX_VERSION = "5.15.36"
KBRANCH = "xlnx_rebase_v5.15_LTS"
SRCREV = "19984dd147fa7fbb7cb14b17400263ad0925c189"
```

`linux-xlnx.inc` 裡 `LINUX_VERSION_EXTENSION = "-xilinx-${XILINX_RELEASE_VERSION}"`,拼起來正好對上板子的版本字串。單純的 tag(如 `xlnx_rebase_v5.15_2022.2`)版本號停在 `5.15.0`,branch 又持續在動,只有這個釘死的 commit hash 精確對應板子當下這顆 kernel。

**實際步驟**(WSL 裡執行):

```bash
mkdir -p ~/petalinux && cd ~/petalinux
git clone https://github.com/Xilinx/linux-xlnx.git
cd linux-xlnx
git checkout 19984dd147fa7fbb7cb14b17400263ad0925c189

# 板子上先跑:zcat /proc/config.gz > /tmp/config.gz(或直接 scp /proc/config.gz)
# 複製到 WSL 的 ~/petalinux/config.gz 之後:
zcat ../config.gz > .config

sudo apt install -y flex bison   # scripts/kconfig 的 lexer/parser 產生器,沒裝會在 olddefconfig 這步報 flex: not found

export ARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
make olddefconfig      # 把 .config 對齊這棵原始碼樹,不會互動問問題
make modules_prepare   # 生出 Module.symvers(這裡是空的,見下方說明)、include/generated/、scripts 工具
```

`modules_prepare` **不會**真的填出有內容的 `Module.symvers`,即使 `CONFIG_MODVERSIONS` 有開也一樣——這是 kernel 官方文件 `Documentation/kbuild/modules.rst` 寫明的行為,要生出完整內容得真的編一次 `vmlinux`。板子這顆 kernel `CONFIG_MODVERSIONS` 本來就沒開(`.config` 裡是 `# CONFIG_MODVERSIONS is not set`),不影響能不能編出可用的 `.ko`,只是編譯階段少了「呼叫的 kernel 函式簽章是否正確」這層檢查,問題會延後到真的 `insmod` 到板子上才會在 `dmesg` 看到。

**編這個 driver 本身**(`ARCH`/`CROSS_COMPILE` 沿用上面,額外指定 `KERNEL_SRC`):

```bash
cd GENX320/driver   # 這個專案目錄,WSL 下用 /mnt/d/... 路徑存取
export KERNEL_SRC=~/petalinux/linux-xlnx
make
```

驗收:`evtdec-video.ko` 產出後,用 `modinfo evtdec-video.ko` 確認 `vermagic` 跟板子 `uname -r` 完全一致(這裡是 `5.15.36-xilinx-v2022.2 SMP mod_unload aarch64`)。編譯產物(`*.o`/`*.ko`/`Module.symvers`/`.*.cmd` 等)不進版控,已加進 `.gitignore`,要重編用 `make clean` 清乾淨後重跑上面的指令即可。

## 上板測試紀錄(2026-08-14)

`scp` 把編好的 `evtdec-video.ko` 複製到板子,`sudo insmod`/`sudo rmmod` 測試皆乾淨——`lsmod` 確認模組正常出現又正常消失,`dmesg`(含 `grep -i evtdec` 全域搜尋)全程沒有任何錯誤或警告,板子沒有當機。

**這只驗證了模組本身能被 kernel 接受,還沒驗證真正的驅動邏輯**:板子目前跑的是出廠預設的 `k26-starter-kits` shell,device tree 裡沒有 `csnn-fpga,evt-decoder` 節點,driver 用 `module_platform_driver()`,`insmod` 只會呼叫 `platform_driver_register()` 登記進 kernel,不會比對到裝置、不會觸發 `evtdec_composite_probe()`(真正去碰硬體暫存器的邏輯完全沒跑到)。

要真正測到 probe 邏輯跟資料路徑,需要把我們自己的 Vivado bitstream 打包成 accelerated application(`bit.bin` + 我們自己的 `.dtbo` + `shell.json`),取代板子現在跑的預設 shell 再測——這部分待辦見下方連結。

## 還沒做的事

- **我們自己的 device tree overlay(`.dtbo`)還沒生成**——現有的 `csnn-fpga,evt-decoder.yaml` 只是 binding 文件,`clocks = <&zynqmp_clk 71>` 這類具體數值是照抄官方範例的示意值,不是核對過的真實值,真實的 phandle 數值要等切換到我們自己的 accelerated application 後才能用 `dtc -I fs -O dts /proc/device-tree` 核對
- 還沒真的接進 PetaLinux(`.bb` recipe 還沒寫,可以照 `petalinux-projects` 裡 `psee-video_2.0.0.bb` 的模式改)
- 板子上目前登入帳號 `petalinux` 沒有 sudo 密碼可用(這是這台板子本身的環境限制,不是專案程式碼問題),需要 root 權限的操作(`xmutil loadapp` 切換 accelerated application 等)還沒能做

下一步待辦記在 [`docs/GENX320/Todo/ps_host_if_replacement_todo.md`](../../docs/GENX320/Todo/ps_host_if_replacement_todo.md)。
