"""答案腳本用哪個量化模型:讀 quant_versions.txt(跟 run_tb_*.tcl、synth_*.tcl 讀同一個檔),換權重只改那個檔。

QUANT_RUN_DIR:量化資料夾的上一層,相對於訓練端 repo 根目錄。
WRAP_VERSION、SATURATE_VERSION:繞回版、飽和版的量化資料夾名稱;匯出的 .mem 在 SaltNET.srcs/sources_1/mem/<名稱>/。
"""
from pathlib import Path

CONFIG_PATH = Path(__file__).resolve().parent / "quant_versions.txt"
_KEYS = ("quant_run_dir", "wrap", "saturate")


def _read_config() -> dict[str, str]:
    """一行一組「名稱 值」,# 之後是註解。少了、重複、多出名稱,或一行不是兩個欄位時 raise ValueError。"""
    entries = {}
    for line_number, line in enumerate(CONFIG_PATH.read_text(encoding="ascii").splitlines(), start=1):
        fields = line.split("#", 1)[0].split()
        if not fields:
            continue
        if len(fields) != 2 or fields[0] not in _KEYS or fields[0] in entries:
            raise ValueError(f"{CONFIG_PATH} 第 {line_number} 行不對:{line!r}")
        entries[fields[0]] = fields[1]
    missing = [key for key in _KEYS if key not in entries]
    if missing:
        raise ValueError(f"{CONFIG_PATH} 少了 {missing}")
    return entries


_CONFIG = _read_config()
QUANT_RUN_DIR = Path(_CONFIG["quant_run_dir"])
WRAP_VERSION = _CONFIG["wrap"]
SATURATE_VERSION = _CONFIG["saturate"]
