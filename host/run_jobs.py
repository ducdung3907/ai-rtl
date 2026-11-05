import argparse
import struct
import sys
import time
from collections import deque

import numpy as np
import serial


class FakeBoard:
    def __init__(self, N):
        self.N = N
        self.reply = b""

    def reset_input_buffer(self):
        self.reply = b""

    def write(self, data):
        if not data or data[0] != 0xA5 or len(data) < 3:
            return len(data)

        K = struct.unpack("<H", data[1:3])[0]
        if len(data) != 3 + K * 2 * self.N:
            return len(data)
        if K == 0:
            return len(data)

        A = np.empty((self.N, K), dtype=np.int8)
        B = np.empty((K, self.N), dtype=np.int8)
        offset = 3
        for k in range(K):
            A[:, k] = np.frombuffer(data[offset : offset + self.N], dtype=np.int8)
            offset += self.N
            B[k, :] = np.frombuffer(data[offset : offset + self.N], dtype=np.int8)
            offset += self.N
        C = A.astype(np.int32) @ B.astype(np.int32)
        self.reply += C.astype("<i4").tobytes()      # replies queue up in order, like the board's
        return len(data)

    def read(self, n):
        result, self.reply = self.reply[:n], self.reply[n:]
        return result

    def close(self):
        pass

    def flush(self):
        pass


def open_port(port, baud, timeout, N):
    if port == "fake":
        return FakeBoard(N)
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


def run_jobs(ser, N, jobs, kmax, rng, baud, prep=False, window=1):
    """Send jobs keeping up to `window` of them outstanding (window=1: one at a time).

    window >= 2 needs the pipelined bitstream (sync_fifo + res_buf): the next request
    is written while the board is still computing / sending the previous reply.
    Replies come back in job order, so a FIFO of expected results is enough.
    """
    def new_job():
        K = int(rng.integers(1, kmax + 1))
        A, B = make_job(N, K, rng)
        return K, build_job(A, B), A.astype(np.int32) @ B.astype(np.int32)

    prepared = [new_job() for _ in range(jobs)] if prep else None

    pending = deque()                       # (job_number, K, expected) written, reply not read yet
    sent = 0
    passed = 0
    bytes_moved = 0
    write_time = 0.0
    read_time = 0.0
    failed = False
    ser.reset_input_buffer()
    start = time.perf_counter()
    for job_number in range(1, jobs + 1):
        # top up: keep `window` jobs in flight
        while sent < jobs and sent < job_number - 1 + window:
            K, packet, expected = prepared[sent] if prep else new_job()
            write_start = time.perf_counter()
            written = ser.write(packet)
            write_time += time.perf_counter() - write_start
            bytes_moved += len(packet)
            sent += 1
            pending.append((sent, K, expected))
            if written != len(packet):
                print(f"Job {sent} failed (K={K}): incomplete write")
                failed = True
                break
        if failed:
            break

        number, K, expected = pending.popleft()
        read_start = time.perf_counter()
        data = ser.read(4 * N * N)
        read_time += time.perf_counter() - read_start
        bytes_moved += len(data)
        if len(data) < 4 * N * N:
            print(f"Job {number} failed (K={K}): got {len(data)} of {4 * N * N} reply bytes")
            break

        result = parse_reply(data, N)
        if not np.array_equal(result, expected):
            print("Received matrix:")
            print(result)
            print("Expected matrix:")
            print(expected)
            print("Mismatch indices (row, column):")
            print(np.argwhere(result != expected))
            print(f"Job {number} failed (K={K})")
            break
        passed += 1
    elapsed = time.perf_counter() - start

    print(f"window {window}: passed {passed} / {jobs} jobs")
    print(f"Total time: {elapsed:.3f} s")
    print(f"Jobs per second: {passed / elapsed:.2f}" if elapsed else "Jobs per second: n/a")
    print(f"Bytes moved: {bytes_moved}")
    print(
        f"Effective throughput: {bytes_moved / elapsed:.2f} bytes/s"
        if elapsed else "Effective throughput: n/a"
    )
    if passed:
        # with window > 1 the write and read times overlap with the board's work
        print(f"Average time blocked in ser.write(): {write_time / max(sent, 1):.6f} s")
        print(f"Average time blocked in ser.read(): {read_time / passed:.6f} s")
    print(f"UART limit: {baud / 10:.0f} bytes/s")
    return passed == jobs


def main():
    parser = argparse.ArgumentParser(description="Run serial tests")
    parser.add_argument("--mode", choices=("echo", "job", "run"), default="echo")
    parser.add_argument("--port", default="loop", help="serial port or 'loop'")
    parser.add_argument("--baud", type=int, default=1000000)
    parser.add_argument("--n", type=int, default=1000, help="number of bytes to send")
    parser.add_argument("--N", type=int, default=4, help="matrix dimension")
    parser.add_argument("--K", type=int, default=4, help="number of dot-product steps")
    parser.add_argument("--jobs", type=int, default=1000, help="number of jobs in run mode")
    parser.add_argument("--kmax", type=int, default=64, help="maximum K in run mode")
    parser.add_argument("--prep", action="store_true", help="prepare all run-mode jobs before timing")
    parser.add_argument("--window", type=int, default=1,
                        help="jobs kept in flight in run mode (1 = one at a time; >= 2 needs the pipelined bitstream)")
    parser.add_argument("--seed", type=int, default=1, help="random data seed")
    args = parser.parse_args()

    if args.baud <= 0:
        parser.error("--baud must be positive")
    if args.mode == "job" and (args.N <= 0 or args.K <= 0 or args.K > 65535):
        parser.error("job mode requires positive --N and --K, with --K <= 65535")
    if args.window < 1:
        parser.error("--window must be at least 1")
    if args.mode == "run" and (
        args.N <= 0 or args.jobs <= 0 or args.kmax <= 0 or args.kmax > 65535
    ):
        parser.error("run mode requires positive --N, --jobs, and --kmax, with --kmax <= 65535")

    if args.mode == "echo":
        byte_count = args.n
    elif args.mode == "run":
        byte_count = 3 + args.kmax * 2 * args.N + 4 * args.N * args.N
    else:
        byte_count = 3 + args.K * 2 * args.N + 4 * args.N * args.N
    timeout = max(1.0, 20 * byte_count / args.baud + 1.0)
    ser = None
    try:
        ser = open_port(args.port, args.baud, timeout, args.N)
        if args.mode == "echo":
            success = echo_test(ser, args.n, args.seed)
        elif args.mode == "job":
            rng = np.random.default_rng(args.seed)
            A, B = make_job(args.N, args.K, rng)
            success = run_job(ser, A, B)
        else:
            rng = np.random.default_rng(args.seed)
            success = run_jobs(ser, args.N, args.jobs, args.kmax, rng, args.baud, args.prep, args.window)
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