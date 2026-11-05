"""Run the int8 MNIST pipeline with the two matrix multiplies on the FPGA.

  python board_infer.py --check --n 20                   # FakeBoard: tests the host tiling, no hardware
  python board_infer.py --port COM3 --check --n 100      # the real board

The pipeline is ref_infer.predict(); only the matmul differs. With --check the logits
from the board path must equal the plain-numpy logits exactly (integer maths is exact).
"""
import argparse
import sys
import time
from pathlib import Path

import numpy as np

sys.path.append(str(Path(__file__).resolve().parent.parent / "host"))
from run_jobs import build_job, open_port, parse_reply       # one copy of the UART protocol

import data
from ref_infer import load_model, predict

N = 4                                                         # the array is N x N


def make_board_matmul(ser, stats):
    """Returns matmul(A, B) = A @ B (int32), computed tile by tile on the board."""

    def tile(A, B):                                           # A (r <= N, K) @ B (K, c <= N): one job
        r, K = A.shape
        c = B.shape[1]
        Ap = np.zeros((N, K), np.int8); Ap[:r] = A            # pad a partial tile with zeros
        Bp = np.zeros((K, N), np.int8); Bp[:, :c] = B
        ser.reset_input_buffer()
        job = build_job(Ap, Bp)
        ser.write(job)
        reply = ser.read(4 * N * N)
        if len(reply) != 4 * N * N:
            raise RuntimeError(f"short reply: {len(reply)} of {4 * N * N} bytes (job {stats['jobs']}, K={K})")
        stats["jobs"] += 1
        stats["bytes"] += len(job) + len(reply)
        return parse_reply(reply, N)[:r, :c]

    def matmul(A, B):
        A, B = np.asarray(A), np.asarray(B)
        assert -128 <= A.min() and A.max() <= 127 and -128 <= B.min() and B.max() <= 127, "value outside int8"
        A, B = A.astype(np.int8), B.astype(np.int8)
        m, n = A.shape[0], B.shape[1]
        C = np.zeros((m, n), np.int32)
        for i in range(0, m, N):
            for j in range(0, n, N):
                C[i:i + N, j:j + N] = tile(A[i:i + N], B[:, j:j + N])
        return C

    return matmul


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", default="fake", help="COM3, /dev/ttyUSB0, or fake (default)")
    ap.add_argument("--baud", type=int, default=1_000_000)
    ap.add_argument("--timeout", type=float, default=2.0)
    ap.add_argument("--n", type=int, default=20, help="number of validation images")
    ap.add_argument("--check", action="store_true", help="compare logits with plain numpy (must be identical)")
    args = ap.parse_args()

    q = load_model()
    X, Y, _, _ = data.load_mnist(raw=True)
    pixels, labels = X[-5000:][:args.n], Y[-5000:][:args.n]

    ser = open_port(args.port, args.baud, args.timeout, N)
    stats = {"jobs": 0, "bytes": 0}
    t0 = time.perf_counter()
    pred, logits = predict(q, pixels, matmul=make_board_matmul(ser, stats))
    dt = time.perf_counter() - t0
    ser.close()

    print(f"{args.n} images in {dt:.2f} s ({1000 * dt / args.n:.0f} ms/image), "
          f"{stats['jobs']} jobs, {stats['bytes'] / 1000:.0f} KB over the UART ({stats['bytes'] / args.n / 1000:.1f} KB/image)")
    print(f"board accuracy on these {args.n} images: {np.mean(pred == labels):.2%}")

    if args.check:
        ref_pred, ref_logits = predict(q, pixels)
        bad = np.argwhere(logits != ref_logits)
        if len(bad):
            i, k = bad[0]
            print(f"MISMATCH: {len(bad)} of {logits.size} logits differ; first: image {i}, class {k}, "
                  f"board {logits[i, k]} vs reference {ref_logits[i, k]}")
            sys.exit(1)
        print(f"bit-exact on {args.n} images (all {logits.size} logits identical to ref_infer)")
