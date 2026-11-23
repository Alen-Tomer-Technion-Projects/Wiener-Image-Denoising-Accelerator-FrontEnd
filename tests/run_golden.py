"""Golden model regression for wiener_top.

For every configuration below: generate stimulus and expected output with
golden_model.py, compile tb_golden.sv with the RTL, run it, and check the
RESULT line. Run from the repository root:

    python3 tests/run_golden.py

Exit code 0 only if every configuration passes.
"""

import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TESTS = ROOT / "tests"

# (width, height, frames, idle gap between frames, mode_3x3, noise Q16.8, seed)
# Noise values cover low, medium and saturating variance.
CONFIGS = [
    (8, 8, 3, 0, 0, 200 * 256, 1),       # smallest legal image, back to back
    (8, 8, 3, 0, 1, 200 * 256, 2),
    (13, 9, 2, 0, 0, 600 * 256, 3),      # odd sizes
    (13, 9, 2, 0, 1, 50 * 256, 4),
    (16, 12, 2, 37, 0, 900 * 256, 5),    # idle gap between frames
    (16, 12, 2, 37, 1, 900 * 256, 6),
    (32, 24, 2, 0, 0, 20000 * 256, 7),   # very large noise (weight floor)
    (32, 24, 1, 0, 1, 1, 8),             # almost no noise (weight close to 1)
    (64, 48, 1, 0, 0, 680 * 256, 9),
    (10, 8, 3, 1, 0, 300 * 256, 10),     # gaps shorter than the 3 flush shifts,
    (10, 8, 3, 2, 1, 300 * 256, 11),     # so the next frame interrupts the flush
    (10, 8, 3, 3, 0, 300 * 256, 12),
    (10, 8, 3, 5, 1, 300 * 256, 13),
]


def rtl_files():
    # The design file list is written relative to the repository root
    lines = (ROOT / "rtl" / "rtl.f").read_text().split()
    return [str(ROOT / p) for p in lines]


def run(cfg, work):
    w, h, frames, gap, mode, noise, seed = cfg
    case = work / f"w{w}_h{h}_f{frames}_g{gap}_m{mode}_s{seed}"
    subprocess.run([sys.executable, str(TESTS / "golden_model.py"), str(case),
                    str(w), str(h), str(frames), str(mode), str(noise), str(seed)], check=True)
    sim = case / "sim.out"
    params = [f"-Ptb_golden.{k}={v}" for k, v in
              dict(W=w, H=h, FRAMES=frames, GAP=gap, MODE_3X3=mode, NOISE=noise).items()]
    params.append(f'-Ptb_golden.DIR="{case}"')
    subprocess.run(["iverilog", "-g2012", "-s", "tb_golden", "-o", str(sim), *params,
                    *rtl_files(), str(TESTS / "tb_golden.sv")], check=True)
    out = subprocess.run(["vvp", "-n", str(sim)], capture_output=True, text=True, timeout=600).stdout
    for line in out.splitlines():
        if line.startswith("MISMATCH"):
            print("   ", line)
    result = [l for l in out.splitlines() if l.startswith("RESULT")]
    print(result[0] if result else f"RESULT missing for {cfg}\n{out}")
    return bool(result) and result[0].endswith("PASS")


def main():
    with tempfile.TemporaryDirectory(prefix="wiener_golden_") as tmp:
        results = [run(cfg, Path(tmp)) for cfg in CONFIGS]
    passed = sum(results)
    print(f"{passed} of {len(results)} configurations passed")
    sys.exit(0 if passed == len(results) else 1)


if __name__ == "__main__":
    main()
