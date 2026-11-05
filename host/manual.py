"""Hand-checked single-tile matmuls on the board: a few tiny cases against NumPy.

    python host/manual.py --port COM3
    python host/manual.py --port fake
"""
import argparse

import numpy as np

from run_jobs import build_job, open_port, parse_reply

N = 4


def board_matmul(ser, A, B):
    """A is r x K, B is K x c (r, c <= N). Returns the r x c result from the FPGA."""
    A = np.array(A, dtype=np.int8)
    B = np.array(B, dtype=np.int8)
    r, K = A.shape
    c = B.shape[1]
    Ap = np.zeros((N, K), np.int8)
    Ap[:r, :] = A
    Bp = np.zeros((K, N), np.int8)
    Bp[:, :c] = B
    ser.reset_input_buffer()
    ser.write(build_job(Ap, Bp))
    C = parse_reply(ser.read(4 * N * N), N)
    return C[:r, :c]


TESTS = [
    ([[2]], [[5]]),
    ([[1, 2], [3, 4]], [[5, 6], [7, 8]]),
    ([[1, 2, 3, 4, 5]], [[1], [1], [1], [1], [1]]),
    ([[-128]], [[-128]]),
]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", default="COM3")
    ap.add_argument("--baud", type=int, default=1_000_000)
    ap.add_argument("--timeout", type=float, default=2.0)
    args = ap.parse_args()

    ser = open_port(args.port, args.baud, args.timeout, N)
    bad = 0
    try:
        for A, B in TESTS:
            got = board_matmul(ser, A, B)
            exp = np.array(A, dtype=np.int32) @ np.array(B, dtype=np.int32)
            ok = np.array_equal(got, exp)
            bad += not ok
            print("A =", A, " B =", B)
            print("board:\n", got, "\nnumpy:\n", exp, "\n", "OK" if ok else "MISMATCH", "\n")
    finally:
        ser.close()
    raise SystemExit(1 if bad else 0)


if __name__ == "__main__":
    main()
