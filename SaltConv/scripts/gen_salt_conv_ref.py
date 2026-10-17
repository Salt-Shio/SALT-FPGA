"""產生 tb_salt_conv_*.sv(四支,清單見 run_tb_salt_conv.tcl)共用的參考答案,人工參數組另外產生權重檔、門檻檔、衰減表檔。

整層 SaltConv 的答案:每筆樣本餵進一串輸入事件,比對輸出事件的順序、樣本結束時每顆神經元的 (V̂, t_last)、
out_ready 一直是 1 時的拍數。

答案有兩份,互相比對,一致才寫答案檔:
- 官方:訓練端 ConvLayer.forward + QuantBackend(整層的整數掃描,輸出事件流照 salt_core/stream.py 排序)。
  佇列容量不夠時結果會被截斷,這時把容量放大到 diag.needed 再跑一次。
- 逐筆迴圈:照硬體的做法一筆事件一筆事件、一個 o_c 一個 o_c 算,候選用訓練端 _axis_candidates,
  更新用訓練端 apply_decay_table_int + process_event。官方答案沒有的三樣東西從這裡來:
    每顆神經元的 t_last、每筆事件每個 o_c fire 的個數 k(算拍數)、做完最後一筆事件時的 V̂。
  官方的 v_final 多做了一步 catch-up:每顆神經元再衰減到樣本最後一筆事件的時間(權重 0)。
  逐筆迴圈補上同一步之後要等於官方的 v_final,輸出事件序列也要完全相同。
硬體不做 catch-up,所以 testbench 比的是 catch-up 之前的 V̂。

拍數(Conv.md 5.3、5.3「OC=1」):out_ready 一直是 1、輸入一直有時,從第一個 o_c 算的那一拍到最後一個 o_c
送完那一拍共 Σ_事件 Σ_o_c max(1, k) 拍;OC = 1 時算的那一拍一律不算送完,是 Σ_事件 max(2, k) 拍。

參數組分兩種:
- 訓練端的 conv1、conv2,繞回版、飽和版各一份,輸入是 test 的前 SAMPLE_COUNT 筆(量化資料夾 eval/test.yaml
  記的評估取樣,跟 eval/test_outputs.npz 的前幾筆相同);conv2 的輸入是訓練端 conv1 的輸出。
  權重檔、門檻檔、衰減表檔用 SaltConv.srcs/sources_1/mem/<量化資料夾>/ 匯出的,這裡會確認內容跟 model.npz 相同。
  每層 spike 數跟 eval/test_outputs.npz 的 spike_count 比對(那一筆沒被截斷時)。
- 人工參數組:隨機權重、門檻、衰減表、事件,門檻壓低讓同一個 o_c 常有多個 fire;
  三個資料檔用訓練端 salt_core.fpga_export 的函式寫,跟答案放在同一個目錄。

答案檔一行一筆,第一個欄位是種類,欄位以空白分隔,全部十進位,有號數直接寫負號:
    coverage <stall_on_compute_cycle> <stall_with_more_left> <stall_last_of_oc> <stall_last_of_event_next_queued> <stall_last_of_event>
        testbench 的涵蓋項目裡,跟 fire 分布有關的五項這組參數碰不碰得到(1:要求至少發生一次):
          stall_on_compute_cycle:有 (事件, o_c) fire 1 個以上(算的那一拍就有東西送)
          stall_with_more_left:有 (事件, o_c) fire 2 個以上
          stall_last_of_oc:有 o_c < OC-1 的 (事件, o_c) fire 1 個以上
          stall_last_of_event_next_queued:不是樣本最後一筆的事件,在 o_c = OC-1 fire 1 個以上
          stall_last_of_event:有事件在 o_c = OC-1 fire 1 個以上
    sample <in_count> <out_count> <cycle_count> <state_count>
    in <x> <y> <c> <t>                                        × in_count,照輸入順序
    out <o_c> <o_y> <o_x> <t>                                 × out_count,照送出順序
    state <row_bank> <col_bank> <bank_addr> <membrane> <last_time>   × state_count,每顆神經元一行
    end <sample_count>
bank、bank 內位址照 Conv.md 第 2 節:bank (o_y mod M, o_x mod M),位址 (o_c·G_y + ⌊o_y/M⌋)·G_x + ⌊o_x/M⌋。

用法(WSL,conda 環境 jax,在 scripts 目錄執行):
    python gen_salt_conv_ref.py \
        --training-repo /mnt/d/Project/Spiking-Affine-Lazy-Training \
        --mem-dir /mnt/d/Project/SALT-FPGA/SaltConv/SaltConv.srcs/sources_1/mem \
        --out-dir /mnt/d/Project/SALT-FPGA/SaltConv/SaltConv.srcs/sim_1/new/ref
"""
import argparse
import dataclasses
import sys
from pathlib import Path

import numpy as np

QUANT_RUN_DIR = Path("experiments/scale_10k_20260919_050446/quant")
WRAP_VERSION = "best_val50_b7_fa6_fv0_round_pc_clip100_wrap_g1"
SATURATE_VERSION = "best_val50_b7_fa6_fv0_round_pc_clip100_saturate_iv9-11-11"
SAMPLE_COUNT = 10
TRAINED_TIME_WIDTH = 16
TRAINED_WEIGHT_WIDTH = 7
SEED = 0


@dataclasses.dataclass(frozen=True)
class ParamSet:
    """一組 SaltConv 參數。整數欄位跟 run_tb_salt_conv.tcl 的清單、tb_salt_conv_common.svh 的 parameter 一致。"""
    kernel_size: int
    stride: int
    padding: int
    in_rows: int
    in_cols: int
    in_channels: int
    out_channels: int
    time_width: int
    weight_width: int
    membrane_int_width: int
    membrane_frac_width: int
    decay_frac_width: int
    decay_table_depth: int
    round_enabled: int
    saturate_enabled: int

    @property
    def out_rows(self) -> int:
        return (self.in_rows + 2 * self.padding - self.kernel_size) // self.stride + 1

    @property
    def out_cols(self) -> int:
        return (self.in_cols + 2 * self.padding - self.kernel_size) // self.stride + 1

    @property
    def bank_count(self) -> int:
        return (self.kernel_size + self.stride - 1) // self.stride

    @property
    def membrane_width(self) -> int:
        return self.membrane_int_width + self.membrane_frac_width

    @property
    def stem(self) -> str:
        """答案檔、人工資料檔共用的檔名主體,testbench 用同一套規則組出檔名。"""
        return (f"salt_conv_K{self.kernel_size}_S{self.stride}_P{self.padding}_R{self.out_rows}_C{self.out_cols}"
                f"_IC{self.in_channels}_OC{self.out_channels}_IV{self.membrane_int_width}"
                f"_FV{self.membrane_frac_width}_RD{self.round_enabled}_SAT{self.saturate_enabled}")


# (量化資料夾, 層名, 參數)
TRAINED_SETS = [
    (WRAP_VERSION, "conv1", ParamSet(3, 2, 1, 34, 34, 2, 8, 16, 7, 12, 0, 6, 75, 1, 0)),
    (SATURATE_VERSION, "conv1", ParamSet(3, 2, 1, 34, 34, 2, 8, 16, 7, 9, 0, 6, 75, 1, 1)),
    (WRAP_VERSION, "conv2", ParamSet(3, 2, 1, 17, 17, 8, 16, 16, 7, 14, 0, 6, 75, 1, 0)),
    (SATURATE_VERSION, "conv2", ParamSet(3, 2, 1, 17, 17, 8, 16, 16, 7, 11, 0, 6, 75, 1, 1)),
]

# (參數, 樣本數, 每筆樣本的事件數)
SYNTHETIC_SETS = [
    (ParamSet(1, 2, 0, 8, 6, 2, 3, 9, 4, 5, 0, 3, 4, 0, 1), 4, 120),       # S>K,M=1;truncate、飽和
    (ParamSet(3, 1, 1, 13, 11, 3, 5, 11, 5, 7, 0, 4, 10, 1, 0), 3, 150),   # M=3,C、OC 不是 2 的次方;round、繞回
    (ParamSet(5, 2, 2, 20, 14, 2, 3, 12, 6, 6, 2, 5, 20, 0, 0), 3, 150),   # M=3、S>1,f_V=2;truncate、繞回
    (ParamSet(4, 1, 0, 10, 8, 1, 4, 10, 4, 6, 0, 4, 8, 1, 1), 3, 150),     # M=4;round、飽和
    (ParamSet(3, 1, 1, 1, 1, 2, 1, 8, 4, 5, 0, 3, 3, 1, 1), 4, 60),        # 輸出 1x1、OC=1
]


def signed_range(width: int) -> tuple[int, int]:
    return -(1 << (width - 1)), (1 << (width - 1)) - 1


def write_lines(path: Path, lines: list[str]) -> None:
    path.write_text("".join(f"{line}\n" for line in lines), encoding="ascii")


class LayerModel:
    """一層的參數跟訓練端的函式:官方整層 forward、逐筆迴圈。"""

    def __init__(self, training: dict, params: ParamSet, q: np.ndarray, thresholds: np.ndarray,
                 decay_table: np.ndarray):
        self.training = training
        self.params = params
        self.q = np.asarray(q, dtype=np.int64)
        self.thresholds = np.asarray(thresholds, dtype=np.int64)
        self.decay_table = np.asarray(decay_table, dtype=np.int64)
        self.round_mode = "round" if params.round_enabled else "truncate"
        self.overflow_mode = "saturate" if params.saturate_enabled else "wrap"

        jax, jnp = training["jax"], training["jnp"]
        decay_table_int = jnp.asarray(self.decay_table, dtype=jnp.int32)

        def update(v0, delta_t, q_code, threshold):
            a_int, is_identity = training["apply_decay_table_int"](delta_t, decay_table_int)
            result = training["process_event"](v0, a_int, is_identity, q_code, threshold,
                                               f_a=params.decay_frac_width, f_V=params.membrane_frac_width,
                                               i_V=params.membrane_int_width, round_mode=self.round_mode,
                                               overflow_mode=self.overflow_mode)
            return result.v_final, result.is_spiked

        self.update = jax.jit(update)

    def layer(self, max_queue_len: int, max_out_spikes: int):
        p = self.params
        return self.training["ConvLayer"](name="conv", ic=p.in_channels, h_in=p.in_rows, w_in=p.in_cols,
                                          oc=p.out_channels, k=p.kernel_size, s=p.stride, p=p.padding,
                                          init_k=1.0, max_queue_len=max_queue_len, max_out_spikes=max_out_spikes)

    def quantized_params(self):
        jnp = self.training["jnp"]
        p = self.params
        n_neurons = p.out_channels * p.out_rows * p.out_cols
        v_th = np.repeat(self.thresholds, p.out_rows * p.out_cols)
        return self.training["QuantizedLayerParams"](
            q=jnp.asarray(self.q, dtype=jnp.int32), decay_table_int=jnp.asarray(self.decay_table, dtype=jnp.int32),
            v_th_int=jnp.asarray(v_th, dtype=jnp.int32), scale=jnp.ones(n_neurons, dtype=jnp.float32),
            f_a=p.decay_frac_width, f_V=p.membrane_frac_width, i_V=p.membrane_int_width,
            overflow_mode=self.overflow_mode)

    def official_forward(self, in_stream, max_queue_len: int, max_out_spikes: int):
        """訓練端整層 forward;容量不夠就放大到 diag.needed 再跑。回傳 LayerOutput。"""
        backend = self.training["QuantBackend"](round_mode=self.round_mode)
        layer = self.layer(max_queue_len, max_out_spikes)
        output = layer.forward(self.quantized_params(), in_stream, backend=backend)
        if not bool(layer.capacity.fits(output.diag)):
            needed = output.diag.needed
            layer = self.layer(max(max_queue_len, int(needed["max_queue_len"])),
                               max(max_out_spikes, int(needed["max_out_spikes"])))
            output = layer.forward(self.quantized_params(), in_stream, backend=backend)
            if not bool(layer.capacity.fits(output.diag)):
                raise RuntimeError("放大容量之後還是放不下")
        return output

    def run_events(self, events: np.ndarray) -> dict:
        """逐筆迴圈。events: (n, 4) 的 (x, y, c, t)。回傳輸出事件、每 (事件, o_c) 的 k、拍數、最後的 V̂、t_last。"""
        p = self.params
        jnp = self.training["jnp"]
        bank_count = p.bank_count
        candidate_count = (p.kernel_size - 1) // p.stride + 1   # 訓練端的寫法,跟 ceil(K/S) 相同
        if candidate_count != bank_count:
            raise RuntimeError(f"候選數 {candidate_count} 跟 bank 數 {bank_count} 不一致")
        axis_candidates = self.training["_axis_candidates"]
        out_y, valid_y, tap_y = (np.asarray(a) for a in axis_candidates(
            jnp.asarray(events[:, 1], dtype=jnp.int32), p.kernel_size, p.stride, p.padding, candidate_count,
            p.out_rows))
        out_x, valid_x, tap_x = (np.asarray(a) for a in axis_candidates(
            jnp.asarray(events[:, 0], dtype=jnp.int32), p.kernel_size, p.stride, p.padding, candidate_count,
            p.out_cols))

        membrane = np.zeros((p.out_channels, p.out_rows, p.out_cols), dtype=np.int64)
        last_time = np.zeros_like(membrane)
        # 固定長度送進 jit,不用每種候選數各編譯一次;多出來的位置 Δt=0、q=0,結果不用
        slot_count = p.out_channels * bank_count * bank_count
        outputs = []
        fire_counts = np.zeros((len(events), p.out_channels), dtype=np.int64)
        for event_index, (x, y, c, t) in enumerate(events):
            # 兩軸都合法才是候選;候選照 (o_y, o_x) 由小到大排(_axis_candidates 的 o 隨 index 遞增)
            spatial = [(int(out_y[event_index, i]), int(tap_y[event_index, i]),
                        int(out_x[event_index, j]), int(tap_x[event_index, j]))
                       for i in range(candidate_count) if valid_y[event_index, i]
                       for j in range(candidate_count) if valid_x[event_index, j]]
            if not spatial:
                continue
            oc_index = np.repeat(np.arange(p.out_channels), len(spatial))
            oy_index = np.tile([s[0] for s in spatial], p.out_channels)
            ky_index = np.tile([s[1] for s in spatial], p.out_channels)
            ox_index = np.tile([s[2] for s in spatial], p.out_channels)
            kx_index = np.tile([s[3] for s in spatial], p.out_channels)
            used = len(oc_index)

            v0 = np.zeros(slot_count, dtype=np.int32)
            delta_t = np.zeros(slot_count, dtype=np.int32)
            q_code = np.zeros(slot_count, dtype=np.int32)
            threshold = np.zeros(slot_count, dtype=np.int32)
            v0[:used] = membrane[oc_index, oy_index, ox_index]
            delta_t[:used] = t - last_time[oc_index, oy_index, ox_index]
            q_code[:used] = self.q[oc_index, c, ky_index, kx_index]
            threshold[:used] = self.thresholds[oc_index]
            if np.any(delta_t[:used] < 0):
                raise RuntimeError(f"事件 {event_index} 的時間比 t_last 早")
            v_final, is_spiked = self.update(v0, delta_t, q_code, threshold)
            v_final = np.asarray(v_final)[:used]
            is_spiked = np.asarray(is_spiked)[:used]

            membrane[oc_index, oy_index, ox_index] = v_final
            last_time[oc_index, oy_index, ox_index] = t
            for slot in np.flatnonzero(is_spiked):
                outputs.append((int(oc_index[slot]), int(oy_index[slot]), int(ox_index[slot]), int(t)))
                fire_counts[event_index, oc_index[slot]] += 1

        min_cycles_per_oc = 2 if p.out_channels == 1 else 1
        cycle_count = int(np.sum(np.maximum(min_cycles_per_oc, fire_counts)))
        return {"outputs": outputs, "fire_counts": fire_counts, "cycle_count": cycle_count,
                "membrane": membrane, "last_time": last_time}

    def catch_up(self, membrane: np.ndarray, last_time: np.ndarray, end_time: int) -> np.ndarray:
        """官方 v_final 的最後一步:每顆神經元衰減到 end_time,權重 0。回傳攤平成神經元編號順序的 V̂。"""
        flat_membrane = membrane.reshape(-1).astype(np.int32)
        delta_t = (end_time - last_time.reshape(-1)).astype(np.int32)
        threshold = np.repeat(self.thresholds, self.params.out_rows * self.params.out_cols).astype(np.int32)
        v_final, is_spiked = self.update(flat_membrane, delta_t, np.zeros_like(flat_membrane), threshold)
        if np.any(np.asarray(is_spiked)):
            raise RuntimeError("catch-up 時 fire 了,逐筆迴圈的輸出會少這幾個")
        return np.asarray(v_final)


def check_against_official(model: LayerModel, events: np.ndarray, loop_result: dict, output) -> None:
    """逐筆迴圈跟官方整層 forward 比:輸出事件序列、catch-up 之後的 V̂。不一致就 raise。"""
    p = model.params
    n_out = int(output.stream.n_real_events)
    official_idx = np.asarray(output.stream.event_source_idx)[:n_out]
    official_time = np.asarray(output.stream.event_times)[:n_out]
    hw = p.out_rows * p.out_cols
    loop_idx = np.array([oc * hw + oy * p.out_cols + ox for oc, oy, ox, _ in loop_result["outputs"]], dtype=np.int64)
    loop_time = np.array([t for *_, t in loop_result["outputs"]], dtype=np.float64)
    if len(loop_idx) != n_out or not np.array_equal(loop_idx, official_idx) or \
            not np.array_equal(loop_time, official_time):
        raise RuntimeError(f"輸出事件序列不一致:逐筆迴圈 {len(loop_idx)} 筆,官方 {n_out} 筆")
    end_time = int(events[-1, 3]) if len(events) else 0   # 沒有輸入事件時 V̂ 全 0,衰減到哪裡都一樣
    caught_up = model.catch_up(loop_result["membrane"], loop_result["last_time"], end_time)
    official_v = np.asarray(output.result.v_final)
    if not np.array_equal(caught_up, official_v):
        bad = np.flatnonzero(caught_up != official_v)
        raise RuntimeError(f"catch-up 之後的 V̂ 有 {bad.size} 顆跟官方不同,例如神經元 {bad[:5].tolist()}")


def sample_lines(params: ParamSet, events: np.ndarray, loop_result: dict) -> list[str]:
    bank_count = params.bank_count
    row_slots = -(-params.out_rows // bank_count)
    col_slots = -(-params.out_cols // bank_count)
    state_count = params.out_channels * params.out_rows * params.out_cols
    lines = [f"sample {len(events)} {len(loop_result['outputs'])} {loop_result['cycle_count']} {state_count}"]
    lines += [f"in {x} {y} {c} {t}" for x, y, c, t in events]
    lines += [f"out {oc} {oy} {ox} {t}" for oc, oy, ox, t in loop_result["outputs"]]
    membrane, last_time = loop_result["membrane"], loop_result["last_time"]
    for oc in range(params.out_channels):
        for oy in range(params.out_rows):
            for ox in range(params.out_cols):
                bank_addr = (oc * row_slots + oy // bank_count) * col_slots + ox // bank_count
                lines.append(f"state {oy % bank_count} {ox % bank_count} {bank_addr} "
                             f"{membrane[oc, oy, ox]} {last_time[oc, oy, ox]}")
    return lines


def coverage_line(params: ParamSet, sample_fire_counts: list[np.ndarray]) -> str:
    """跟 fire 分布有關的五個涵蓋項目,這組參數碰不碰得到。"""
    on_compute_cycle = any(np.any(counts >= 1) for counts in sample_fire_counts)
    more_left = any(np.any(counts >= 2) for counts in sample_fire_counts)
    last_of_oc = any(np.any(counts[:, :-1] >= 1) for counts in sample_fire_counts)
    last_of_event_next_queued = any(np.any(counts[:-1, -1] >= 1) for counts in sample_fire_counts)
    last_of_event = any(np.any(counts[:, -1] >= 1) for counts in sample_fire_counts)
    return (f"coverage {int(on_compute_cycle)} {int(more_left)} {int(last_of_oc)} "
            f"{int(last_of_event_next_queued)} {int(last_of_event)}")


def check_time_width(params: ParamSet, events: np.ndarray) -> None:
    """時間戳記繞回還沒定,答案只用 2^TIME_WIDTH 以內的時間。"""
    if len(events) and events[:, 3].max() >= (1 << params.time_width):
        raise RuntimeError(f"事件時間 {events[:, 3].max()} 超出 TIME_WIDTH={params.time_width}")


def stream_events(stream, in_rows: int, in_cols: int) -> np.ndarray:
    """訓練端 EventStream 的真事件 -> (n, 4) 的 (x, y, c, t)。"""
    n = int(stream.n_real_events)
    source = np.asarray(stream.event_source_idx)[:n].astype(np.int64)
    times = np.asarray(stream.event_times)[:n]
    if not np.all(times == np.floor(times)):
        raise RuntimeError("事件時間不是整數毫秒")
    hw = in_rows * in_cols
    return np.stack([source % hw % in_cols, source % hw // in_cols, source // hw, times.astype(np.int64)], axis=1)


def check_mem_file(path: Path, expected_lines: list[str]) -> None:
    actual = path.read_text(encoding="ascii").split()
    if actual != expected_lines:
        raise RuntimeError(f"{path} 的內容跟 model.npz 匯出的不同")


def build_trained_references(training: dict, training_repo: Path, mem_dir: Path, out_dir: Path) -> None:
    """訓練端 conv1、conv2 兩版:輸入取 test 評估取樣的前 SAMPLE_COUNT 筆,conv2 的輸入是訓練端 conv1 的輸出。"""
    for version in (WRAP_VERSION, SATURATE_VERSION):
        quant_dir = training_repo / QUANT_RUN_DIR / version
        model_file = training["load_quantized"](quant_dir / "model.npz")
        evaluation = training["yaml"].safe_load((quant_dir / "eval" / "test.yaml").read_text(encoding="utf-8"))
        if evaluation["which"] != "test" or evaluation["n_samples"] < SAMPLE_COUNT:
            raise RuntimeError(f"{version} 的 eval/test.yaml 不是 test 的評估,或筆數不夠")
        with np.load(quant_dir / "eval" / "test_outputs.npz") as npz:
            reference_spike_count = npz["spike_count"]
            reference_truncated = npz["truncated"]
        # 同一個 seed 抽 n 筆等於抽更多筆時的前 n 筆(訓練端 example/quantize.py _build_split),跟評估的前幾筆相同
        split = training["NMNISTDataset"](training["DATASET_ROOT"],
                                          max_events=model_file.metadata["data"]["max_events"]).build_split(
            seed=evaluation["seed"], n_samples=SAMPLE_COUNT, which="test")
        raw = training["split_input_events"](split, model_file.network.input_shape)
        layer_names = [layer.name for layer in model_file.network.layers]
        if model_file.round_mode.value != "round":
            raise RuntimeError(f"{version} 的捨入規則是 {model_file.round_mode},參數組寫的是 round")

        version_sets = [(layer_name, params) for v, layer_name, params in TRAINED_SETS if v == version]
        layer_models = {}
        for layer_name, params in version_sets:
            layer_index = layer_names.index(layer_name)
            layer = model_file.network.layers[layer_index]
            layer_params = model_file.params[layer_index]
            if (layer.ic, layer.h_in, layer.w_in, layer.oc, layer.k, layer.s, layer.p) != (
                    params.in_channels, params.in_rows, params.in_cols, params.out_channels, params.kernel_size,
                    params.stride, params.padding):
                raise RuntimeError(f"{version} {layer_name} 的幾何跟參數組不同")
            if (layer_params.i_V, layer_params.f_V, layer_params.f_a) != (
                    params.membrane_int_width, params.membrane_frac_width, params.decay_frac_width):
                raise RuntimeError(f"{version} {layer_name} 的 i_V、f_V、f_a 跟參數組不同")
            if layer_params.overflow_mode.value != ("saturate" if params.saturate_enabled else "wrap"):
                raise RuntimeError(f"{version} {layer_name} 的溢位處理跟參數組不同")
            q = np.asarray(layer_params.q)
            decay_table = np.asarray(layer_params.decay_table_int)
            if decay_table.shape[0] != params.decay_table_depth:
                raise RuntimeError(f"{version} {layer_name} 的衰減表深度跟參數組不同")
            thresholds = training["channel_thresholds"](np.asarray(layer_params.v_th_int), layer.oc)
            export = training["fpga_export"]
            check_mem_file(mem_dir / version / f"{layer_name}_weight.mem",
                           export.conv_weight_lines(q, TRAINED_WEIGHT_WIDTH))
            check_mem_file(mem_dir / version / f"{layer_name}_threshold.mem",
                           export.threshold_lines(thresholds, params.membrane_width))
            check_mem_file(mem_dir / version / f"{layer_name}_decay.mem",
                           export.decay_lines(decay_table, params.decay_frac_width))
            layer_models[layer_name] = (layer_index, layer, LayerModel(training, params, q, thresholds, decay_table))

        all_lines = {layer_name: [] for layer_name, _ in version_sets}
        all_fire_counts = {layer_name: [] for layer_name, _ in version_sets}
        for sample_index in range(SAMPLE_COUNT):
            sample_raw = training["take_input_events"](raw, sample_index)
            stream = model_file.network.input_stream(sample_raw)
            for layer_name, params in version_sets:
                layer_index, layer, model = layer_models[layer_name]
                events = stream_events(stream, params.in_rows, params.in_cols)
                check_time_width(params, events)
                output = model.official_forward(stream, layer.max_queue_len, layer.max_out_spikes)
                loop_result = model.run_events(events)
                check_against_official(model, events, loop_result, output)
                if not reference_truncated[sample_index, layer_index] and \
                        len(loop_result["outputs"]) != reference_spike_count[sample_index, layer_index]:
                    raise RuntimeError(f"{version} {layer_name} 第 {sample_index} 筆 spike 數 "
                                       f"{len(loop_result['outputs'])},test_outputs.npz 是 "
                                       f"{reference_spike_count[sample_index, layer_index]}")
                all_lines[layer_name] += sample_lines(params, events, loop_result)
                all_fire_counts[layer_name].append(loop_result["fire_counts"])
                stream = output.stream

        for layer_name, params in version_sets:
            lines = [coverage_line(params, all_fire_counts[layer_name])] + all_lines[layer_name] + \
                    [f"end {SAMPLE_COUNT}"]
            write_reference(out_dir / f"{params.stem}.txt", lines, all_fire_counts[layer_name])


def synthetic_events(rng: np.random.Generator, params: ParamSet, event_count: int) -> np.ndarray:
    """隨機事件:同一個時間戳記、Δt 在表內、超過表深度都有;時間不超出 TIME_WIDTH。"""
    gaps = np.where(rng.random(event_count) < 0.3, 0,
                    np.where(rng.random(event_count) < 0.8,
                             rng.integers(1, params.decay_table_depth + 1, size=event_count),
                             rng.integers(params.decay_table_depth + 1, 2 * params.decay_table_depth + 2,
                                          size=event_count)))
    times = np.cumsum(gaps)
    if times[-1] >= (1 << params.time_width):
        raise RuntimeError(f"人工事件時間 {times[-1]} 超出 TIME_WIDTH={params.time_width},參數組要改")
    return np.stack([rng.integers(0, params.in_cols, size=event_count),
                     rng.integers(0, params.in_rows, size=event_count),
                     rng.integers(0, params.in_channels, size=event_count), times], axis=1)


def synthetic_parameters(rng: np.random.Generator, params: ParamSet) -> tuple[np.ndarray, ...]:
    """隨機權重(偏正,讓膜電位往上爬)、門檻、衰減表。"""
    weight_low, weight_high = signed_range(params.weight_width)
    q = rng.integers(weight_low // 2, weight_high + 1,
                     size=(params.out_channels, params.in_channels, params.kernel_size, params.kernel_size))
    # 門檻:大多壓低(常常同一拍多個 fire),也留高的(膜電位會碰到暫存器範圍,測溢位處理)
    membrane_low, membrane_high = signed_range(params.membrane_width)
    weight_step = 1 << params.membrane_frac_width
    low_thresholds = rng.integers(1, weight_high * weight_step + 1, size=params.out_channels)
    high_thresholds = rng.integers(membrane_high // 2, membrane_high + 1, size=params.out_channels)
    thresholds = np.where(rng.random(params.out_channels) < 0.7, low_thresholds, high_thresholds)
    # 最後一個 o_c 權重取絕對值、用低門檻,一定會 fire:換事件那一拍(送最後一個 fire)被 out_ready 擋住的情況才碰得到
    q[-1] = np.abs(q[-1])
    thresholds[-1] = low_thresholds[-1]
    # OC = 1 時唯一的 o_c 就是最後一個:每筆都 fire 歸零的話膜電位永遠是 0,連續兩筆事件讀寫同一顆神經元時
    # 讀到舊值也看不出來(Conv.md 5.3「OC=1」的反向測試抓不到)。改成權重至少 1、門檻比單筆權重的上限高,
    # 累積幾筆事件才 fire,膜電位帶著非 0 的值跨事件。
    if params.out_channels == 1:
        q[-1] = np.maximum(q[-1], 1)
        thresholds[-1] = min(weight_high * weight_step + low_thresholds[-1], membrane_high)
    code_max = (1 << params.decay_frac_width) - 1
    decay_table = rng.integers(0, code_max + 1, size=params.decay_table_depth)
    decay_table[0] = code_max
    decay_table[-1] = rng.integers(1, code_max + 1)   # 最後一格不是 0,查表跟超過表深度的 A=0 才分得出來
    if not (membrane_low <= thresholds.min() and thresholds.max() <= membrane_high):
        raise RuntimeError("門檻超出暫存器範圍")
    return q, thresholds, decay_table


def build_synthetic_references(training: dict, out_dir: Path) -> None:
    rng = np.random.default_rng(SEED)
    export = training["fpga_export"]
    for params, sample_count, event_count in SYNTHETIC_SETS:
        if params.out_rows < 1 or params.out_cols < 1:
            raise RuntimeError(f"{params.stem} 幾何退化")
        q, thresholds, decay_table = synthetic_parameters(rng, params)
        export.write_mem(out_dir / f"{params.stem}_weight.mem", export.conv_weight_lines(q, params.weight_width))
        export.write_mem(out_dir / f"{params.stem}_threshold.mem",
                         export.threshold_lines(thresholds, params.membrane_width))
        export.write_mem(out_dir / f"{params.stem}_decay.mem",
                         export.decay_lines(decay_table, params.decay_frac_width))
        model = LayerModel(training, params, q, thresholds, decay_table)
        network = training["Network"](input_shape=(params.in_channels, params.in_rows, params.in_cols),
                                      layers=(model.layer(event_count + 1, event_count * params.out_channels
                                                          * params.bank_count ** 2),))

        lines = []
        fire_counts = []
        for _ in range(sample_count):
            events = synthetic_events(rng, params, event_count)
            check_time_width(params, events)
            source_idx = np.ravel_multi_index((events[:, 2], events[:, 1], events[:, 0]),
                                              (params.in_channels, params.in_rows, params.in_cols))
            raw = training["InputEvents"].checked(events[:, 3], source_idx, event_count)
            stream = network.input_stream(raw)
            output = model.official_forward(stream, event_count + 1,
                                            event_count * params.out_channels * params.bank_count ** 2)
            loop_result = model.run_events(events)
            check_against_official(model, events, loop_result, output)
            lines += sample_lines(params, events, loop_result)
            fire_counts.append(loop_result["fire_counts"])
        lines = [coverage_line(params, fire_counts)] + lines + [f"end {sample_count}"]
        write_reference(out_dir / f"{params.stem}.txt", lines, fire_counts)


def write_reference(path: Path, lines: list[str], fire_counts: list[np.ndarray]) -> None:
    write_lines(path, lines)
    all_counts = np.concatenate(fire_counts)
    print(f"{path.name}: {lines[0]}, 樣本 {len(fire_counts)} 筆, 事件 {all_counts.shape[0]} 筆, "
          f"fire {int(all_counts.sum())} 個, 同一個 (事件, o_c) 最多 {int(all_counts.max())} 個")


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
    from salt_core.connectivity.conv import _axis_candidates
    from salt_core.io import load_quantized
    from salt_core.layers.conv import ConvLayer
    from salt_core.network import InputEvents, Network
    from salt_core.quant.backend import QuantBackend
    from salt_core.quant.codes import apply_decay_table_int
    from salt_core.quant.params import QuantizedLayerParams
    from salt_core.quant.scan import process_event

    return {"jax": jax, "jnp": jnp, "yaml": yaml, "fpga_export": fpga_export,
            "channel_thresholds": fpga_export.channel_thresholds,
            "NMNISTDataset": NMNISTDataset, "DATASET_ROOT": DATASET_ROOT, "split_input_events": split_input_events,
            "take_input_events": take_input_events, "_axis_candidates": _axis_candidates,
            "load_quantized": load_quantized, "ConvLayer": ConvLayer, "InputEvents": InputEvents, "Network": Network,
            "QuantBackend": QuantBackend, "apply_decay_table_int": apply_decay_table_int,
            "QuantizedLayerParams": QuantizedLayerParams, "process_event": process_event}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--training-repo", required=True, type=Path, help="Spiking-Affine-Lazy-Training 的根目錄")
    parser.add_argument("--mem-dir", required=True, type=Path, help="SaltConv.srcs/sources_1/mem,訓練端匯出的資料檔")
    parser.add_argument("--out-dir", required=True, type=Path, help="參考答案輸出目錄")
    args = parser.parse_args()

    training = load_training(args.training_repo)
    args.out_dir.mkdir(parents=True, exist_ok=True)
    build_trained_references(training, args.training_repo, args.mem_dir, args.out_dir)
    build_synthetic_references(training, args.out_dir)


if __name__ == "__main__":
    main()
