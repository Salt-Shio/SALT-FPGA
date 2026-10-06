"""產生 tb_candidate_grid.sv 用的參考答案。

候選照訓練端 salt_core.connectivity.conv.build_conv_structure 的做法:
y、x 各用 _axis_candidates 算單軸候選,兩軸的 valid 做外積得到二維候選。
再照 Conv.md 第 2 節的 banking 放到 bank (o_y mod M, o_x mod M),
bank 內位址用 Conv.md 的公式從 o_y、o_x 直接算:
    addr = (o_c * G_y + floor(o_y/M)) * G_x + floor(o_x/M),G_y = ceil(H_out/M),G_x = ceil(W_out/M)

每組參數輸出一個文字檔,一行一組輸入,out_channel、in_y、in_x 由外到內窮舉,欄位以空白分隔:
    out_channel in_y in_x  [bank (0,0)] [bank (0,1)] ... [bank (M-1,M-1)]
每個 bank 六個欄位:valid out_y out_x tap_y tap_x bank_addr,bank 依 (r_y, r_x) row-major 排列。
沒有候選的 bank 寫 valid=0,其餘欄位填 0,testbench 比對時不看。

產生答案之前,先窮舉這組參數的每一顆神經元,確認 (bank, bank_addr) 一對一、bank_addr 小於 bank 深度。

用法(WSL,conda 環境 jax):
    python gen_candidate_grid_ref.py \
        --training-repo /mnt/d/Project/Spiking-Affine-Lazy-Training \
        --out-dir /mnt/d/Project/SALT-FPGA/SaltConv/SaltConv.srcs/sim_1/new/ref
"""
import argparse
import sys
from pathlib import Path

import numpy as np

# (KERNEL_SIZE, STRIDE, PADDING, OUT_ROWS, OUT_COLS, OUT_CHANNELS, Y_WIDTH, X_WIDTH),
# 跟 run_tb_candidate_grid.tcl 的清單一致
PARAM_SETS = [
    (3, 2, 1, 17, 17, 8, 6, 6),    # 訓練端 conv1,M=2
    (3, 2, 1, 9, 9, 16, 5, 5),     # 訓練端 conv2,M=2
    (3, 1, 1, 13, 11, 5, 4, 4),    # M=3,長寬不同且不是 M 的倍數,OUT_CHANNELS 不是 2 的次方
    (4, 1, 0, 7, 5, 3, 4, 3),      # M=4
    (5, 2, 2, 10, 7, 3, 5, 4),     # M=3、S>1,候選可能少於 M
    (1, 2, 0, 4, 3, 2, 3, 3),      # S>K,M=1,有座標沒有候選
    (3, 1, 1, 1, 1, 1, 2, 2),      # 輸出 1x1、OUT_CHANNELS=1,位寬下限保護
]

FIELDS_PER_BANK = 6


def ref_file_name(kernel_size: int, stride: int, padding: int, out_rows: int, out_cols: int,
                  out_channels: int, y_width: int, x_width: int) -> str:
    """參考答案檔名,testbench 用同一套規則組出檔名。"""
    return (f"candidate_grid_K{kernel_size}_S{stride}_P{padding}_R{out_rows}_C{out_cols}"
            f"_OC{out_channels}_Y{y_width}_X{x_width}.txt")


def bank_address(out_channel: int, out_y: int, out_x: int, bank_count: int, row_slots: int,
                 col_slots: int) -> int:
    """Conv.md 第 2 節「bank 內部位址」。"""
    return (out_channel * row_slots + out_y // bank_count) * col_slots + out_x // bank_count


def check_bank_layout(bank_count: int, row_slots: int, col_slots: int, out_rows: int,
                      out_cols: int, out_channels: int) -> None:
    """窮舉每一顆神經元,確認不同神經元不會落在同一個 bank 的同一格,位址也不超出 bank 深度。"""
    bank_depth = out_channels * row_slots * col_slots
    used_slots = set()
    for out_channel in range(out_channels):
        for out_y in range(out_rows):
            for out_x in range(out_cols):
                bank = (out_y % bank_count, out_x % bank_count)
                addr = bank_address(out_channel, out_y, out_x, bank_count, row_slots, col_slots)
                if not 0 <= addr < bank_depth:
                    raise RuntimeError(f"神經元 ({out_channel},{out_y},{out_x}) 的位址 {addr} "
                                       f"超出 bank 深度 {bank_depth}")
                if (bank, addr) in used_slots:
                    raise RuntimeError(f"神經元 ({out_channel},{out_y},{out_x}) 跟別的神經元"
                                       f"撞在 bank {bank} 位址 {addr}")
                used_slots.add((bank, addr))


def axis_candidate_lists(axis_candidates, in_width: int, kernel_size: int, stride: int,
                         padding: int, candidate_count: int, out_size: int) -> list[list[tuple[int, int]]]:
    """單軸窮舉 in_coord = 0 ~ 2^in_width - 1,回傳每個座標的合法候選 [(o, k), ...]。"""
    import jax.numpy as jnp

    in_coords = np.arange(2 ** in_width, dtype=np.int32)
    out_coords, valids, taps = axis_candidates(jnp.asarray(in_coords), kernel_size, stride,
                                               padding, candidate_count, out_size)
    out_coords = np.asarray(out_coords)
    valids = np.asarray(valids)
    taps = np.asarray(taps)

    candidate_lists = []
    for coord_idx, in_coord in enumerate(in_coords):
        candidates = []
        for candidate_idx in range(candidate_count):
            if not valids[coord_idx, candidate_idx]:
                continue
            tap = int(taps[coord_idx, candidate_idx])
            if not 0 <= tap < kernel_size:
                raise RuntimeError(f"in_coord={in_coord} 的合法候選 tap={tap} 超出 kernel 範圍")
            candidates.append((int(out_coords[coord_idx, candidate_idx]), tap))
        candidate_lists.append(candidates)
    return candidate_lists


def build_reference_rows(axis_candidates, kernel_size: int, stride: int, padding: int,
                         out_rows: int, out_cols: int, out_channels: int, y_width: int,
                         x_width: int) -> list[str]:
    """窮舉 out_channel、in_y、in_x,回傳每一行的文字。"""
    bank_count = (kernel_size + stride - 1) // stride
    candidate_count = (kernel_size - 1) // stride + 1   # 訓練端的寫法,跟 ceil(K/S) 相同
    if candidate_count != bank_count:
        raise RuntimeError(f"候選數 {candidate_count} 跟 bank 數 {bank_count} 不一致")
    row_slots = (out_rows + bank_count - 1) // bank_count
    col_slots = (out_cols + bank_count - 1) // bank_count
    check_bank_layout(bank_count, row_slots, col_slots, out_rows, out_cols, out_channels)

    row_candidates = axis_candidate_lists(axis_candidates, y_width, kernel_size, stride, padding,
                                          candidate_count, out_rows)
    col_candidates = axis_candidate_lists(axis_candidates, x_width, kernel_size, stride, padding,
                                          candidate_count, out_cols)

    rows = []
    for out_channel in range(out_channels):
        for in_y, y_candidates in enumerate(row_candidates):
            for in_x, x_candidates in enumerate(col_candidates):
                banks = [[(0,) * FIELDS_PER_BANK for _ in range(bank_count)] for _ in range(bank_count)]
                # 兩軸都合法才是候選,跟 build_conv_structure 的 valid_y & valid_x 相同
                for out_y, tap_y in y_candidates:
                    for out_x, tap_x in x_candidates:
                        row_bank = out_y % bank_count
                        col_bank = out_x % bank_count
                        if banks[row_bank][col_bank][0]:
                            raise RuntimeError(f"in_y={in_y} in_x={in_x} 有兩個候選落在 "
                                               f"bank ({row_bank},{col_bank})")
                        addr = bank_address(out_channel, out_y, out_x, bank_count, row_slots, col_slots)
                        banks[row_bank][col_bank] = (1, out_y, out_x, tap_y, tap_x, addr)
                fields = [str(out_channel), str(in_y), str(in_x)]
                for bank_row in banks:
                    for bank_fields in bank_row:
                        fields.extend(str(value) for value in bank_fields)
                rows.append(" ".join(fields))
    return rows


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--training-repo", required=True, type=Path,
                        help="Spiking-Affine-Lazy-Training 的根目錄")
    parser.add_argument("--out-dir", required=True, type=Path, help="參考答案輸出目錄")
    args = parser.parse_args()

    # 運算量很小,固定用 CPU,不去佔 GPU 記憶體(GPU 可能正在跑訓練)
    import jax
    jax.config.update("jax_platforms", "cpu")

    sys.path.insert(0, str(args.training_repo.resolve()))
    from salt_core.connectivity.conv import _axis_candidates

    args.out_dir.mkdir(parents=True, exist_ok=True)
    for params in PARAM_SETS:
        rows = build_reference_rows(_axis_candidates, *params)
        out_path = args.out_dir / ref_file_name(*params)
        out_path.write_text("\n".join(rows) + "\n", encoding="ascii")
        print(f"{out_path.name}: {len(rows)} 行")


if __name__ == "__main__":
    main()
