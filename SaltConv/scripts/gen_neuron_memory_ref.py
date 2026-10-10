"""產生 tb_neuron_memory.sv 用的參考答案。

testbench 例化 CandidateGrid + NeuronMemory,讀寫位址都由 RTL 的 CandidateGrid 算。這裡用訓練端的候選規則
(gen_candidate_grid_ref.py 的 axis_candidate_lists,訓練端 salt_core.connectivity.conv._axis_candidates)
算每一步 (in_y, in_x, o_c) 每個 bank 的候選神經元 (o_c, o_y, o_x),bank 是 (o_y mod M, o_x mod M)。
逐顆神經元記住 (V̂, t_last),排出每一拍的操作跟預期讀出值。時序照 Conv.md 5.2、5.3(讀取延遲 1 拍):
這拍讀的那一步,下一拍寫回;下一拍同時可以讀下一步。

測試分五段(答案檔 cycle 行的 phase 欄位):
  1. reset、清除:放開 rst_n 後 clearing 要剛好維持 BANK_DEPTH 拍。
  2. 全部讀一遍:每顆神經元都要是 (0, 0)。
  3. 隨機讀改寫:隨機事件,每筆事件 o_c 照 0 ~ OC-1 的順序;每一步讀出後,下一拍寫回隨機的 (V̂, t_last),
     值涵蓋 w 位元有號、TIME_WIDTH 位元無號的上下限。隨機插空拍;下一步的讀跟這一拍的寫碰到同一顆神經元時
     也插空拍(NeuronMemory 同一拍讀寫同一個位址時,讀出的值不保證)。
  4. 全部讀一遍:每顆神經元要等於最後寫進去的值。
  5. 再 reset、清除一次,全部讀一遍:每顆神經元都要回到 (0, 0)。
「全部讀一遍」窮舉每個 o_c、兩軸都有候選的 (in_y, in_x),產生時會檢查每顆神經元至少讀到一次。

答案檔一行一個指令,第一個欄位是種類,欄位以空白分隔:
    reset <hold_cycles> <clear_cycles>
        rst_n 拉低 hold_cycles 拍再放開,放開後 clearing 要剛好維持 clear_cycles 拍。
    cycle <phase> <do_read> <in_y> <in_x> <out_channel> <do_write>  [bank (0,0)] ... [bank (M-1,M-1)]
        一拍。do_read=1:這拍用 (in_y, in_x, out_channel) 讀,do_read=0 時這三個欄位填 0。
        do_write=1:這拍寫回上一拍讀的那一步(上一拍一定是 do_read=1)。
        每個 bank 六個欄位,bank 依 (r_y, r_x) row-major 排列:
            valid check membrane last_time write_membrane write_last_time
          valid:這拍讀的那一步這個 bank 有沒有候選(do_read=0 時是 0)
          check:posedge 後要不要比對讀出值(這個 bank 還沒讀過任何值時是 0)
          membrane last_time:posedge 後預期的讀出值;valid=0 的 bank 是保持的上一次讀出值
          write_membrane write_last_time:這拍寫進這個 bank 的值,沒有寫入時填 0
    end <cycle_count> <check_count>
        cycle 行數、要比對讀出值的 (拍, bank) 總數,testbench 用來確認沒有漏掉。

用法(WSL,conda 環境 jax,在 scripts 目錄執行,要 import 同目錄的 gen_candidate_grid_ref.py):
    python gen_neuron_memory_ref.py \
        --training-repo /mnt/d/Project/Spiking-Affine-Lazy-Training \
        --out-dir /mnt/d/Project/SALT-FPGA/SaltConv/SaltConv.srcs/sim_1/new/ref
"""
import argparse
import sys
from pathlib import Path

import numpy as np

from gen_candidate_grid_ref import axis_candidate_lists

# (KERNEL_SIZE, STRIDE, PADDING, OUT_ROWS, OUT_COLS, OUT_CHANNELS, Y_WIDTH, X_WIDTH, MEMBRANE_WIDTH, TIME_WIDTH),
# 跟 run_tb_neuron_memory.tcl 的清單一致
PARAM_SETS = [
    (3, 2, 1, 17, 17, 8, 6, 6, 12, 16),    # 訓練端 conv1 繞回版,M=2
    (3, 2, 1, 17, 17, 8, 6, 6, 9, 16),     # 訓練端 conv1 飽和版
    (3, 2, 1, 9, 9, 16, 5, 5, 14, 16),     # 訓練端 conv2 繞回版
    (3, 2, 1, 9, 9, 16, 5, 5, 11, 16),     # 訓練端 conv2 飽和版
    (3, 1, 1, 13, 11, 5, 4, 4, 5, 3),      # M=3,長寬不同且不是 M 的倍數
    (4, 1, 0, 7, 5, 3, 4, 3, 2, 1),        # M=4;MEMBRANE_WIDTH、TIME_WIDTH 下限
    (5, 2, 2, 10, 7, 3, 5, 4, 17, 21),     # M=3、S>1,候選可能少於 M;字寬 38 bits,最寬的一組
    (1, 2, 0, 4, 3, 2, 3, 3, 7, 5),        # S>K,M=1,有座標沒有候選
    (3, 1, 1, 1, 1, 1, 2, 2, 3, 2),        # 輸出 1x1、OC=1:BANK_DEPTH=1,每一步都撞到上一步的寫
]

SEED = 0
RESET_HOLD_CYCLES = 3
RANDOM_STEPS = 6000      # 隨機讀改寫的步數下限,事件數 = ceil(RANDOM_STEPS / OC)
BUBBLE_PROB = 0.2        # 隨機讀改寫每一步之前插空拍的機率
EXTREME_PROB = 0.1       # 寫入值直接取上限或下限的機率


def ref_file_name(kernel_size: int, stride: int, padding: int, out_rows: int, out_cols: int,
                  out_channels: int, y_width: int, x_width: int, membrane_width: int,
                  time_width: int) -> str:
    """參考答案檔名,testbench 用同一套規則組出檔名。"""
    return (f"neuron_memory_K{kernel_size}_S{stride}_P{padding}_R{out_rows}_C{out_cols}"
            f"_OC{out_channels}_Y{y_width}_X{x_width}_W{membrane_width}_T{time_width}.txt")


def step_banks(row_candidates: list, col_candidates: list, bank_count: int, in_y: int, in_x: int,
               out_channel: int) -> list[list[tuple[int, int, int] | None]]:
    """一步 (in_y, in_x, out_channel) 每個 bank 的候選神經元 (o_c, o_y, o_x),沒有候選的 bank 是 None。"""
    banks = [[None] * bank_count for _ in range(bank_count)]
    # 兩軸都合法才是候選,跟 build_conv_structure 的 valid_y & valid_x 相同
    for out_y, _ in row_candidates[in_y]:
        for out_x, _ in col_candidates[in_x]:
            row_bank = out_y % bank_count
            col_bank = out_x % bank_count
            if banks[row_bank][col_bank] is not None:
                raise RuntimeError(f"in_y={in_y} in_x={in_x} 有兩個候選落在 bank ({row_bank},{col_bank})")
            banks[row_bank][col_bank] = (out_channel, out_y, out_x)
    return banks


def step_neurons(banks: list) -> set[tuple[int, int, int]]:
    return {neuron for bank_row in banks for neuron in bank_row if neuron is not None}


class ReferenceBuilder:
    """逐拍產生答案檔的行,同時記住每顆神經元的 (V̂, t_last)、每個 bank 保持的讀出值。"""

    def __init__(self, bank_count: int, bank_depth: int, membrane_width: int, time_width: int,
                 rng: np.random.Generator):
        self.bank_count = bank_count
        self.bank_depth = bank_depth
        self.membrane_range = (-(1 << (membrane_width - 1)), (1 << (membrane_width - 1)) - 1)
        self.time_range = (0, (1 << time_width) - 1)
        self.rng = rng
        self.lines: list[str] = []
        self.cycle_count = 0
        self.check_count = 0
        # 沒寫過的神經元不在 dict 裡,值是清除後的 (0, 0)
        self.neuron_state: dict[tuple[int, int, int], tuple[int, int]] = {}
        # 每個 bank 上一次讀出的值,還沒讀過是 None
        self.held_read = [[None] * bank_count for _ in range(bank_count)]
        # 上一拍讀的那一步要寫回的值:每個 bank 是 (神經元, (V̂, t_last)) 或 None;上一拍沒讀時是 None
        self.pending_write: list[list[tuple | None]] | None = None

    def reset(self) -> None:
        if self.pending_write is not None:
            raise RuntimeError("reset 之前還有沒寫回的步驟")
        self.lines.append(f"reset {RESET_HOLD_CYCLES} {self.bank_depth}")
        self.neuron_state = {}

    def random_value(self, value_range: tuple[int, int]) -> int:
        low, high = value_range
        if self.rng.random() < EXTREME_PROB:
            return low if self.rng.random() < 0.5 else high
        return int(self.rng.integers(low, high + 1))

    def pending_neurons(self) -> set[tuple[int, int, int]]:
        if self.pending_write is None:
            return set()
        return {entry[0] for bank_row in self.pending_write for entry in bank_row if entry is not None}

    def cycle(self, phase: int, step: tuple | None, write_back: bool) -> None:
        """一拍:讀 step(None 是不讀),寫回上一拍讀的那一步。write_back=True 時替這一步的候選產生新值,下一拍寫回。"""
        if step is not None and step_neurons(step[3]) & self.pending_neurons():
            raise RuntimeError(f"同一拍讀、寫同一顆神經元:step={step[:3]}")
        do_write = self.pending_write is not None
        if step is None:
            read_fields = [0, 0, 0, 0]
        else:
            in_y, in_x, out_channel, _ = step
            read_fields = [1, in_y, in_x, out_channel]
        fields = ["cycle", phase] + read_fields + [int(do_write)]

        next_pending = [[None] * self.bank_count for _ in range(self.bank_count)] if write_back else None
        for row_bank in range(self.bank_count):
            for col_bank in range(self.bank_count):
                neuron = None if step is None else step[3][row_bank][col_bank]
                if neuron is not None:
                    # 同拍讀寫不會碰到同一顆神經元,讀到的是這拍寫入之前的值
                    self.held_read[row_bank][col_bank] = self.neuron_state.get(neuron, (0, 0))
                    if write_back:
                        next_pending[row_bank][col_bank] = (
                            neuron, (self.random_value(self.membrane_range), self.random_value(self.time_range)))
                expected = self.held_read[row_bank][col_bank]
                if expected is None:
                    fields += [int(neuron is not None), 0, 0, 0]
                else:
                    fields += [int(neuron is not None), 1, expected[0], expected[1]]
                    self.check_count += 1

                write_entry = None if self.pending_write is None else self.pending_write[row_bank][col_bank]
                if write_entry is None:
                    fields += [0, 0]
                else:
                    fields += list(write_entry[1])

        if self.pending_write is not None:
            for bank_row in self.pending_write:
                for entry in bank_row:
                    if entry is not None:
                        self.neuron_state[entry[0]] = entry[1]
        self.pending_write = next_pending
        self.lines.append(" ".join(str(value) for value in fields))
        self.cycle_count += 1

    def run_steps(self, phase: int, steps: list[tuple], write_back: bool, bubble_prob: float = 0.0) -> None:
        """依序讀每一步;下一步跟上一步的寫回撞到同一顆神經元時,先插一個只寫回的空拍。最後把剩下的寫回做完。"""
        for step in steps:
            collides = bool(step_neurons(step[3]) & self.pending_neurons())
            if collides or self.rng.random() < bubble_prob:
                self.cycle(phase, None, False)
            self.cycle(phase, step, write_back)
        if self.pending_write is not None:
            self.cycle(phase, None, False)

    def finish(self) -> list[str]:
        return self.lines + [f"end {self.cycle_count} {self.check_count}"]


def build_reference_lines(axis_candidates, kernel_size: int, stride: int, padding: int, out_rows: int,
                          out_cols: int, out_channels: int, y_width: int, x_width: int, membrane_width: int,
                          time_width: int) -> list[str]:
    bank_count = (kernel_size + stride - 1) // stride
    candidate_count = (kernel_size - 1) // stride + 1   # 訓練端的寫法,跟 ceil(K/S) 相同
    if candidate_count != bank_count:
        raise RuntimeError(f"候選數 {candidate_count} 跟 bank 數 {bank_count} 不一致")
    row_slots = (out_rows + bank_count - 1) // bank_count
    col_slots = (out_cols + bank_count - 1) // bank_count
    bank_depth = out_channels * row_slots * col_slots

    row_candidates = axis_candidate_lists(axis_candidates, y_width, kernel_size, stride, padding,
                                          candidate_count, out_rows)
    col_candidates = axis_candidate_lists(axis_candidates, x_width, kernel_size, stride, padding,
                                          candidate_count, out_cols)

    def make_step(in_y: int, in_x: int, out_channel: int) -> tuple:
        return (in_y, in_x, out_channel,
                step_banks(row_candidates, col_candidates, bank_count, in_y, in_x, out_channel))

    # 全部讀一遍:每個 o_c、兩軸都有候選的座標
    sweep_steps = [make_step(in_y, in_x, out_channel)
                   for out_channel in range(out_channels)
                   for in_y in range(2 ** y_width) if row_candidates[in_y]
                   for in_x in range(2 ** x_width) if col_candidates[in_x]]
    all_neurons = {(out_channel, out_y, out_x)
                   for out_channel in range(out_channels) for out_y in range(out_rows) for out_x in range(out_cols)}
    swept = set().union(*(step_neurons(step[3]) for step in sweep_steps))
    if swept != all_neurons:
        raise RuntimeError(f"全部讀一遍漏了 {len(all_neurons - swept)} 顆神經元")

    rng = np.random.default_rng(SEED)
    event_count = -(-RANDOM_STEPS // out_channels)
    random_steps = []
    for _ in range(event_count):
        in_y = int(rng.integers(0, 2 ** y_width))
        in_x = int(rng.integers(0, 2 ** x_width))
        random_steps.extend(make_step(in_y, in_x, out_channel) for out_channel in range(out_channels))

    builder = ReferenceBuilder(bank_count, bank_depth, membrane_width, time_width, rng)
    builder.reset()
    builder.run_steps(2, sweep_steps, write_back=False)
    builder.run_steps(3, random_steps, write_back=True, bubble_prob=BUBBLE_PROB)
    builder.run_steps(4, sweep_steps, write_back=False)
    builder.reset()
    builder.run_steps(5, sweep_steps, write_back=False)
    return builder.finish()


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
        lines = build_reference_lines(_axis_candidates, *params)
        out_path = args.out_dir / ref_file_name(*params)
        out_path.write_text("".join(f"{line}\n" for line in lines), encoding="ascii")
        print(f"{out_path.name}: {lines[-1]}")


if __name__ == "__main__":
    main()
