"""Bit exact golden model of the wiener_top datapath.

The model reproduces the RTL fixed point arithmetic exactly (same widths,
same truncation, same saturation), so every output pixel of the RTL can be
compared with == instead of a tolerance.

Border rule (same as the RTL): a neighbour that falls outside the image is
replaced by its mirror about the window centre. For a centre at row 0 the
row -1 neighbour is row +1 and the row -2 neighbour is row +2. Columns use
the same rule.

Usage as a script (used by run_golden.py):
    python3 golden_model.py OUT_DIR WIDTH HEIGHT FRAMES MODE_3X3 NOISE_Q16_8 SEED
writes OUT_DIR/in.hex (all frames, raster order) and OUT_DIR/expected.hex.
"""

import random
import sys
from pathlib import Path

# Reciprocal constants from stats_calc_5x5.sv
MU_RECIP_9 = 1864136        # ceil(2^24 / 9)
MU_RECIP_25 = 671089        # ceil(2^24 / 25)
MU_SHIFT = 16
EX2_RECIP_9 = 238609295     # ceil(2^31 / 9)
EX2_RECIP_25 = 85899346     # ceil(2^31 / 25)
EX2_SHIFT = 23

# Constants from wiener_core.sv
W_MIN_Q1_8 = 16             # minimum weight, 0.0625
R_ZERO_THRESHOLD = 236      # R >= 236/256 gives weight 0 (then the floor)
MAX_VAL = 65280             # 255.0 in Q8.8


def mirror(c, d, size):
    # Neighbour at offset d from centre c, mirrored about the centre when
    # it would fall outside [0, size)
    return c + d if 0 <= c + d < size else c - d


def noise_q14_4(noise_q16_8):
    # wiener_top: Q16.8 -> drop 4 fraction bits -> saturate to 18 bits
    q16_4 = (noise_q16_8 & 0xFFFFFF) >> 4
    return 0x3FFFF if q16_4 >> 18 else q16_4


def stats(window, mode_3x3):
    # window is a 5x5 list [row][col] of pixels, centre at [2][2]
    if mode_3x3:
        pix = [window[r][c] for r in range(1, 4) for c in range(1, 4)]
    else:
        pix = [window[r][c] for r in range(5) for c in range(5)]
    sum_x = sum(pix)
    sum_x2 = sum(p * p for p in pix)

    # Mean, Q8.8 (16 bit result)
    mu_recip = MU_RECIP_9 if mode_3x3 else MU_RECIP_25
    mu = ((sum_x * mu_recip) >> MU_SHIFT) & 0xFFFF

    # E[x^2], Q16.8 (24 bit result)
    ex2_recip = EX2_RECIP_9 if mode_3x3 else EX2_RECIP_25
    ex2 = ((sum_x2 * ex2_recip) >> EX2_SHIFT) & 0xFFFFFF

    # Mean squared, Q16.8
    mu_sq = ((mu * mu) >> 8) & 0xFFFFFF

    # Variance, floored at 0, then Q16.8 -> Q16.4 -> saturate to Q14.4
    var_q16_8 = ex2 - mu_sq if ex2 > mu_sq else 0
    var_q16_4 = var_q16_8 >> 4
    var_q14_4 = 0x3FFFF if var_q16_4 >> 18 else var_q16_4
    return mu, var_q14_4


def core(mu, var_q14_4, noise, pixel):
    # Safe variance and ratio R = noise / var with 8 fraction bits
    sigma2 = var_q14_4 if var_q14_4 != 0 else 1
    r_full = (noise << 8) // sigma2

    # Weight 1 - R (Q1.8), zero above the threshold, then the floor
    w = 0 if r_full >= R_ZERO_THRESHOLD else (256 - (r_full & 0x1FF)) & 0x1FF
    w = max(w, W_MIN_Q1_8)

    # out = mu + w * (pixel - mu), arithmetic in signed Q8.8
    diff = (pixel << 8) - mu
    prod = (w * diff) >> 8          # Python >> on negatives is arithmetic
    restored = mu + prod

    # Clamp to [0, 255.0] and keep the integer part
    if restored <= 0:
        restored = 0
    elif restored >= MAX_VAL:
        restored = MAX_VAL
    return (restored >> 8) & 0xFF


def filter_frame(img, width, height, mode_3x3, noise_q16_8):
    # img is a flat list in raster order, returns the filtered flat list
    noise = noise_q14_4(noise_q16_8)
    out = []
    for y in range(height):
        for x in range(width):
            window = [[img[mirror(y, dy, height) * width + mirror(x, dx, width)]
                       for dx in range(-2, 3)] for dy in range(-2, 3)]
            mu, var = stats(window, mode_3x3)
            out.append(core(mu, var, noise, img[y * width + x]))
    return out


def make_frame(width, height, rng):
    # Test image: smooth gradient plus random edges plus noise, so that
    # flat areas (low variance) and edges (high variance) are both covered
    img = []
    for y in range(height):
        for x in range(width):
            base = (x * 255) // max(width - 1, 1) // 2 + (y * 255) // max(height - 1, 1) // 2
            if rng.random() < 0.05:
                base = rng.choice([0, 255])
            img.append(max(0, min(255, base + int(rng.gauss(0, 25)))))
    return img


def main():
    out_dir, width, height, frames, mode_3x3, noise_q16_8, seed = sys.argv[1:8]
    width, height, frames = int(width), int(height), int(frames)
    mode_3x3, noise_q16_8, seed = int(mode_3x3), int(noise_q16_8), int(seed)
    rng = random.Random(seed)
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    pixels, expected = [], []
    for _ in range(frames):
        img = make_frame(width, height, rng)
        pixels += img
        expected += filter_frame(img, width, height, mode_3x3, noise_q16_8)
    (out_dir / "in.hex").write_text("".join(f"{p:02x}\n" for p in pixels))
    (out_dir / "expected.hex").write_text("".join(f"{p:02x}\n" for p in expected))


if __name__ == "__main__":
    main()
