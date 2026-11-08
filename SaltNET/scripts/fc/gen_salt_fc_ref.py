"""產生整層 SaltFC testbench 的參考答案,同時寫權重檔、門檻檔、衰減表檔。
- 不 fire 的層(SPIKE_OUTPUT = 0):tb_salt_fc_no_spike.sv,清單見 run_tb_salt_fc_no_spike.tcl。
- 會 fire 的層(SPIKE_OUTPUT = 1):tb_salt_fc_ready_*.sv 四支共用,清單見 run_tb_salt_fc.tcl。

整層 SaltFC 的答案:每筆樣本餵進一串輸入事件 (src, t),比對輸出事件 (i, t) 的順序、每筆事件之後全部神經元的 V̂
(膜電位輸出,也給 tb_fc_membrane_register_*.sv 用)、樣本結束時每顆神經元的 V̂、out_ready 一直是 1、輸入一直有時的拍數。

答案有兩份,互相比對,一致才寫答案檔(同 scripts/conv/gen_salt_conv_ref.py):
- 官方:訓練端 FCLayer.forward + QuantBackend(整層的整數掃描,輸出事件流照 salt_core/stream.py 排序),trace=True。
  容量不夠時把容量放大到 diag.needed 再跑一次。
  trace.v_steps 是每一步寫回之後的暫存器值(fire 的已經歸 0),整數掃描一步一筆事件,前 n_real 欄就是
  每筆真事件之後的 V̂;後面補齊的欄 Δt = 0、權重 0,值不變。
- 逐筆迴圈:照硬體的做法一筆事件一筆事件算,t_last 整層一份(上一筆事件的 t),
  更新用訓練端 apply_decay_table_int + process_event。官方答案沒有的兩樣東西從這裡來:
    每筆事件每列 fire 的個數 k(算拍數)、做完最後一筆事件時的 V̂。
  每筆事件之後的 V̂ 要跟官方 trace.v_steps 的前 n_real 欄逐筆、逐顆相同。
  官方的 v_final 多做了一步 catch-up:每顆神經元再衰減到樣本最後一筆事件的時間(權重 0)。
  FC 每筆事件都更新全部神經元,catch-up 的 Δt 一律是 0;逐筆迴圈照樣補上同一步之後要等於官方的 v_final,
  輸出事件序列也要完全相同。
硬體不做 catch-up,所以 testbench 比的是 catch-up 之前的 V̂。

拍數:out_ready 一直是 1、輸入一直有時,從第一列算的那一拍到最後一列送完那一拍。
算法跟 SaltConv 相同,o_c 換成列(FC.md 第 5 節 ⑦⑧),直接用 gen_salt_conv_ref.cycle_count:
每列 max(1, k) 拍,不重疊時兩次讀之間隔 L 步,n_row <= L 時兩筆事件的第 0 列隔 L + 1 步。
答案檔對 CYCLE_CONFIGS 裡每組 (R, C, OVERLAP) 各列一個拍數,testbench 照自己的參數挑。

參數組分三種:
- 訓練端的 out 層(不 fire),繞回版、飽和版各一份,n_col = 4、10 各一份(權重檔照 n_col 打包)。
  量化資料夾照 quant_versions.txt。n_col 跟匯出時相同(EXPORTED_FC_COLS)、sources_1/mem 有這個量化資料夾的
  out_weight.mem 時,寫的權重檔、衰減表檔要跟匯出的 out_weight.mem、out_decay.mem 相同。
  輸入是 test 的前 SAMPLE_COUNT 筆(量化資料夾 eval/test.yaml 記的評估取樣),經訓練端 conv1 → conv2 的輸出;
  conv2 輸出流的 event_source_idx 就是 FC 的 src(o_c·H_out·W_out + o_y·W_out + o_x,gen_salt_conv_ref.py
  逐筆迴圈跟官方比對時已經確認這個攤平順序)。
- 人工參數組,不 fire:隨機權重、衰減表、事件,權重偏正讓膜電位常碰到暫存器範圍;第一筆事件 t = 0。
- 人工參數組,會 fire:同上再加隨機門檻,門檻大多壓低讓同一列常有多個 fire。訓練端沒有會 fire 的 FC 層,
  只有人工參數組。門檻兩種(RTL 的 SHARED_THRESHOLD):每顆一個(per-channel)、整層一個(per-tensor)。
權重檔、門檻檔、衰減表檔都用訓練端 salt_core.fpga_export 的函式寫,跟答案放在同一個目錄
(FC 的 .mem 等 n_col 選定才 commit 進 sources_1/mem,TODO Part 1)。

答案檔一行一筆,第一個欄位是種類,欄位以空白分隔,全部十進位,有號數直接寫負號:
    coverage <stall_on_compute_cycle> <stall_with_more_left> <stall_last_of_row> <stall_last_of_event_next_queued> <stall_last_of_event>
        只有會 fire 的層有這一行(第一行)。testbench 的涵蓋項目裡,跟 fire 分布有關的五項
        這組參數碰不碰得到(1:要求至少發生一次):
          stall_on_compute_cycle:有 (事件, 列) fire 1 個以上(算的那一拍就有東西送)
          stall_with_more_left:有 (事件, 列) fire 2 個以上
          stall_last_of_row:有 y < n_row-1 的 (事件, 列) fire 1 個以上
          stall_last_of_event_next_queued:不是樣本最後一筆的事件,在 y = n_row-1 fire 1 個以上
          stall_last_of_event:有事件在 y = n_row-1 fire 1 個以上
    sample <in_count> <out_count> <state_count> <cycle_count> ...   每組 (R, C, OVERLAP) 一個,照 CYCLE_CONFIGS 的順序
    in <src> <t>                × in_count,照輸入順序
    out <i> <t>                 × out_count,照送出順序(不 fire 時沒有)
    update <t> <V̂_0> ... <V̂_{n_out-1}>   × in_count,照輸入順序:處理完這筆事件之後全部神經元的 V̂(fire 的是歸 0 之後)
    state <neuron> <membrane>   × state_count(= n_out),神經元編號 i 的 V̂
    end <sample_count>

用法(WSL,conda 環境 jax,在 scripts/fc 目錄執行):
    python gen_salt_fc_ref.py \
        --training-repo /mnt/d/Project/Spiking-Affine-Lazy-Training \
        --out-dir /mnt/d/Project/SALT-FPGA/SaltNET/SaltNET.srcs/sim_1/new/fc/ref
"""
import argparse
import dataclasses
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "conv"))
from gen_salt_conv_ref import CYCLE_CONFIGS, SAMPLE_COUNT, cycle_count, signed_range, write_lines  # noqa: E402
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))   # scripts/:quant_versions.py
from quant_versions import QUANT_RUN_DIR, SATURATE_VERSION, WRAP_VERSION  # noqa: E402  量化資料夾,換權重改 quant_versions.txt

TRAINED_LAYER = "out"
SEED = 0
# SaltNET.srcs/sources_1/mem/<量化資料夾>/out_*.mem 匯出時的 n_col;有這兩個檔的資料夾,同一個 n_col 的參數組要跟它相同
EXPORTED_FC_COLS = 4
MEM_DIR = Path(__file__).resolve().parents[2] / "SaltNET.srcs" / "sources_1" / "mem"


@dataclasses.dataclass(frozen=True)
class ParamSet:
    """一組 SaltFC 參數。整數欄位跟 run_tb_salt_fc_no_spike.tcl、run_tb_salt_fc.tcl 的清單、
    tb_salt_fc_no_spike.sv、tb_salt_fc_common.svh 的 parameter 一致。"""
    in_neurons: int
    out_neurons: int
    neurons_per_row: int
    time_width: int
    weight_width: int
    membrane_int_width: int
    membrane_frac_width: int
    decay_frac_width: int
    decay_table_depth: int
    round_enabled: int
    saturate_enabled: int
    spike_output: int
    shared_threshold: int = 0   # 只有 spike_output = 1 時有意義

    @property
    def row_count(self) -> int:
        return -(-self.out_neurons // self.neurons_per_row)

    @property
    def membrane_width(self) -> int:
        return self.membrane_int_width + self.membrane_frac_width

    @property
    def stem(self) -> str:
        """答案檔、資料檔共用的檔名主體,testbench、run_tb_*.tcl 用同一套規則組出檔名。
        會 fire 的層多一段 _SH<shared_threshold>(門檻檔格式不同);不 fire 的層沒有門檻,不加。"""
        stem = (f"salt_fc_IN{self.in_neurons}_OUT{self.out_neurons}_COL{self.neurons_per_row}"
                f"_IV{self.membrane_int_width}_FV{self.membrane_frac_width}_RD{self.round_enabled}"
                f"_SAT{self.saturate_enabled}_SPK{self.spike_output}")
        if self.spike_output:
            stem += f"_SH{self.shared_threshold}"
        return stem


# (量化資料夾, 參數)
TRAINED_SETS = [
    (WRAP_VERSION, ParamSet(1296, 10, 4, 16, 7, 14, 0, 6, 75, 1, 0, 0)),
    (WRAP_VERSION, ParamSet(1296, 10, 10, 16, 7, 14, 0, 6, 75, 1, 0, 0)),
    (SATURATE_VERSION, ParamSet(1296, 10, 4, 16, 7, 11, 0, 6, 75, 1, 1, 0)),
    (SATURATE_VERSION, ParamSet(1296, 10, 10, 16, 7, 11, 0, 6, 75, 1, 1, 0)),
]

# (參數, 樣本數, 每筆樣本的事件數)
# 會 fire 的排在後面:同一個亂數產生器依序抽,不 fire 那幾組的答案跟加 fire 之前相同
SYNTHETIC_SETS = [
    (ParamSet(7, 10, 3, 11, 5, 6, 0, 4, 10, 1, 0, 0), 3, 100),   # n_col 不是 2 的次方、最後一列 1 顆、n_row=4;round、繞回
    (ParamSet(7, 10, 4, 12, 6, 7, 2, 5, 20, 0, 1, 0), 3, 100),   # n_row=3,f_V=2;truncate、飽和
    (ParamSet(5, 3, 4, 10, 4, 5, 0, 3, 4, 1, 1, 0), 3, 100),     # n_row=1、最後一列不滿;round、飽和
    (ParamSet(7, 5, 1, 12, 7, 8, 0, 6, 12, 0, 0, 0), 3, 100),    # n_col=1;truncate、繞回
    (ParamSet(1, 1, 1, 9, 4, 4, 0, 3, 3, 1, 1, 0), 4, 60),       # 位寬下限;round、飽和
    # 會 fire:最後一個欄位 1 是整層一個門檻
    (ParamSet(7, 10, 3, 11, 5, 6, 0, 4, 10, 1, 0, 1, 0), 3, 100),    # 每顆一個;n_col 不是 2 的次方、最後一列 1 顆、n_row=4
    (ParamSet(7, 10, 4, 12, 6, 7, 2, 5, 20, 0, 1, 1, 1), 3, 100),    # 整層一個;n_row=3,f_V=2;truncate、飽和
    (ParamSet(5, 3, 4, 10, 4, 5, 0, 3, 4, 1, 1, 1, 0), 3, 100),      # 每顆一個;n_row=1、最後一列不滿
    (ParamSet(5, 3, 4, 10, 4, 5, 0, 3, 4, 1, 1, 1, 1), 3, 100),      # 整層一個;n_row=1
    (ParamSet(7, 5, 1, 12, 7, 8, 0, 6, 12, 0, 0, 1, 1), 3, 100),     # 整層一個;n_col=1、n_row=5;truncate、繞回
    (ParamSet(9, 16, 8, 12, 6, 8, 0, 5, 16, 1, 0, 1, 0), 3, 100),    # 每顆一個;n_col=8 是 2 的次方(i 直接接位元)、整除、n_row=2
    (ParamSet(1, 1, 1, 9, 4, 4, 0, 3, 3, 1, 1, 1, 0), 4, 60),        # 每顆一個;位寬下限
]


class LayerModel:
    """一層的參數跟訓練端的函式:官方整層 forward、逐筆迴圈。"""

    def __init__(self, training: dict, params: ParamSet, q: np.ndarray, decay_table: np.ndarray,
                 thresholds: np.ndarray | None):
        """thresholds: (n_out,) 每顆神經元的整數門檻(整層一個時每顆相同);None 時這層不 fire。"""
        if bool(params.spike_output) != (thresholds is not None):
            raise RuntimeError("SPIKE_OUTPUT 跟有沒有門檻不一致")
        self.training = training
        self.params = params
        self.q = np.asarray(q, dtype=np.int64)
        self.decay_table = np.asarray(decay_table, dtype=np.int64)
        self.thresholds = None if thresholds is None else np.asarray(thresholds, dtype=np.int64)
        self.round_mode = "round" if params.round_enabled else "truncate"
        self.overflow_mode = "saturate" if params.saturate_enabled else "wrap"
        if self.q.shape != (params.out_neurons, params.in_neurons):
            raise RuntimeError(f"q 的形狀 {self.q.shape} 跟參數組不同")
        if self.thresholds is not None and self.thresholds.shape != (params.out_neurons,):
            raise RuntimeError(f"門檻的形狀 {self.thresholds.shape} 跟參數組不同")

        jax, jnp = training["jax"], training["jnp"]
        decay_table_int = jnp.asarray(self.decay_table, dtype=jnp.int32)
        self.threshold_codes = None if self.thresholds is None else jnp.asarray(self.thresholds, dtype=jnp.int32)

        def update(v0, delta_t, q_code, threshold):
            a_int, is_identity = training["apply_decay_table_int"](delta_t, decay_table_int)
            result = training["process_event"](v0, a_int, is_identity, q_code, threshold,
                                               f_a=params.decay_frac_width, f_V=params.membrane_frac_width,
                                               i_V=params.membrane_int_width, round_mode=self.round_mode,
                                               overflow_mode=self.overflow_mode)
            return result.v_final, result.is_spiked, result.overflowed

        self.update = jax.jit(update)

    def quantized_params(self):
        jnp = self.training["jnp"]
        p = self.params
        return self.training["QuantizedLayerParams"](
            q=jnp.asarray(self.q, dtype=jnp.int32), decay_table_int=jnp.asarray(self.decay_table, dtype=jnp.int32),
            v_th_int=self.threshold_codes, scale=jnp.ones(p.out_neurons, dtype=jnp.float32),
            f_a=p.decay_frac_width, f_V=p.membrane_frac_width, i_V=p.membrane_int_width,
            overflow_mode=self.overflow_mode, round_mode=self.round_mode)

    def official_forward(self, layer, in_stream):
        """訓練端整層 forward,帶逐步軌跡(每筆事件之後的 V̂)。回傳 LayerOutput。"""
        backend = self.training["QuantBackend"]()   # 捨入、溢位規則照 quantized_params
        return fitted_forward(layer, self.quantized_params(), in_stream, backend, trace=True)

    def run_events(self, events: np.ndarray) -> dict:
        """逐筆迴圈。events: (n, 2) 的 (src, t)。回傳輸出事件、每 (事件, 列) 的 k、拍數、每筆事件之後的 V̂、最後的 V̂。"""
        p = self.params
        membrane = np.zeros(p.out_neurons, dtype=np.int32)
        last_time = 0   # t_last 整層一份,基準是樣本開始
        overflow_count = 0   # 寫回前的真實值超出暫存器範圍的 (事件, 神經元) 數
        outputs = []
        updates = np.zeros((len(events), p.out_neurons), dtype=np.int64)   # 每筆事件之後的 V̂
        fire_counts = np.zeros((len(events), p.row_count), dtype=np.int64)
        for event_index, (src, t) in enumerate(events):
            if t < last_time:
                raise RuntimeError(f"事件 {event_index} 的時間比 t_last 早")
            delta_t = np.full(p.out_neurons, t - last_time, dtype=np.int32)
            v_final, is_spiked, overflowed = self.update(membrane, delta_t, self.q[:, src].astype(np.int32),
                                                         self.threshold_codes)
            membrane = np.asarray(v_final)
            updates[event_index] = membrane
            last_time = int(t)
            overflow_count += int(np.sum(np.asarray(overflowed)))
            # 同一筆事件照神經元編號由小到大送(FC.md 第 4 節 ②)
            for neuron in np.flatnonzero(np.asarray(is_spiked)):
                outputs.append((int(neuron), int(t)))
                fire_counts[event_index, neuron // p.neurons_per_row] += 1
        cycle_counts = [cycle_count(fire_counts, read_latency, compute_latency, overlap)
                        for read_latency, compute_latency, overlap in CYCLE_CONFIGS]
        return {"outputs": outputs, "fire_counts": fire_counts, "cycle_counts": cycle_counts, "updates": updates,
                "membrane": membrane, "last_time": last_time, "overflow_count": overflow_count}

    def catch_up(self, membrane: np.ndarray, last_time: int, end_time: int) -> np.ndarray:
        """官方 v_final 的最後一步:每顆神經元衰減到 end_time,權重 0。"""
        delta_t = np.full(self.params.out_neurons, end_time - last_time, dtype=np.int32)
        v_final, is_spiked, _ = self.update(membrane.astype(np.int32), delta_t,
                                            np.zeros_like(membrane, dtype=np.int32), self.threshold_codes)
        if np.any(np.asarray(is_spiked)):
            raise RuntimeError("catch-up 時 fire 了,逐筆迴圈的輸出會少這幾個")
        return np.asarray(v_final)


def fitted_forward(layer, params, in_stream, backend, trace=False):
    """layer.forward;容量不夠就放大到 diag.needed 再跑一次。"""
    output = layer.forward(params, in_stream, backend=backend, trace=trace)
    if not bool(layer.capacity.fits(output.diag)):
        needed = output.diag.needed
        layer = layer.with_capacity(layer.capacity.replace(
            **{knob: max(layer.capacity[knob], int(needed[knob])) for knob in layer.capacity}))
        output = layer.forward(params, in_stream, backend=backend, trace=trace)
        if not bool(layer.capacity.fits(output.diag)):
            raise RuntimeError(f"{layer.name} 放大容量之後還是放不下")
    return output


def check_against_official(model: LayerModel, events: np.ndarray, loop_result: dict, output) -> None:
    """逐筆迴圈跟官方整層 forward 比:輸出事件序列、每筆事件之後的 V̂、catch-up 之後的 V̂。不一致就 raise。"""
    n_out = int(output.stream.n_real_events)
    official_idx = np.asarray(output.stream.event_source_idx)[:n_out]
    official_time = np.asarray(output.stream.event_times)[:n_out]
    loop_idx = np.array([neuron for neuron, _ in loop_result["outputs"]], dtype=np.int64)
    loop_time = np.array([t for _, t in loop_result["outputs"]], dtype=np.float64)
    if len(loop_idx) != n_out or not np.array_equal(loop_idx, official_idx) or \
            not np.array_equal(loop_time, official_time):
        raise RuntimeError(f"輸出事件序列不一致:逐筆迴圈 {len(loop_idx)} 筆,官方 {n_out} 筆")
    official_updates = np.asarray(output.trace.v_steps)[:, :len(events)].T   # (事件, 神經元)
    if official_updates.shape != loop_result["updates"].shape:
        raise RuntimeError(f"每筆事件之後的 V̂:官方 trace.v_steps 取出 {official_updates.shape},"
                           f"逐筆迴圈 {loop_result['updates'].shape}")
    if not np.array_equal(official_updates, loop_result["updates"]):
        bad = np.argwhere(official_updates != loop_result["updates"])
        raise RuntimeError(f"每筆事件之後的 V̂ 有 {len(bad)} 個跟官方 trace.v_steps 不同,"
                           f"例如 (事件, 神經元) {[tuple(int(x) for x in pair) for pair in bad[:5]]}")
    end_time = int(events[-1, 1]) if len(events) else 0   # 沒有輸入事件時 V̂ 全 0,衰減到哪裡都一樣
    caught_up = model.catch_up(loop_result["membrane"], loop_result["last_time"], end_time)
    official_v = np.asarray(output.result.v_final)
    if not np.array_equal(caught_up, official_v):
        bad = np.flatnonzero(caught_up != official_v)
        raise RuntimeError(f"catch-up 之後的 V̂ 有 {bad.size} 顆跟官方不同,例如神經元 {bad[:5].tolist()}")


def sample_lines(params: ParamSet, events: np.ndarray, loop_result: dict) -> list[str]:
    cycle_text = " ".join(str(count) for count in loop_result["cycle_counts"])
    lines = [f"sample {len(events)} {len(loop_result['outputs'])} {params.out_neurons} {cycle_text}"]
    lines += [f"in {src} {t}" for src, t in events]
    lines += [f"out {neuron} {t}" for neuron, t in loop_result["outputs"]]
    lines += [f"update {t} " + " ".join(str(membrane) for membrane in update)
              for (_, t), update in zip(events, loop_result["updates"])]
    lines += [f"state {neuron} {membrane}" for neuron, membrane in enumerate(loop_result["membrane"])]
    return lines


def coverage_line(sample_fire_counts: list[np.ndarray]) -> str:
    """跟 fire 分布有關的五個涵蓋項目,這組參數碰不碰得到。sample_fire_counts: 每筆樣本一個 (事件, 列) 的 k。"""
    on_compute_cycle = any(np.any(counts >= 1) for counts in sample_fire_counts)
    more_left = any(np.any(counts >= 2) for counts in sample_fire_counts)
    last_of_row = any(np.any(counts[:, :-1] >= 1) for counts in sample_fire_counts)
    last_of_event_next_queued = any(np.any(counts[:-1, -1] >= 1) for counts in sample_fire_counts)
    last_of_event = any(np.any(counts[:, -1] >= 1) for counts in sample_fire_counts)
    return (f"coverage {int(on_compute_cycle)} {int(more_left)} {int(last_of_row)} "
            f"{int(last_of_event_next_queued)} {int(last_of_event)}")


def check_time_width(params: ParamSet, events: np.ndarray) -> None:
    """時間戳記繞回還沒定,答案只用 2^TIME_WIDTH 以內的時間。"""
    if len(events) and events[:, 1].max() >= (1 << params.time_width):
        raise RuntimeError(f"事件時間 {events[:, 1].max()} 超出 TIME_WIDTH={params.time_width}")


def stream_events(stream) -> np.ndarray:
    """訓練端 EventStream 的真事件 -> (n, 2) 的 (src, t)。"""
    n = int(stream.n_real_events)
    source = np.asarray(stream.event_source_idx)[:n].astype(np.int64)
    times = np.asarray(stream.event_times)[:n]
    if not np.all(times == np.floor(times)):
        raise RuntimeError("事件時間不是整數毫秒")
    return np.stack([source, times.astype(np.int64)], axis=1)


def write_data_files(training: dict, out_dir: Path, params: ParamSet, q: np.ndarray, decay_table: np.ndarray,
                     thresholds: np.ndarray | None) -> None:
    """權重檔、衰減表檔,會 fire 時加門檻檔(整層一個時只有一行,同訓練端 write_fc_layer_mem)。"""
    export = training["fpga_export"]
    export.write_mem(out_dir / f"{params.stem}_weight.mem",
                     export.fc_weight_lines(q, params.weight_width, params.neurons_per_row))
    if thresholds is not None:
        if params.shared_threshold:
            threshold_lines = export.threshold_lines([export.layer_threshold(thresholds, params.out_neurons)],
                                                     params.membrane_width)
        else:
            threshold_lines = export.fc_threshold_lines(thresholds, params.out_neurons, params.membrane_width,
                                                        params.neurons_per_row)
        export.write_mem(out_dir / f"{params.stem}_threshold.mem", threshold_lines)
    export.write_mem(out_dir / f"{params.stem}_decay.mem", export.decay_lines(decay_table, params.decay_frac_width))


def check_exported_files(training: dict, version: str, params: ParamSet, out_dir: Path) -> None:
    """量化資料夾在 sources_1/mem 有匯出的 out 層檔、而且 n_col 相同時,剛寫的權重檔、衰減表檔要跟它相同。"""
    exported_dir = MEM_DIR / version
    if params.neurons_per_row != EXPORTED_FC_COLS or not (exported_dir / f"{TRAINED_LAYER}_weight.mem").exists():
        return
    for suffix in ("weight", "decay"):
        exported_path = exported_dir / f"{TRAINED_LAYER}_{suffix}.mem"
        written_path = out_dir / f"{params.stem}_{suffix}.mem"
        if exported_path.read_text(encoding="ascii").split() != written_path.read_text(encoding="ascii").split():
            raise RuntimeError(f"{written_path.name} 跟匯出的 {exported_path} 不同")
    print(f"{params.stem}:權重檔、衰減表檔跟 sources_1/mem/{version} 匯出的相同")


def build_trained_references(training: dict, training_repo: Path, out_dir: Path) -> None:
    """訓練端 out 層兩版:輸入取 test 評估取樣的前 SAMPLE_COUNT 筆,經訓練端 conv1 → conv2。"""
    for version in dict.fromkeys(version for version, _ in TRAINED_SETS):
        quant_dir = training_repo / QUANT_RUN_DIR / version
        model_file = training["load_quantized"](quant_dir / "model.npz")
        evaluation = training["yaml"].safe_load((quant_dir / "eval" / "test.yaml").read_text(encoding="utf-8"))
        if evaluation["which"] != "test" or evaluation["n_samples"] < SAMPLE_COUNT:
            raise RuntimeError(f"{version} 的 eval/test.yaml 不是 test 的評估,或筆數不夠")
        # 同一個 seed 抽 n 筆等於抽更多筆時的前 n 筆(訓練端 example/quantize.py _build_split),跟評估的前幾筆相同
        split = training["NMNISTDataset"](training["DATASET_ROOT"],
                                          max_events=model_file.metadata["data"]["max_events"]).build_split(
            seed=evaluation["seed"], n_samples=SAMPLE_COUNT, which="test")
        raw = training["split_input_events"](split, model_file.network.input_shape)
        backend = training["QuantBackend"]()   # conv1、conv2 的捨入、溢位規則照 model.npz 每層的參數

        layers = model_file.network.layers
        layer_names = [layer.name for layer in layers]
        if layer_names[-1] != TRAINED_LAYER:
            raise RuntimeError(f"{version} 的最後一層是 {layer_names[-1]},不是 {TRAINED_LAYER}")
        fc_layer = layers[-1]
        fc_params = model_file.params[-1]
        if fc_params.v_th_int is not None:
            raise RuntimeError(f"{version} 的 {TRAINED_LAYER} 層會 fire,參數組寫的是不 fire")
        q = np.asarray(fc_params.q)
        decay_table = np.asarray(fc_params.decay_table_int)

        version_sets = [params for v, params in TRAINED_SETS if v == version]
        models = []
        for params in version_sets:
            if (fc_layer.n_in, fc_layer.n_out) != (params.in_neurons, params.out_neurons):
                raise RuntimeError(f"{version} {TRAINED_LAYER} 的 n_in、n_out 跟參數組不同")
            if (fc_params.i_V, fc_params.f_V, fc_params.f_a) != (
                    params.membrane_int_width, params.membrane_frac_width, params.decay_frac_width):
                raise RuntimeError(f"{version} {TRAINED_LAYER} 的 i_V、f_V、f_a 跟參數組不同")
            if fc_params.overflow_mode.value != ("saturate" if params.saturate_enabled else "wrap"):
                raise RuntimeError(f"{version} {TRAINED_LAYER} 的溢位處理跟參數組不同")
            if fc_params.round_mode.value != ("round" if params.round_enabled else "truncate"):
                raise RuntimeError(f"{version} {TRAINED_LAYER} 的捨入規則跟參數組不同")
            if decay_table.shape[0] != params.decay_table_depth:
                raise RuntimeError(f"{version} {TRAINED_LAYER} 的衰減表深度跟參數組不同")
            write_data_files(training, out_dir, params, q, decay_table, None)
            check_exported_files(training, version, params, out_dir)
            models.append(LayerModel(training, params, q, decay_table, None))

        all_lines = [[] for _ in version_sets]
        all_overflow_counts = [0 for _ in version_sets]
        for sample_index in range(SAMPLE_COUNT):
            stream = model_file.network.input_stream(training["take_input_events"](raw, sample_index))
            for layer, layer_params in zip(layers[:-1], model_file.params[:-1]):
                stream = fitted_forward(layer, layer_params, stream, backend).stream
            events = stream_events(stream)
            for set_index, (model, lines) in enumerate(zip(models, all_lines)):
                check_time_width(model.params, events)
                output = model.official_forward(fc_layer, stream)
                loop_result = model.run_events(events)
                check_against_official(model, events, loop_result, output)
                lines += sample_lines(model.params, events, loop_result)
                all_overflow_counts[set_index] += loop_result["overflow_count"]
            print(f"{version} 第 {sample_index} 筆:FC 輸入 {len(events)} 筆事件")
        for params, lines, overflow_count in zip(version_sets, all_lines, all_overflow_counts):
            write_reference(out_dir / f"{params.stem}.txt", lines + [f"end {SAMPLE_COUNT}"], SAMPLE_COUNT,
                            overflow_count, [])


def synthetic_events(rng: np.random.Generator, params: ParamSet, event_count: int) -> np.ndarray:
    """隨機事件:第一筆 t = 0;同一個時間戳記、Δt 在表內、超過表深度都有;時間不超出 TIME_WIDTH。"""
    gaps = np.where(rng.random(event_count) < 0.3, 0,
                    np.where(rng.random(event_count) < 0.8,
                             rng.integers(1, params.decay_table_depth + 1, size=event_count),
                             rng.integers(params.decay_table_depth + 1, 2 * params.decay_table_depth + 2,
                                          size=event_count)))
    gaps[0] = 0
    times = np.cumsum(gaps)
    if times[-1] >= (1 << params.time_width):
        raise RuntimeError(f"人工事件時間 {times[-1]} 超出 TIME_WIDTH={params.time_width},參數組要改")
    return np.stack([rng.integers(0, params.in_neurons, size=event_count), times], axis=1)


def synthetic_parameters(rng: np.random.Generator, params: ParamSet
                         ) -> tuple[np.ndarray, np.ndarray, np.ndarray | None]:
    """隨機權重(偏正,讓膜電位往上爬、碰到暫存器範圍,測溢位處理)、衰減表;會 fire 時加門檻(不 fire 時 None)。
    亂數照權重、衰減表、門檻的順序抽,不 fire 的參數組抽到的權重、衰減表跟加門檻之前相同。"""
    weight_low, weight_high = signed_range(params.weight_width)
    q = rng.integers(weight_low // 2, weight_high + 1, size=(params.out_neurons, params.in_neurons))
    code_max = (1 << params.decay_frac_width) - 1
    decay_table = rng.integers(0, code_max + 1, size=params.decay_table_depth)
    decay_table[0] = code_max
    decay_table[-1] = rng.integers(1, code_max + 1)   # 最後一格不是 0,查表跟超過表深度的 A=0 才分得出來
    if not params.spike_output:
        return q, decay_table, None

    # 門檻:大多壓低(常常同一列多個 fire),也留高的(膜電位會碰到暫存器範圍,測溢位處理)
    membrane_low, membrane_high = signed_range(params.membrane_width)
    weight_step = 1 << params.membrane_frac_width
    low_thresholds = rng.integers(1, weight_high * weight_step + 1, size=params.out_neurons)
    high_thresholds = rng.integers(membrane_high // 2, membrane_high + 1, size=params.out_neurons)
    thresholds = np.where(rng.random(params.out_neurons) < 0.7, low_thresholds, high_thresholds)
    # 最後一列權重取絕對值、用低門檻,一定會 fire:換事件那一拍(送最後一個 fire)被 out_ready 擋住的情況才碰得到
    last_row = slice((params.row_count - 1) * params.neurons_per_row, params.out_neurons)
    q[last_row] = np.abs(q[last_row])
    thresholds[last_row] = low_thresholds[last_row]
    # n_row = 1 時唯一的列就是最後一列:每筆都 fire 歸零的話膜電位永遠是 0,連續兩筆事件讀寫同一列時
    # 讀到舊值也看不出來(FC.md 第 5 節 ⑧ 的反向測試抓不到)。改成權重至少 1、門檻比單筆權重的上限高,
    # 累積幾筆事件才 fire,膜電位帶著非 0 的值跨事件(同 gen_salt_conv_ref.py 的 OC = 1)。
    if params.row_count == 1:
        q = np.maximum(q, 1)
        thresholds = np.minimum(weight_high * weight_step + low_thresholds, membrane_high)
    # 整層一個門檻:全部用最後一顆的(低門檻,常常多個 fire)
    if params.shared_threshold:
        thresholds = np.full(params.out_neurons, thresholds[-1])
    if not (membrane_low <= thresholds.min() and thresholds.max() <= membrane_high):
        raise RuntimeError("門檻超出暫存器範圍")
    return q, decay_table, thresholds


def build_synthetic_references(training: dict, out_dir: Path) -> None:
    rng = np.random.default_rng(SEED)
    for params, sample_count, event_count in SYNTHETIC_SETS:
        q, decay_table, thresholds = synthetic_parameters(rng, params)
        write_data_files(training, out_dir, params, q, decay_table, thresholds)
        model = LayerModel(training, params, q, decay_table, thresholds)
        layer = training["FCLayer"](name="fc", n_in=params.in_neurons, n_out=params.out_neurons, init_k=1.0,
                                    max_out_spikes=1, max_extra_steps=0)
        network = training["Network"](input_shape=(params.in_neurons,), layers=(layer,))

        lines = []
        overflow_count = 0
        fire_counts = []
        for _ in range(sample_count):
            events = synthetic_events(rng, params, event_count)
            check_time_width(params, events)
            raw = training["InputEvents"].checked(events[:, 1], events[:, 0], event_count)
            stream = network.input_stream(raw)
            output = model.official_forward(layer, stream)
            loop_result = model.run_events(events)
            check_against_official(model, events, loop_result, output)
            lines += sample_lines(params, events, loop_result)
            overflow_count += loop_result["overflow_count"]
            fire_counts.append(loop_result["fire_counts"])
        if params.spike_output:
            lines = [coverage_line(fire_counts)] + lines
        write_reference(out_dir / f"{params.stem}.txt", lines + [f"end {sample_count}"], sample_count,
                        overflow_count, fire_counts if params.spike_output else [])


def write_reference(path: Path, lines: list[str], sample_count: int, overflow_count: int,
                    fire_counts: list[np.ndarray]) -> None:
    """fire_counts: 會 fire 的層每筆樣本一個 (事件, 列) 的 k,印 fire 分布;不 fire 的層給空的。"""
    write_lines(path, lines)
    in_count = sum(line.startswith("in ") for line in lines)
    text = f"{path.name}: 樣本 {sample_count} 筆, 輸入事件 {in_count} 筆, 碰到暫存器範圍 {overflow_count} 次"
    if fire_counts:
        all_counts = np.concatenate(fire_counts)
        text += (f", {lines[0]}, fire {int(all_counts.sum())} 個, "
                 f"同一個 (事件, 列) 最多 {int(all_counts.max())} 個")
    print(text)


def load_training(training_repo: Path) -> dict:
    # 運算量不大,固定用 CPU,不去佔 GPU 記憶體(GPU 可能正在跑訓練)
    import jax
    import yaml
    jax.config.update("jax_platforms", "cpu")
    import jax.numpy as jnp

    sys.path.insert(0, str(training_repo.resolve()))
    import salt_core.fpga_export as fpga_export
    from data.src.nmnist import NMNISTDataset
    from example.paths import DATASET_ROOT
    from example.utils import split_input_events, take_input_events
    from salt_core.io import load_quantized
    from salt_core.layers.fc import FCLayer
    from salt_core.network import InputEvents, Network
    from salt_core.quant.backend import QuantBackend
    from salt_core.quant.codes import apply_decay_table_int
    from salt_core.quant.params import QuantizedLayerParams
    from salt_core.quant.scan import process_event

    return {"jax": jax, "jnp": jnp, "yaml": yaml, "fpga_export": fpga_export,
            "NMNISTDataset": NMNISTDataset, "DATASET_ROOT": DATASET_ROOT, "split_input_events": split_input_events,
            "take_input_events": take_input_events, "load_quantized": load_quantized, "FCLayer": FCLayer,
            "InputEvents": InputEvents, "Network": Network, "QuantBackend": QuantBackend,
            "apply_decay_table_int": apply_decay_table_int, "QuantizedLayerParams": QuantizedLayerParams,
            "process_event": process_event}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--training-repo", required=True, type=Path, help="Spiking-Affine-Lazy-Training 的根目錄")
    parser.add_argument("--out-dir", required=True, type=Path, help="參考答案、資料檔輸出目錄")
    args = parser.parse_args()

    training = load_training(args.training_repo)
    args.out_dir.mkdir(parents=True, exist_ok=True)
    build_trained_references(training, args.training_repo, args.out_dir)
    build_synthetic_references(training, args.out_dir)


if __name__ == "__main__":
    main()
