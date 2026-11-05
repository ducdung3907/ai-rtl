"""float weights -> int8 weights + int32 biases + integer requantize multiplier.

  python quantize.py     # reads weights/mlp_64_float.npz, writes weights/mlp_64_int8.npz
"""
from math import floor, log2
from pathlib import Path

import numpy as np

import data
from ref_infer import quantize_pixels, requant

HERE = Path(__file__).resolve().parent
S_X = 1 / 127                                   # input scale: x_q = round(pixel * 127 / 255)


def quantize_weights(W):
    """Symmetric per-tensor int8: W ~ W_q * s_w."""
    W = W.astype(np.float64)
    s_w = np.abs(W).max() / 127
    W_q = np.clip(np.round(W / s_w), -127, 127).astype(np.int8)
    assert np.abs(W_q).max() == 127
    assert np.abs(W - W_q * s_w).max() <= s_w / 2 + 1e-9
    return W_q, s_w


def quantize(params, n_calib=5000):
    W1_q, s_w1 = quantize_weights(params["W1"])
    W2_q, s_w2 = quantize_weights(params["W2"])

    # calibrate the layer-1 output range on training images (never the test set)
    x_q = quantize_pixels(data.load_mnist(raw=True)[0][:n_calib])
    h = np.maximum((x_q / 127) @ params["W1"] + params["b1"], 0)       # float reference
    print(f"layer-1 output: max {h.max():.4f}, 99.9th percentile {np.percentile(h, 99.9):.4f}")
    s_a1 = h.max() / 127

    # requantize multiplier m1 = M1 / 2**shift1, with M1 in [2**14, 2**15)
    m1 = S_X * s_w1 / s_a1
    shift1 = 14 - floor(log2(m1))
    M1 = int(round(m1 * 2**shift1))
    assert abs(M1 / 2**shift1 - m1) / m1 <= 2**-14

    # biases live at the accumulator scale (int32)
    b1_q = np.round(params["b1"] / (S_X * s_w1)).astype(np.int32)
    b2_q = np.round(params["b2"] / (s_a1 * s_w2)).astype(np.int32)

    # integer layer 1 on the calibration images: headroom, saturation, agreement with the exact scaling
    acc1 = x_q @ W1_q.astype(np.int32) + b1_q
    assert np.abs(acc1.astype(np.int64)).max() < 2**31
    a1_q = requant(acc1, M1, shift1)
    ideal = np.clip(np.round(np.maximum(acc1 * (S_X * s_w1), 0) / s_a1), 0, 127)
    assert np.abs(a1_q.astype(int) - ideal).max() <= 1                  # requant() == exact scaling, to 1 step
    drift = np.abs(a1_q.astype(int) - np.clip(np.round(h / s_a1), 0, 127)).mean()
    print(f"max |acc1| {np.abs(acc1).max()}, saturated at 127: {np.mean(a1_q == 127):.4%}, "
          f"M1 {M1}, shift1 {shift1}, s_a1 {s_a1:.5f}")
    print(f"layer-1 int8 vs float activations: mean |difference| {drift:.3f} steps (weight rounding)")

    return dict(W1_q=W1_q, W2_q=W2_q, b1_q=b1_q, b2_q=b2_q,
                M1=np.int64(M1), shift1=np.int64(shift1),
                s_x=S_X, s_w1=s_w1, s_w2=s_w2, s_a1=s_a1)


if __name__ == "__main__":
    with np.load(HERE / "weights" / "mlp_64_float.npz", allow_pickle=False) as d:
        params = {k: d[k] for k in d.files}
    for name, arr in params.items():
        print(f"{name}: shape {arr.shape}, dtype {arr.dtype}, "
              f"min {arr.min():.3f}, max {arr.max():.3f}, mean |x| {np.abs(arr).mean():.3f}")

    q = quantize(params)
    np.savez(HERE / "weights" / "mlp_64_int8.npz", **q)
    print("saved weights/mlp_64_int8.npz:", {k: np.asarray(v).dtype.name for k, v in q.items()})