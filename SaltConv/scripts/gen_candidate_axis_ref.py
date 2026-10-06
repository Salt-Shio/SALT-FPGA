"""產生 tb_candidate_axis.sv 用的參考答案。

候選用訓練端 salt_core.connectivity.conv._axis_candidates 算,也就是 Conv.md 的字面定義:
從 o_min 往上列 ceil(K/S) 個,檢查 o <= o_max、o >= 0、o < O_max,tap = i - o*S + P。
再照 Conv.md 的 banking 放到 bank (o mod M),補上 bank_offset = floor(o/M)。

每組參數輸出一個文字檔,一行一個 in_coord,欄位以空白分隔:
    in_coord  valid_0 out_coord_0 bank_offset_0 tap_0  valid_1 out_coord_1 ...
沒有候選的 bank 寫 valid=0,其餘三個欄位填 0,testbench 比對時不看。

用法(WSL,conda 環境 jax):
    python gen_candidate_axis_ref.py \
        --training-repo /mnt/d/Project/Spiking-Affine-Lazy-Training \
        --out-dir /mnt/d/Project/SALT-FPGA/SaltConv/SaltConv.srcs/sim_1/new/ref
"""
import argparse
import sys
from pathlib import Path

import numpy as np

# (KERNEL_SIZE, STRIDE, PADDING, OUT_SIZE, IN_COORD_WIDTH),跟 run_tb_candidate_axis.tcl 的清單一致
PARAM_SETS = [
    (3, 1, 1, 64, 9),   # 預設,M=3
    (3, 2, 1, 32, 6),   # S>1,候選可能少於 M
    (5, 2, 2, 20, 6),   # M=3、P=2
    (4, 1, 0, 7, 4),    # M=4,OUT_SIZE 不是 M 的倍數
    (7, 3, 3, 15, 5),   # S 不是 2 的次方
    (1, 2, 0, 16, 5),   # S>K,M=1,有座標沒有候選
    (2, 3, 0, 10, 5),   # tap 截斷前不合法、截斷後看起來合法的情況
    (3, 1, 1, 1, 3),    # OUT_SIZE=1,位寬下限保護
]


def ref_file_name(kernel_size: int, stride: int, padding: int, out_size: int,
                  in_coord_width: int) -> str:
    """參考答案檔名,testbench 用同一套規則組出檔名。"""
    return (f"candidate_axis_K{kernel_size}_S{stride}_P{padding}"
            f"_O{out_size}_W{in_coord_width}.txt")


def build_reference_rows(axis_candidates, kernel_size: int, stride: int, padding: int,
                         out_size: int, in_coord_width: int) -> list[str]:
    """窮舉 in_coord = 0 ~ 2^in_coord_width - 1,回傳每一行的文字。"""
    import jax.numpy as jnp

    bank_count = (kernel_size + stride - 1) // stride
    candidate_count = (kernel_size - 1) // stride + 1   # 訓練端的寫法,跟 ceil(K/S) 相同
    if candidate_count != bank_count:
        raise RuntimeError(f"候選數 {candidate_count} 跟 bank 數 {bank_count} 不一致")

    in_coords = np.arange(2 ** in_coord_width, dtype=np.int32)
    out_coords, valids, taps = axis_candidates(jnp.asarray(in_coords), kernel_size, stride,
                                               padding, candidate_count, out_size)
    out_coords = np.asarray(out_coords)
    valids = np.asarray(valids)
    taps = np.asarray(taps)

    rows = []
    for row_idx, in_coord in enumerate(in_coords):
        banks = [(0, 0, 0, 0)] * bank_count
        for candidate_idx in range(candidate_count):
            if not valids[row_idx, candidate_idx]:
                continue
            out_coord = int(out_coords[row_idx, candidate_idx])
            tap = int(taps[row_idx, candidate_idx])
            if not 0 <= tap < kernel_size:
                raise RuntimeError(f"in_coord={in_coord} 的合法候選 tap={tap} 超出 kernel 範圍")
            bank = out_coord % bank_count
            if banks[bank][0]:
                raise RuntimeError(f"in_coord={in_coord} 有兩個候選落在 bank {bank}")
            banks[bank] = (1, out_coord, out_coord // bank_count, tap)
        fields = [str(int(in_coord))]
        for bank_fields in banks:
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
