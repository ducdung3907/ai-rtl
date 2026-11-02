import argparse
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


def main():
    parser = argparse.ArgumentParser(description="Run echo test on serial port")
    parser.add_argument("--port", default="loop", help="serial port or 'loop'")
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--n", type=int, default=1000, help="number of bytes to send")
    parser.add_argument("--seed", type=int, default=1, help="random data seed")
    args = parser.parse_args()

    if args.baud <= 0:
        parser.error("--baud must be positive")

    timeout = max(1.0, 20 * args.n / args.baud + 1.0)
    ser = None
    try:
        ser = open_port(args.port, args.baud, timeout)
        success = echo_test(ser, args.n, args.seed)
        if success:
            print("Echo test passed.")
        else:
            print("Echo test failed.")
        sys.exit(0 if success else 1)
    finally:
        if ser is not None:
            ser.close()

if __name__ == "__main__":
    main()