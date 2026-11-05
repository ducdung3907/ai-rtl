"""Find where a reply goes wrong at a high baud rate (default 2 Mbaud).

Sends five K = 31 jobs and prints how many reply bytes arrived and the first
byte that differs from NumPy's result.

    python host/diag2m.py --port COM3 --baud 2000000
"""
import argparse

import numpy as np

from run_jobs import build_job, make_job, open_port


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", default="COM3")
    ap.add_argument("--baud", type=int, default=2_000_000)
    ap.add_argument("--N", type=int, default=4)
    ap.add_argument("--K", type=int, default=31)
    ap.add_argument("--trials", type=int, default=5)
    args = ap.parse_args()

    n_bytes = 4 * args.N * args.N
    ser = open_port(args.port, args.baud, 2.0, args.N)
    try:
        for trial in range(args.trials):
            A, B = make_job(args.N, args.K, np.random.default_rng(trial))
            exp = (A.astype(np.int32) @ B.astype(np.int32)).astype("<i4").tobytes()
            ser.reset_input_buffer()
            ser.write(build_job(A, B))
            got = ser.read(n_bytes)
            first = next((k for k in range(min(len(got), n_bytes)) if got[k] != exp[k]), None)
            print(f"trial {trial}: got {len(got)}/{n_bytes}, first difference at byte {first}")
    finally:
        ser.close()


if __name__ == "__main__":
    main()
