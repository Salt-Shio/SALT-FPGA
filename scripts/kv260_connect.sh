#!/usr/bin/env bash
# kv260_connect.sh — 一次搞定 X11 forwarding 環境 + SSH 連線,取代每次手動：
#   1. 開 VcXsrv(Multiple windows / Start no client / Disable access control)
#   2. $env:DISPLAY = "localhost:0.0"
#   3. ssh -Y kv260
#
# 用法: bash scripts/kv260_connect.sh
#
# 前提(見 docs/GENX320/Reference/KV260/kv260_operation_notes/network_ssh_access.md):
#   - VcXsrv 已裝在 D:\VcXsrv
#   - ~/.ssh/config 已設好 Host kv260(含 XAuthLocation 指到 xauth.exe)

set -euo pipefail

VCXSRV_EXE="/d/VcXsrv/vcxsrv.exe"

# tasklist/find 的篩選參數用 // 開頭,避免 Git Bash 把 /FI 誤判成路徑轉換
if ! tasklist.exe //FI "IMAGENAME eq vcxsrv.exe" 2>/dev/null | grep -qi vcxsrv.exe; then
	echo "[kv260_connect] VcXsrv 未執行,啟動中(multiwindow / disable access control)..."
	if [ ! -x "$VCXSRV_EXE" ]; then
		echo "[kv260_connect] 找不到 $VCXSRV_EXE,VcXsrv 安裝路徑跟筆記記的不一樣,先手動確認" >&2
		exit 1
	fi
	"$VCXSRV_EXE" -multiwindow -ac &
	disown
	sleep 2
else
	echo "[kv260_connect] VcXsrv 已在執行,略過啟動"
fi

export DISPLAY="localhost:0.0"

echo "[kv260_connect] DISPLAY=$DISPLAY,連線中(-Y,這個環境下 -X 已知會失敗)..."
exec ssh -Y kv260
