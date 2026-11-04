"""產生 tb_fc_spike_select.sv 用的參考答案。

送出順序用訓練端 salt_core.stream.extract_output_events_fc 算:它是 FC 層 forward 把這一層的 spike 排成
下一層事件流的函式,同一筆事件讓幾顆神經元同時 fire 時,照神經元編號由小到大(FC.md 第 4 節 ②)。
每個 case 是「第 y 列、這一列哪幾行還沒送」:做一個 n_out 顆神經元、只有一筆輸入事件的 spike_mask,
在 y*n_col + x 的位置設成 fire,呼叫 extract_output_events_fc,前 n_real_events 筆的 event_source_idx
就是預期送出的 i。最後一列空的位置(y*n_col + x >= n_out)上層會先遮成 0,不會亮。
每一列窮舉這一列合法行的全部子集合。

答案檔一行一個指令,第一個欄位是種類,欄位以空白分隔:
    case <row_base> <pending> <count> <neuron_1> ... <neuron_count>
        row_base = y*n_col;pending 是 n_col 位元的 bitmask(第 x 位元 = 第 x 行),寫成十進位整數;
        neuron 是預期送出的 i,依送出順序;count = pending 亮的個數。
    end <case_count> <step_count>
        case 行數、預期送出的總筆數,testbench 用來確認沒有漏掉。

用法(WSL,conda 環境 jax,在 scripts/fc 目錄執行):
    python gen_fc_spike_select_ref.py \
        --training-repo /mnt/d/Project/Spiking-Affine-Lazy-Training \
        --out-dir /mnt/d/Project/SALT-FPGA/SaltNET/SaltNET.srcs/sim_1/new/fc/ref
"""
import argparse
import sys
from pathlib import Path

import numpy as np

# 參數組:(OUT_NEURONS, NEURONS_PER_ROW),跟 run_tb_fc_spike_select.tcl 的清單一致
PARAM_SETS = [
    (10, 4),   # 訓練端 out 層的形狀(n_col 先用 4):2 的次方,直接接位元;最後一列只有 2 顆
    (10, 3),   # 不是 2 的次方,用加法;最後一列只有 1 顆
    (13, 5),   # 比較大、不是 2 的次方;最後一列 3 顆
    (20, 8),   # 比較大的 2 的次方;最後一列 4 顆
    (5, 1),    # n_col = 1:x 一定是 0
    (3, 4),    # n_col > n_out:只有一列,i 的位寬等於 x 的位寬
    (2, 8),    # 只有一列,i 的位寬比 x 的位寬小
    (1, 1),    # n_out = n_col = 1:位寬下限保護
]


def ref_file_name(out_neurons: int, neurons_per_row: int) -> str:
    """參考答案檔名,testbench 用同一套規則組出檔名。"""
    return f"fc_spike_select_OUT{out_neurons}_COL{neurons_per_row}.txt"


def emitted_neurons(extract_output_events_fc, fired: list[int], out_neurons: int) -> list[int]:
    """一筆輸入事件讓 fired 這幾顆神經元 fire,訓練端排出來的送出順序(神經元編號)。"""
    import jax.numpy as jnp

    spike_mask = np.zeros((out_neurons, 1), dtype=bool)
    spike_mask[fired, 0] = True
    stream = extract_output_events_fc(jnp.asarray(spike_mask),
                                      jnp.zeros((out_neurons, 1), dtype=jnp.int32),
                                      jnp.ones((out_neurons, 1), dtype=jnp.float32),
                                      jnp.zeros((1,), dtype=jnp.float32))
    real_count = int(stream.n_real_events)
    if real_count != len(fired):
        raise RuntimeError(f"fire {fired}:訓練端排出 {real_count} 筆,應該是 {len(fired)} 筆")
    return [int(neuron) for neuron in np.asarray(stream.event_source_idx)[:real_count]]


def build_reference_rows(extract_output_events_fc, out_neurons: int, neurons_per_row: int) -> list[str]:
    row_count = -(-out_neurons // neurons_per_row)
    rows = []
    step_count = 0
    for row in range(row_count):
        row_base = row * neurons_per_row
        valid_columns = [column for column in range(neurons_per_row) if row_base + column < out_neurons]
        for subset in range(1 << len(valid_columns)):
            columns = [column for bit, column in enumerate(valid_columns) if (subset >> bit) & 1]
            pending = sum(1 << column for column in columns)
            order = emitted_neurons(extract_output_events_fc, [row_base + column for column in columns],
                                    out_neurons)
            fields = ["case", row_base, pending, len(order)] + order
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
    from salt_core.stream import extract_output_events_fc

    args.out_dir.mkdir(parents=True, exist_ok=True)
    for params in PARAM_SETS:
        rows = build_reference_rows(extract_output_events_fc, *params)
        out_path = args.out_dir / ref_file_name(*params)
        out_path.write_text("\n".join(rows) + "\n", encoding="ascii")
        print(f"{out_path.name}: {rows[-1]}")


if __name__ == "__main__":
    main()
