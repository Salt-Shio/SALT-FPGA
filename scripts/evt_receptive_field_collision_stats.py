#!/usr/bin/env python
"""
evt_receptive_field_collision_stats.py — 統計同一 1ms 窗口內,有沒有「不同」事件
的候選輸出位置(受 kernel/stride/padding 影響的感受野)互相重疊。

動機:evt_ms_collision_stats.py 量的是「同一個 pixel/polarity 重複觸發」,這只是
真正會讓連續時間模型跟 spikingjelly 1ms 離散模型分岔的碰撞集合裡最窄的子集合——
conv 層裡,只要兩筆座標不同的事件的感受野有重疊(共用至少一個下游神經元的候選
輸出格),不管是不是同一個 pixel,一樣會分岔。這支腳本改用正確的判斷標準,套用
docs/SNN/Concept/conv_event_scatter_banking_derivation.md 第 2、4、7 節的候選輸出
範圍公式:

  單軸合法輸出範圍: ceil((i+P-K+1)/S) <= o <= floor((i+P)/S)

同一 1ms 窗口內,只要某個候選輸出格 (oy,ox) 被 >=2 筆「不同」事件碰到,就是一次
真正的碰撞(不分 polarity/channel,因為卷積本來就要對 input channel 求和,共用
同一個 V[oc,oy,ox] 累加器)。

事件 bit 排列跟 evt_visualize.py 相同(來源 EventProcessor.sv:143)。

用法:
  python evt_receptive_field_collision_stats.py <input1.bin> [input2.bin ...] \
      [--width 320] [--height 320] [--ms-div 1000] [-K 3] [-S 2] [-P 1]
"""

import argparse
import sys

import numpy as np


def load_events(path):
    raw = np.fromfile(path, dtype=np.uint64)
    if raw.size == 0:
        raise ValueError(f"{path} 是空檔案,沒有事件可以讀")
    t = (raw & 0x3FFFFFFFF).astype(np.int64)
    type_ = ((raw >> 34) & 0x1).astype(np.int8)
    y = ((raw >> 35) & 0x7FF).astype(np.int32)
    x = ((raw >> 46) & 0x7FF).astype(np.int32)
    return x, y, type_, t


def ceil_div(a, b):
    # a, b 皆為 numpy int 陣列/純量,b>0;對負數 a 也正確
    return -(-a // b)


def candidate_o_range(i, K, S, P):
    o_min = ceil_div(i + P - K + 1, S)
    o_max = (i + P) // S
    return o_min, o_max


def analyze(path, width, height, ms_div, K, S, P):
    x, y, type_, t = load_events(path)

    valid = (x < width) & (y < height)
    dropped = int(np.count_nonzero(~valid))
    if dropped:
        print(
            f"警告:{path} 有 {dropped} 筆事件 x/y 超出 {width}x{height} 範圍,已忽略",
            file=sys.stderr,
        )
        x, y, type_, t = x[valid], y[valid], type_[valid], t[valid]

    n_events = len(t)
    print(f"=== {path} ===  (K={K}, S={S}, P={P}, ms_div={ms_div})")
    print(f"事件數 {n_events:,},時長 {(t[-1] - t[0]) / 1e6:.3f} s")

    if n_events == 0:
        print()
        return

    m = (t // ms_div).astype(np.int64)

    oy_min, oy_max = candidate_o_range(y.astype(np.int64), K, S, P)
    ox_min, ox_max = candidate_o_range(x.astype(np.int64), K, S, P)

    # N = ceil(K/S),每筆事件最多 N*N 個候選輸出格。conv1/conv2 是 N=2 -> 最多 4 個。
    N = -(-K // S)
    ev_id = np.arange(n_events, dtype=np.int64)

    rows_m, rows_oy, rows_ox, rows_ev = [], [], [], []
    for dy in range(N):
        oy = oy_min + dy
        keep_y = oy <= oy_max
        for dx in range(N):
            ox = ox_min + dx
            keep = keep_y & (ox <= ox_max)
            if not np.any(keep):
                continue
            rows_m.append(m[keep])
            rows_oy.append(oy[keep])
            rows_ox.append(ox[keep])
            rows_ev.append(ev_id[keep])

    cand_m = np.concatenate(rows_m)
    cand_oy = np.concatenate(rows_oy)
    cand_ox = np.concatenate(rows_ox)
    cand_ev = np.concatenate(rows_ev)

    o_span = int(max(cand_oy.max(), cand_ox.max())) + 2
    key = (cand_m * o_span + cand_oy) * o_span + cand_ox

    # 同一筆事件展開出的 N*N 個候選格,彼此的 (oy,ox) 一定互不相同(公式保證),
    # 所以同一個 key 底下的候選列數,就直接等於碰到這個格子的「不同事件」數,
    # 不需要另外去重——可以整段用 np.unique 向量化算完,不用逐格 Python 迴圈
    uniq_key, inverse, counts = np.unique(key, return_inverse=True, return_counts=True)
    row_count = counts[inverse]  # 每個候選列所屬的格子,總共被幾筆事件碰到

    total_cells = len(uniq_key)
    collide_mask_cell = counts >= 2
    collide_cells = int(np.count_nonzero(collide_mask_cell))
    collide_sizes = counts[collide_mask_cell]

    collide_mask_row = row_count >= 2
    n_collide_events = int(np.unique(cand_ev[collide_mask_row]).size) if np.any(collide_mask_row) else 0

    print(
        f"候選輸出格(ms,oy,ox)總數 = {total_cells:,},"
        f"其中被 >=2 筆不同事件碰到的格數 = {collide_cells:,}"
        f"({collide_cells / total_cells * 100:.3f}%)"
    )
    print(
        f"涉入碰撞的事件數 = {n_collide_events:,}"
        f"({n_collide_events / n_events * 100:.3f}% of all events)"
        f"  ——比較基準:同 pixel 重複觸發那個(較窄的)量法量到的數字"
    )
    if collide_sizes.size:
        pct = np.percentile(collide_sizes, [50, 90, 99])
        print(
            f"碰撞格內的事件數分布:p50={pct[0]:.0f}  p90={pct[1]:.0f}  p99={pct[2]:.0f}"
            f"  max={int(collide_sizes.max())}"
        )
    print()


def main():
    parser = argparse.ArgumentParser(description="同一 1ms 窗口內,不同事件感受野重疊(碰撞)統計")
    parser.add_argument("inputs", nargs="+", help="一或多個 evt_dump -o 存的 .bin 路徑")
    parser.add_argument("--width", type=int, default=320)
    parser.add_argument("--height", type=int, default=320)
    parser.add_argument("--ms-div", type=int, default=1000, help="us->ms 除數(預設 1000,對應 conv1 的 D)")
    parser.add_argument("-K", type=int, default=3, help="kernel size(預設 3,conv1/conv2)")
    parser.add_argument("-S", type=int, default=2, help="stride(預設 2,conv1/conv2)")
    parser.add_argument("-P", type=int, default=1, help="padding(預設 1,conv1/conv2)")
    args = parser.parse_args()

    for path in args.inputs:
        analyze(path, args.width, args.height, args.ms_div, args.K, args.S, args.P)


if __name__ == "__main__":
    main()
