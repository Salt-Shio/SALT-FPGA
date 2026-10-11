"""產生 tb_spike_select.sv 用的參考答案。

候選照訓練端 salt_core.connectivity.conv._axis_candidates(gen_candidate_grid_ref.py 的 axis_candidate_lists)
算每個事件座標 (in_y, in_x) 每個 bank 的候選 (o_y, o_x),bank 是 (o_y mod M, o_x mod M)。
合法 bank 的子集合當 pending,送出順序照 model_operation_quant.md 第 5 節的神經元編號由小到大:
同一個 o_c 內就是 o_y * OUT_COLS + o_x 由小到大(訓練端 salt_core/stream.py 用同一個編號 lexsort)。

pending 怎麼取:
  - SpikeSelect 的行為只由 (top_row_bank, left_col_bank, 合法 bank 的位置) 決定,同一種組合第一次出現時,
    合法 bank 數 n <= EXHAUSTIVE_BANKS 就窮舉全部 2^n 個子集合,否則抽 SAMPLED_SUBSETS 個,再加上全亮、只亮一個。
  - 同一種組合之後再出現(座標不同),只抽 REPEAT_SUBSETS 個,加上全亮,讓不同座標也測到 selected_y、selected_x。
  - 兩軸都沒有候選的座標只有全 0 一種。
不合法 bank 的 out_y、out_x 填亂數(一半機率填 0)。testbench 送進 SpikeSelect 的座標來自 RTL 的
CandidateGrid,不是這裡的值;這裡的值只在 valid=1 時拿來跟 CandidateGrid 比對。

top_row_bank、left_col_bank 是窗(這一拍的 M x M 候選)最上面那列的 o_y mod M、最左邊那行的 o_x mod M,
用 gen_candidate_axis_ref.py 的 axis_min_bank 算;產生答案時用 check_min_bank_order 確認:
合法候選照「從窗的最上面(最左邊)往下(往右)」排的順序,跟依座標排的順序相同(SpikeSelect 不比座標的前提)。

答案檔一行一個指令,第一個欄位是種類,欄位以空白分隔:
    case <in_y> <in_x> <top_row_bank> <left_col_bank> [bank (0,0)] ... [bank (M-1,M-1)] <count> <order_1> ... <order_count>
        每個 bank 四個欄位 valid pending out_y out_x,bank 依 (r_y, r_x) row-major 排列;pending=1 的 bank 一定 valid=1。
        order 是預期送出順序,每個是 bank 的 row-major 編號 r_y * M + r_x;count = pending 亮的個數。
    end <case_count> <step_count>
        case 行數、預期送出的總筆數,testbench 用來確認沒有漏掉。

用法(WSL,conda 環境 jax,在 scripts 目錄執行,要 import 同目錄的 gen_candidate_grid_ref.py、gen_candidate_axis_ref.py):
    python gen_spike_select_ref.py \
        --training-repo /mnt/d/Project/Spiking-Affine-Lazy-Training \
        --out-dir /mnt/d/Project/SALT-FPGA/SaltConv/SaltConv.srcs/sim_1/new/ref
"""
import argparse
import itertools
import sys
from pathlib import Path

import numpy as np

from gen_candidate_axis_ref import axis_min_bank, check_min_bank_order
from gen_candidate_grid_ref import axis_candidate_lists

# (KERNEL_SIZE, STRIDE, PADDING, OUT_ROWS, OUT_COLS, Y_WIDTH, X_WIDTH),跟 run_tb_spike_select.tcl 的清單一致
PARAM_SETS = [
    (3, 2, 1, 17, 17, 6, 6),     # 訓練端 conv1,M=2
    (3, 2, 1, 9, 9, 5, 5),       # 訓練端 conv2,M=2
    (3, 1, 1, 13, 11, 4, 4),     # M=3,長寬不同且不是 M 的倍數
    (3, 1, 1, 64, 64, 7, 7),     # M=3,座標 6 bits,座標位寬最大的一組
    (4, 1, 0, 7, 5, 4, 3),       # M=4,合法 bank 最多 16 個,抽樣
    (5, 2, 2, 10, 7, 5, 4),      # M=3、S>1,候選可能少於 M
    (1, 2, 0, 4, 3, 3, 3),       # S>K,M=1,有座標沒有候選
    (3, 1, 1, 1, 1, 2, 2),       # 輸出 1x1,座標位寬下限
]

SEED = 0
EXHAUSTIVE_BANKS = 9      # 合法 bank 數不超過這個就窮舉子集合(2^9 = 512)
SAMPLED_SUBSETS = 512     # 超過時第一次出現抽幾個
REPEAT_SUBSETS = 8        # 同一種組合再出現時抽幾個
GARBAGE_ZERO_PROB = 0.5   # 不合法 bank 的座標填 0 的機率


def ref_file_name(kernel_size: int, stride: int, padding: int, out_rows: int, out_cols: int,
                  y_width: int, x_width: int) -> str:
    """參考答案檔名,testbench 用同一套規則組出檔名。"""
    return (f"spike_select_K{kernel_size}_S{stride}_P{padding}_R{out_rows}_C{out_cols}"
            f"_Y{y_width}_X{x_width}.txt")


def random_subsets(valid_banks: list[int], count: int, rng: np.random.Generator) -> list[tuple[int, ...]]:
    subsets = []
    for _ in range(count):
        keep = rng.random(len(valid_banks)) < 0.5
        subsets.append(tuple(bank for bank, kept in zip(valid_banks, keep) if kept))
    return subsets


def pick_subsets(valid_banks: list[int], first_occurrence: bool,
                 rng: np.random.Generator) -> list[tuple[int, ...]]:
    """這個座標要測的 pending 子集合(bank 的 row-major 編號)。"""
    if not valid_banks:
        return [()]
    full = tuple(valid_banks)
    if not first_occurrence:
        return random_subsets(valid_banks, REPEAT_SUBSETS, rng) + [full]
    if len(valid_banks) <= EXHAUSTIVE_BANKS:
        return [subset for size in range(len(valid_banks) + 1)
                for subset in itertools.combinations(valid_banks, size)]
    singles = [(bank,) for bank in valid_banks]
    return random_subsets(valid_banks, SAMPLED_SUBSETS, rng) + [(), full] + singles


def build_reference_rows(axis_candidates, kernel_size: int, stride: int, padding: int,
                         out_rows: int, out_cols: int, y_width: int, x_width: int,
                         rng: np.random.Generator) -> list[str]:
    bank_count = (kernel_size + stride - 1) // stride
    candidate_count = (kernel_size - 1) // stride + 1   # 訓練端的寫法,跟 ceil(K/S) 相同
    if candidate_count != bank_count:
        raise RuntimeError(f"候選數 {candidate_count} 跟 bank 數 {bank_count} 不一致")
    out_y_width = max(1, (out_rows - 1).bit_length())
    out_x_width = max(1, (out_cols - 1).bit_length())

    row_candidates = axis_candidate_lists(axis_candidates, y_width, kernel_size, stride, padding,
                                          candidate_count, out_rows)
    col_candidates = axis_candidate_lists(axis_candidates, x_width, kernel_size, stride, padding,
                                          candidate_count, out_cols)

    rows = []
    step_count = 0
    seen_patterns = set()
    for in_y, y_candidates in enumerate(row_candidates):
        top_row = axis_min_bank(in_y, stride, padding, bank_count)
        check_min_bank_order([out_y for out_y, _ in y_candidates], top_row, bank_count, in_y)
        for in_x, x_candidates in enumerate(col_candidates):
            left_col = axis_min_bank(in_x, stride, padding, bank_count)
            check_min_bank_order([out_x for out_x, _ in x_candidates], left_col, bank_count, in_x)

            # 合法 bank 的座標;兩軸都合法才是候選,跟 build_conv_structure 的 valid_y & valid_x 相同
            coords: dict[int, tuple[int, int]] = {}
            for out_y, _ in y_candidates:
                for out_x, _ in x_candidates:
                    bank = (out_y % bank_count) * bank_count + out_x % bank_count
                    if bank in coords:
                        raise RuntimeError(f"in_y={in_y} in_x={in_x} 有兩個候選落在 bank {bank}")
                    coords[bank] = (out_y, out_x)
            valid_banks = sorted(coords)

            pattern = (top_row, left_col, tuple(valid_banks))
            subsets = pick_subsets(valid_banks, pattern not in seen_patterns, rng)
            seen_patterns.add(pattern)

            for subset in subsets:
                bank_fields = []
                for bank in range(bank_count * bank_count):
                    if bank in coords:
                        out_y, out_x = coords[bank]
                    else:
                        out_y = 0 if rng.random() < GARBAGE_ZERO_PROB else int(rng.integers(0, 1 << out_y_width))
                        out_x = 0 if rng.random() < GARBAGE_ZERO_PROB else int(rng.integers(0, 1 << out_x_width))
                    bank_fields += [int(bank in coords), int(bank in subset), out_y, out_x]
                # 神經元編號由小到大;同一個 o_c,編號差只在 o_y * OUT_COLS + o_x
                order = sorted(subset, key=lambda bank: coords[bank][0] * out_cols + coords[bank][1])
                fields = ["case", in_y, in_x, top_row, left_col] + bank_fields + [len(order)] + order
                rows.append(" ".join(str(field) for field in fields))
                step_count += len(order)

    rows.append(f"end {len(rows)} {step_count}")
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

    rng = np.random.default_rng(SEED)
    args.out_dir.mkdir(parents=True, exist_ok=True)
    for params in PARAM_SETS:
        rows = build_reference_rows(_axis_candidates, *params, rng)
        out_path = args.out_dir / ref_file_name(*params)
        out_path.write_text("\n".join(rows) + "\n", encoding="ascii")
        print(f"{out_path.name}: {rows[-1]}, {out_path.stat().st_size / 1e6:.1f} MB")


if __name__ == "__main__":
    main()
