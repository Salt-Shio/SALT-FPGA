#!/bin/bash
# load-csnn-fpga-evtdec.sh — 把 deploy_manual.md 步驟 1~5(搶 fallback driver、
# insmod、部署+切換 app、設定 media pipeline 格式、找裝置節點)串成一支腳本,
# 對照官方的 load-prophesee-kv260-genx320.sh 寫法。在 KV260 板子上執行,
# 不是本機。
#
# 前提:這支腳本跟 csnn-fpga-evtdec.bit.bin / .dtbo / shell.json /
# evtdec-video.ko / evt_dump / v4l2_reg 放同一個資料夾(deploy_manual.md
# 開頭列的檔案)。
#
# 用法(不要整支加 sudo——會導致 $HOME 變成 root 的家目錄,腳本裡用相對
# 於自己所在資料夾的路徑去找檔案,找不到就會像上面這樣去 /home/root 底下
# 找。個別需要權限的指令已經各自加了 sudo,會依序跳密碼提示):
#   bash load-csnn-fpga-evtdec.sh
set -e

BUNDLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "[1/5] 搶贏 fallback driver..."
sudo modprobe psee-tkeep-handler
sudo modprobe psee-event-stream-smart-tracker

echo "[2/5] 載入 evtdec-video.ko..."
if lsmod | grep -q '^evtdec_video'; then
	echo "      已載入,略過 insmod"
else
	sudo insmod "$BUNDLE_DIR/evtdec-video.ko"
fi

echo "[3/5] 部署 app bundle、切換..."
sudo mkdir -p /lib/firmware/xilinx/csnn-fpga-evtdec
sudo cp "$BUNDLE_DIR/csnn-fpga-evtdec.bit.bin" "$BUNDLE_DIR/csnn-fpga-evtdec.dtbo" "$BUNDLE_DIR/shell.json" \
	/lib/firmware/xilinx/csnn-fpga-evtdec/
sudo xmutil unloadapp || true
sudo xmutil loadapp csnn-fpga-evtdec
sleep 1

echo "[4/5] 設定 media pipeline 格式(節點名稱照抄官方腳本,我們沒改過)..."
media-ctl -V "'genx320 6-003c':0[fmt:PSEE_EVT21/320x320]"
media-ctl -V "'a0010000.mipi_csi2_rx_subsystem':1[fmt:PSEE_EVT21/320x320]"
media-ctl -V "'a0040000.axis_tkeep_handler':1[fmt:PSEE_EVT21/320x320]"
media-ctl -V "'a0050000.event_stream_smart_tra':1[fmt:PSEE_EVT21/320x320]"

echo "[5/5] 拓樸與裝置節點..."
media-ctl -p
echo ""
DEV=$(media-ctl -e "evtdec output 0" 2>/dev/null || true)
if [ -z "$DEV" ]; then
	echo "找不到 'evtdec output 0' 這個 entity,上面 media-ctl -p 的輸出裡人工確認哪一段是 [DISABLED]"
	exit 1
fi
echo "裝置節點: $DEV"
echo ""
echo "驗收標準:五個 entity(genx320 -> mipi_csi2_rx_subsystem -> axis_tkeep_handler ->"
echo "event_stream_smart_tracker -> evtdec output 0)都要 [ENABLED],格式統一 PSEE_EVT21/320x320。"
echo ""
echo "接下來(先測假資料,見 deploy_manual.md 步驟 6a):"
echo "  $BUNDLE_DIR/v4l2_reg $DEV set 0x4 0x1"
echo "  $BUNDLE_DIR/evt_dump -n 20 $DEV"
