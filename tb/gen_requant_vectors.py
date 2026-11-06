"""Write tb/vectors/requant.hex for tb_requant.sv (pure Python, no NumPy needed).

Each line is 24 hex digits: acc(8) bias(8) M(4) shift(2) expected_y(2).
The expected value uses the same integer formula as ml/ref_infer.py:
    y = clip((((acc + bias) * M) + (1 << (shift - 1))) >> shift, 0, 127)

    python tb/gen_requant_vectors.py            # rewrites tb/vectors/requant.hex
"""
import os
import random

N_RANDOM = 4000
I32_MIN, I32_MAX = -(2**31), 2**31 - 1


def requant(t, M, shift):
    return min(max((t * M + (1 << (shift - 1))) >> shift, 0), 127)   # Python >> on ints is arithmetic


def row(acc, bias, M, shift):
    t = acc + bias
    assert I32_MIN <= t <= I32_MAX, "acc + bias must fit in int32"
    assert 2**14 <= M < 2**15 and 1 <= shift <= 47
    return "%08x%08x%04x%02x%02x" % (acc & 0xFFFFFFFF, bias & 0xFFFFFFFF, M, shift, requant(t, M, shift))


def main():
    rng = random.Random(1)
    rows = []

    # random: real result spread over negative, in-range and saturating values
    for _ in range(N_RANDOM):
        shift = rng.randint(15, 40)
        M = rng.randint(2**14, 2**15 - 1)
        target = rng.uniform(-40, 200)
        t = int(max(I32_MIN + 1, min(I32_MAX - 1, target / (M / 2**shift))))
        bias = rng.randint(-5000, 5000)
        acc = t - bias
        if not (I32_MIN <= acc <= I32_MAX):
            acc = 0
        rows.append(row(acc, bias, M, shift))

    # edges: int32 extremes, tiny values, every shift, both ends of M
    for shift in list(range(1, 48)):
        for M in (2**14, 2**15 - 1, 2**14 + 7):
            for t in (0, 1, -1, 2, -2, 127, 128, 12345, -12345, I32_MAX, I32_MIN):
                rows.append(row(t, 0, M, shift))

    # exact rounding ties: t * M / 2**shift = k + 0.5
    for shift in range(1, 24):
        M = 2**14
        for k in (0, 1, 2, 63, 126, 127, 128):
            t = ((2 * k + 1) << (shift - 1)) // M if ((2 * k + 1) << (shift - 1)) % M == 0 else None
            if t is not None and I32_MIN <= t <= I32_MAX:
                rows.append(row(t, 0, M, shift))

    rng.shuffle(rows)
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "vectors", "requant.hex")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write("\n".join(rows) + "\n")
    print(f"{len(rows)} vectors -> {path}")


if __name__ == "__main__":
    main()  