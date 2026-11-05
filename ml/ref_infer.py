"""Golden model: integer-only inference from weights/mlp_64_int8.npz (no floats).

  python ref_infer.py            # int8 validation accuracy
  python ref_infer.py --test     # also test accuracy (once, at the end)

predict() takes an optional matmul function, so board_infer.py can run the same
pipeline with the two matrix multiplies done by the FPGA.
"""
import argparse
from pathlib import Path

import numpy as np

import data

MODEL_PATH = Path(__file__).resolve().parent / "weights" / "mlp_64_int8.npz"


def load_model(path=MODEL_PATH):
    with np.load(path, allow_pickle=False) as d:
        return {k: d[k] for k in d.files}


def quantize_pixels(pixels):
    """uint8 pixels (n, 784), 0..255 -> int32 0..127, i.e. round(pixel * 127 / 255) in integers."""
    pixels = np.asarray(pixels, dtype=np.uint8)
    if pixels.ndim != 2 or pixels.shape[1] != 784:
        raise ValueError(f"expected pixels of shape (n, 784), got {pixels.shape}")
    return (pixels.astype(np.int32) * 127 + 127) // 255


def requant(acc, M, shift):
    """int32 accumulator -> int8: round(acc * M / 2**shift) clamped to 0..127 (ReLU folded in)."""
    shift = int(shift)
    assert shift > 0
    return np.clip((acc.astype(np.int64) * int(M) + (1 << (shift - 1))) >> shift, 0, 127).astype(np.int8)


def predict(q, pixels, matmul=None):
    """Integer pipeline. Returns (predictions, int32 logits).

    q:      dict of arrays from mlp_64_int8.npz
    pixels: uint8 (n, 784)
    matmul: optional function (A, B) -> int32 A @ B; default is plain numpy.
            board_infer.py passes the FPGA matmul here.
    """
    mm = matmul or (lambda a, b: a.astype(np.int32) @ b.astype(np.int32))
    x_q = quantize_pixels(pixels)

    acc1 = mm(x_q, q["W1_q"]) + q["b1_q"]         # matmul (FPGA) + bias (host)
    a1 = requant(acc1, q["M1"], q["shift1"])      # requantize + ReLU (host)
    acc2 = mm(a1, q["W2_q"]) + q["b2_q"]          # matmul (FPGA) + bias (host)
    return acc2.argmax(axis=1), acc2


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--test", action="store_true", help="also report test accuracy (once, at the end)")
    args = ap.parse_args()

    q = load_model()
    X, Y, X_test, Y_test = data.load_mnist(raw=True)

    pred, _ = predict(q, X[-5000:])
    print(f"int8 validation accuracy: {np.mean(pred == Y[-5000:]):.2%}")
    if args.test:
        pred, _ = predict(q, X_test)
        print(f"int8 test accuracy: {np.mean(pred == Y_test):.2%}")
