# 前置:`~/csnn-fpga/` 底下要有這些檔案

```
csnn-fpga-evtdec.bit.bin
csnn-fpga-evtdec.dtbo
shell.json
evtdec-video.ko
evt_dump
v4l2_reg
```

`csnn-fpga-evtdec.dts` 是原始碼,板子上用不到,放著無妨。

# 1. 搶贏 fallback driver
```
sudo modprobe psee-tkeep-handler
sudo modprobe psee-event-stream-smart-tracker
```

# 2. 載入我們自己的 driver(還沒裝進系統,要手動)
```
sudo insmod ~/csnn-fpga/evtdec-video.ko
```

# 3. 部署 app、切換
```
sudo mkdir -p /lib/firmware/xilinx/csnn-fpga-evtdec
sudo cp ~/csnn-fpga/csnn-fpga-evtdec.bit.bin ~/csnn-fpga/csnn-fpga-evtdec.dtbo ~/csnn-fpga/shell.json /lib/firmware/xilinx/csnn-fpga-evtdec/
sudo xmutil unloadapp
sudo xmutil loadapp csnn-fpga-evtdec
sleep 1
```

# 4. 上游每個節點設格式(照抄官方腳本,節點名稱我們沒改過)
```
media-ctl -V "'genx320 6-003c':0[fmt:PSEE_EVT21/320x320]"
media-ctl -V "'a0010000.mipi_csi2_rx_subsystem':1[fmt:PSEE_EVT21/320x320]"
media-ctl -V "'a0040000.axis_tkeep_handler':1[fmt:PSEE_EVT21/320x320]"
media-ctl -V "'a0050000.event_stream_smart_tra':1[fmt:PSEE_EVT21/320x320]"
```

# 5. 確認拓樸、找到我們自己的裝置節點
```
media-ctl -p
ls /dev/video*
```

驗收標準:五個 entity(`genx320` → `mipi_csi2_rx_subsystem` → `axis_tkeep_handler` → `event_stream_smart_tracker` → `evtdec output 0`)都要出現,每條線都是 `[ENABLED]`,格式全部統一成 `PSEE_EVT21/320x320`。有任何一段是 `[DISABLED]` 或格式沒統一,先回頭檢查步驟 4,不要往下跳。

**注意**:板子上這個 `v4l2-ctl` 沒有編進 `--get-register`/`--set-register` 功能(`--help-all` 查不到),下面改用我們自己寫的 `v4l2_reg`(直接呼叫跟 driver 的 `VIDIOC_DBG_S_REGISTER`/`VIDIOC_DBG_G_REGISTER`,效果一樣)。

# 6a. 先測假資料(`REG_CONFIG` 位址 `0x4`,bit0=`enable_pattern`)
```
~/csnn-fpga/v4l2_reg /dev/videoN set 0x4 0x1
~/csnn-fpga/v4l2_reg /dev/videoN get 0x4   # 確認讀回來是 0x1
~/csnn-fpga/evt_dump /dev/videoN 20
```
預期看到 `x=0,1,2,3...` 遞增、`y=0 type=0 t=0` 固定。

# 6b. 假資料沒問題,再測真感測器
```
~/csnn-fpga/v4l2_reg /dev/videoN set 0x4 0x0
```

```
# 官方腳本這行是註解掉的,先不加,卡住再補:
# sudo sh -c "echo on > /sys/class/video4linux/v4l-subdevN/device/power/control"
```

```
~/csnn-fpga/evt_dump /dev/videoN 20
```