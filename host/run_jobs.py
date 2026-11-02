import argparse
import struct
import sys

import numpy as np
import serial


def open_port(port, baud, timeout):
    if port == "loop":
        return serial.serial_for_url("loop://", baudrate=baud, timeout=timeout)
    else:
        return serial.Serial(port, baudrate=baud, timeout=timeout)


def echo_test(ser, n, seed):
    if n <= 0:
        raise ValueError("n must be a positive integer")
    rng = np.random.default_rng(seed)
    sent = rng.integers(0, 256, n, dtype=np.uint8).tobytes()

    ser.reset_input_buffer()
    total_written = 0
    while total_written < n:
        written = ser.write(sent[total_written:])
        if written == 0:
            raise IOError("Failed to write to serial port")
        total_written += written
    ser.flush()
    received = ser.read(n)

    match_count = sum(sent[i] == received[i] for i in range(len(received)))
    print(f"Received {len(received)}/{n} bytes, {match_count} match")
    mismatch = next(
        (i for i in range(n) if i >= len(received) or sent[i] != received[i]),
        None,
    )
    if mismatch is not None:
        got = f"0x{received[mismatch]:02x}" if mismatch < len(received) else "<missing>"
        print(f"First mismatch at index {mismatch}: sent 0x{sent[mismatch]:02x}, got {got}")

    return total_written == n and len(received) == n and match_count == n


def make_job(N, K, rng):
    A = rng.integers(-128, 128, size=(N, K), dtype=np.int8)
    B = rng.integers(-128, 128, size=(K, N), dtype=np.int8)
    extremes = np.array([-128, 127, 0], dtype=np.int8)
    for matrix in (A, B):
        mask = rng.random(matrix.shape) < 0.1
        matrix[mask] = rng.choice(extremes, size=np.count_nonzero(mask))
    return A, B


def build_job(A, B):
    N, K = A.shape
    if B.shape != (K, N):
        raise ValueError("B must have shape (K, N)")
    result = b"\xA5" + struct.pack("<H", K)
    result += b"".join(A[:, k].tobytes() + B[k, :].tobytes() for k in range(K))
    if len(result) != 3 + K * 2 * N:
        raise ValueError("invalid job packet length")
    return result


def parse_reply(data, N):
    return np.frombuffer(data, dtype="<i4").reshape(N, N)


def run_job(ser, A, B):
    N = A.shape[0]
    expected_bytes = 4 * N * N
    ser.reset_input_buffer()
    ser.write(build_job(A, B))
    data = ser.read(expected_bytes)
    if len(data) < expected_bytes:
        print(f"got {len(data)} of {expected_bytes} bytes")
        return False

    result = parse_reply(data, N)
    reference = A.astype(np.int32) @ B.astype(np.int32)
    if not np.array_equal(result, reference):
        print("Received matrix:")
        print(result)
        print("Expected matrix:")
        print(reference)
        print("Mismatch indices (row, column):")
        print(np.argwhere(result != reference))
        return False
    return True


def main():
    parser = argparse.ArgumentParser(description="Run echo test on serial port")
    parser.add_argument("--mode", choices=("echo", "job"), default="echo")
    parser.add_argument("--port", default="loop", help="serial port or 'loop'")
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--n", type=int, default=1000, help="number of bytes to send")
    parser.add_argument("--N", type=int, default=4, help="matrix dimension")
    parser.add_argument("--K", type=int, default=4, help="number of dot-product steps")
    parser.add_argument("--seed", type=int, default=1, help="random data seed")
    args = parser.parse_args()

    if args.baud <= 0:
        parser.error("--baud must be positive")
    if args.mode == "job" and (args.N <= 0 or args.K <= 0 or args.K > 65535):
        parser.error("job mode requires positive --N and --K, with --K <= 65535")

    byte_count = args.n if args.mode == "echo" else 3 + args.K * 2 * args.N + 4 * args.N * args.N
    timeout = max(1.0, 20 * byte_count / args.baud + 1.0)
    ser = None
    try:
        ser = open_port(args.port, args.baud, timeout)
        if args.mode == "echo":
            success = echo_test(ser, args.n, args.seed)
        else:
            rng = np.random.default_rng(args.seed)
            A, B = make_job(args.N, args.K, rng)
            success = run_job(ser, A, B)
        if success:
            print(f"{args.mode.capitalize()} test passed.")
        else:
            print(f"{args.mode.capitalize()} test failed.")
        sys.exit(0 if success else 1)
    finally:
        if ser is not None:
            ser.close()

if __name__ == "__main__":
    main()