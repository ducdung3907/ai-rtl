"""Run the int8 MNIST network on the FPGA.

Two board designs:

  v2 (sa_board_top, default): the board only does the matrix multiplies; the host tiles, adds the biases,
  requantises and takes the argmax. Every tile is one job over the UART.
    python board_infer.py --check --n 20                    # FakeBoard: tests the host tiling, no hardware
    python board_infer.py --port COM6 --check --n 100       # the real board

  v3 (infer_board_top, --onchip): the weights live in block RAM and the board runs the whole network.
  The host sends frames of 4 images (host/infer_frame.py) and reads back 4 digits, one frame at a time
  (stop and wait: the next frame goes out only after the reply to the previous one).
    python board_infer.py --onchip --n 100                  # FakeInferBoard, no hardware
    python board_infer.py --onchip --port COM6 --n 1000     # the real board
    python board_infer.py --onchip --port COM6 --test       # all 10,000 test images

v2 --check: the logits must equal the plain-numpy logits exactly (integer maths is exact).
v3: the digits are always compared with ref_infer; every one must match.
"""
import argparse
import sys
import time
from pathlib import Path

import numpy as np

sys.path.append(str(Path(__file__).resolve().parent.parent / "host"))
from run_jobs import build_job, open_port, parse_reply       # one copy of the UART protocol
from infer_frame import N_IMG, OK_REPLY_LEN, FakeInferBoard, ReplyError, build_frame
from infer_frame import parse_reply as parse_frame_reply

import data
from ref_infer import load_model, predict, quantize_pixels, requant

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


def digits_from_q(q, x_q):
    """Integer model on pixels that are already 0..127 (what the board receives). Returns the digits."""
    acc1 = x_q.astype(np.int64) @ q["W1_q"].astype(np.int64) + q["b1_q"]
    a1 = requant(acc1, q["M1"], q["shift1"]).astype(np.int64)
    acc2 = a1 @ q["W2_q"].astype(np.int64) + q["b2_q"]
    return acc2.argmax(axis=1)


def run_onchip(ser, x_q, retries=3, log=print):
    """Send x_q (n, 784, values 0..127) to an infer_board_top, 4 images per frame, stop and wait.

    Returns (digits (n,), stats). A checksum error, a timeout or a reply with the wrong seq is
    retried with a fresh seq after clearing the input buffer, up to `retries` times per frame.
    """
    n = len(x_q)
    digits = np.zeros(n, dtype=np.int64)
    stats = {"frames": 0, "retries": 0, "bytes_out": 0, "bytes_in": 0}   # bytes_in: good replies only
    seq = 0
    ser.reset_input_buffer()
    for b in range(0, n, N_IMG):
        chunk = x_q[b:b + N_IMG]
        for attempt in range(retries + 1):
            frame = build_frame(chunk, seq)
            ser.write(frame)
            stats["bytes_out"] += len(frame)
            try:
                got = parse_frame_reply(ser.read, seq, n_images=len(chunk))
                stats["bytes_in"] += OK_REPLY_LEN
                break
            except ReplyError as e:
                stats["retries"] += 1
                log(f"frame {b // N_IMG} (seq {seq}): {e}; " + ("retrying" if attempt < retries else "giving up"))
                ser.reset_input_buffer()
                if attempt == retries:
                    raise
            finally:
                seq = (seq + 1) & 0x7F
        digits[b:b + len(chunk)] = got
        stats["frames"] += 1
    return digits, stats


def main_onchip(args, q, pixels, labels):
    x_q = quantize_pixels(pixels)
    ref = digits_from_q(q, x_q)
    ref_pred, _ = predict(q, pixels)                  # the same model through ref_infer's own path
    assert np.array_equal(ref, ref_pred), "digits_from_q disagrees with ref_infer.predict"

    if args.port == "fake":
        ser = FakeInferBoard(lambda imgs: digits_from_q(q, imgs.astype(np.int64)))
    else:
        ser = open_port(args.port, args.baud, args.timeout, N)
    t0 = time.perf_counter()
    try:
        got, st = run_onchip(ser, x_q, retries=args.retries)
    finally:
        ser.close()
    dt = time.perf_counter() - t0

    n = len(x_q)
    print(f"{n} images in {dt:.2f} s: {1000 * dt / n:.2f} ms/image, {n / dt:.1f} images/s "
          f"({st['frames']} frames, {st['retries']} retries)")
    print(f"UART: {st['bytes_out']} bytes out, {st['bytes_in']} bytes in "
          f"({st['bytes_out'] / n:.0f} + {st['bytes_in'] / n:.1f} bytes/image)")
    print(f"board accuracy on these {n} images: {np.mean(got == labels):.2%}")
    bad = np.flatnonzero(got != ref)
    if len(bad):
        i = bad[0]
        print(f"MISMATCH: {len(bad)} of {n} digits differ from ref_infer; first: image {i}, "
              f"board {got[i]} vs reference {ref[i]}")
        sys.exit(1)
    print(f"all {n} digits identical to ref_infer")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", default="fake", help="COM3, /dev/ttyUSB0, or fake (default)")
    ap.add_argument("--baud", type=int, default=1_000_000)
    ap.add_argument("--timeout", type=float, default=2.0)
    ap.add_argument("--n", type=int, default=20, help="number of images (default 20)")
    ap.add_argument("--test", action="store_true", help="use the test set (all 10,000 unless --n is given)")
    ap.add_argument("--check", action="store_true", help="v2: compare logits with plain numpy (must be identical)")
    ap.add_argument("--onchip", action="store_true", help="v3 board (infer_board_top): whole network on the FPGA")
    ap.add_argument("--retries", type=int, default=3, help="v3: resends per frame after an error (default 3)")
    args = ap.parse_args()

    q = load_model()
    X, Y, X_test, Y_test = data.load_mnist(raw=True)
    if args.test:
        n = args.n if any(a.startswith("--n") for a in sys.argv[1:]) else len(X_test)
        pixels, labels = X_test[:n], Y_test[:n]
    else:
        pixels, labels = X[-5000:][:args.n], Y[-5000:][:args.n]

    if args.onchip:
        main_onchip(args, q, pixels, labels)
        sys.exit(0)

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
