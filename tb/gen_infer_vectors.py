#!/usr/bin/env python3
"""Test vectors for tb_infer_core: input words, expected hidden words and expected digits.
 
  python3 tb/gen_infer_vectors.py            # 12 batches of 4 images -> tb/vectors/infer_*.hex
 
Run from the repository root. Pure integer arithmetic (the same formulas as ml/ref_infer.py),
so the expected values are exactly what the FPGA has to produce.
 
Per batch b (4 images, pixels already quantised to 0..127):
  infer_in.hex   784 lines: word k = pixel k of images 0..3, byte i = image i (= pixels.T.tobytes())
  infer_hid.hex  64 lines:  word n = hidden neuron n, byte i = image i
  infer_dig.hex  1 line:    4 hex digits, digit i (low nibble first) = predicted digit of image i
"""
import argparse
import sys
from pathlib import Path
 
import numpy as np
 
ROOT = Path(__file__).resolve().parent.parent
MODEL = ROOT / "ml" / "weights" / "mlp_64_int8.npz"
OUT = ROOT / "tb" / "vectors"
 
 
def load_model():
    with np.load(MODEL, allow_pickle=False) as d:
        return {k: d[k] for k in d.files}
 
 
def requant(acc, M, shift):
    shift = int(shift)
    return np.clip((acc.astype(np.int64) * int(M) + (1 << (shift - 1))) >> shift, 0, 127).astype(np.int64)
 
 
def forward(q, x):
    """x: (n, 784) ints 0..127 -> hidden (n, 64) 0..127, logits (n, 10) int, digits (n,)"""
    acc1 = x.astype(np.int64) @ q["W1_q"].astype(np.int64) + q["b1_q"].astype(np.int64)
    hid = requant(acc1, q["M1"], q["shift1"])
    acc2 = hid @ q["W2_q"].astype(np.int64) + q["b2_q"].astype(np.int64)
    return hid, acc2, acc2.argmax(axis=1)
 
 
def blob_images(rng, n):
    """MNIST-ish: a few smooth strokes, mostly zero background, 0..127."""
    yy, xx = np.mgrid[0:28, 0:28]
    out = np.zeros((n, 28, 28))
    for i in range(n):
        for _ in range(rng.integers(2, 6)):
            cy, cx = rng.uniform(6, 22, 2)
            sy, sx = rng.uniform(1.5, 6, 2)
            out[i] += rng.uniform(0.5, 1.0) * np.exp(-(((yy - cy) / sy) ** 2 + ((xx - cx) / sx) ** 2))
    out = np.clip(out, 0, 1) * 127
    out[out < 20] = 0
    return out.reshape(n, 784).astype(np.int64)
 
 
def words_in(x):          # x (4, 784) -> 784 words
    return [sum(int(x[i, k]) << (8 * i) for i in range(4)) for k in range(784)]
 
 
def words_hid(h):         # h (4, 64) -> 64 words
    return [sum(int(h[i, n]) << (8 * i) for i in range(4)) for n in range(64)]
 
 
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=12, help="number of batches (default 12)")
    ap.add_argument("--seed", type=int, default=1)
    args = ap.parse_args()
    if args.n < 6:
        sys.exit("need at least 6 batches")
    rng = np.random.default_rng(args.seed)
    q = load_model()
 
    batches = []          # (label, x (4,784))
    batches.append(("all zeros", np.zeros((4, 784), dtype=np.int64)))
    batches.append(("all 127", np.full((4, 784), 127, dtype=np.int64)))
    batches.append(("uniform random 0..127", rng.integers(0, 128, (4, 784))))
    batches.append(("strokes (blobs)", blob_images(rng, 4)))
 
    # images whose 10 real logits are all negative: here a padded column (logit 0 + bias 0)
    # would win the argmax if the controller fed it
    pool = np.concatenate([blob_images(rng, 6000),
                           rng.integers(0, 128, (4000, 784)),
                           (rng.integers(0, 128, (4000, 784)) * rng.uniform(0, 1, (4000, 1))).astype(np.int64)])
    hid, acc2, dig = forward(q, pool)
    neg = np.where(acc2.max(axis=1) < 0)[0]
    print(f"images with all 10 logits negative found: {len(neg)} (of {len(pool)})")
    if len(neg) >= 1:
        sel = list(neg[:4])
        while len(sel) < 4:
            sel.append(int(rng.integers(len(pool))))
        batches.append(("all-negative logits (padding would win)", pool[sel]))
 
    # cover every digit at least twice, 4 per batch
    by_digit = {d: list(np.where(dig == d)[0]) for d in range(10)}
    for d in range(10):
        if len(by_digit[d]) == 0:
            print(f"note: no image predicted as {d} in the pool")
    cur = 0
    while len(batches) < args.n:
        sel = []
        for _ in range(4):
            for _try in range(10):
                d = cur % 10
                cur += 1
                if by_digit[d]:
                    sel.append(by_digit[d].pop(0) if len(by_digit[d]) > 1 else by_digit[d][0])
                    break
            else:
                sel.append(int(rng.integers(len(pool))))
        batches.append((f"mixed digits {len(batches)}", pool[sel]))
    batches = batches[:args.n]
 
    OUT.mkdir(parents=True, exist_ok=True)
    fin, fhid, fdig = [], [], []
    seen = set()
    sat = zero = tot = 0
    for label, x in batches:
        h, a2, d = forward(q, x)
        fin += [f"{w:08x}" for w in words_in(x)]
        fhid += [f"{w:08x}" for w in words_hid(h)]
        fdig.append("%04x" % sum(int(d[i]) << (4 * i) for i in range(4)))
        seen.update(int(v) for v in d)
        sat += int((h == 127).sum()); zero += int((h == 0).sum()); tot += h.size
        print(f"  {label:42s} digits {list(map(int, d))}  max logit {a2[:, :10].max(axis=1).tolist()}")
    (OUT / "infer_in.hex").write_text("\n".join(fin) + "\n")
    (OUT / "infer_hid.hex").write_text("\n".join(fhid) + "\n")
    (OUT / "infer_dig.hex").write_text("\n".join(fdig) + "\n")
    print(f"digits covered: {sorted(seen)}; hidden values: {zero/tot:.0%} zero (ReLU), {sat/tot:.1%} saturated at 127")
    print(f"wrote {len(batches)} batches to {OUT}  (tb parameter N_BATCH = {len(batches)})")
 
 
if __name__ == "__main__":
    main()
 