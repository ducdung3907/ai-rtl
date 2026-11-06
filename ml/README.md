# int8 MNIST on the systolic array

A 784 → 64 → 10 MLP, trained in float with PyTorch, quantised to int8, and run on the Wukong board by
sending every matrix product to the FPGA over UART. The host does only the bookkeeping (tiling, padding,
requantisation); every multiply-accumulate of both layers runs on the 4×4 array.

## Pipeline

| Step | File | What it does |
| --- | --- | --- |
| 1 | `train_torch.py` | Trains the float model (Adam, cosine decay) and exports weights as `.npz`; checks the numpy forward pass against PyTorch |
| 2 | `quantize.py` | Symmetric per-tensor int8 weights, int32 biases, activation scale from a calibration pass, fixed-point requantisation constants |
| 3 | `ref_infer.py` | Bit-exact integer reference model (what the board must reproduce) |
| 4 | `board_infer.py` | Same network with the matrix products sent to the board (`--port COMx`), or to the software board model (default) |

```bash
pip install -r ml/requirements.txt
python ml/train_torch.py --hidden 64 --epochs 20      # weights/mlp_64_float.npz
python ml/quantize.py                                 # weights/mlp_64_int8.npz
python ml/ref_infer.py                                # int8 accuracy on the validation set
python ml/board_infer.py --check --n 20               # software board model, no hardware
python ml/board_infer.py --port COM6 --check --n 100  # real board, compared with ref_infer
```

## Quantisation

- Input pixels: `x_q = (pixel * 127 + 127) // 255`, scale 1/127.
- Weights: symmetric per tensor, `s_w = max|W| / 127`, clipped to ±127.
- Biases: int32 at scale `s_in · s_w`.
- Hidden activation scale from the maximum over 5,000 training images.
- Requantisation: `clip((acc * M + (1 << (shift - 1))) >> shift, 0, 127)` in 64-bit integers, with `M` in
  [2^14, 2^15); the clip at 0 is the ReLU. The output layer has no requantisation; the class is the argmax of the int32 sums.
- Products are accumulated in int32; the cast to int32 before the matrix product matters (int8 @ int8 overflows in NumPy).

## Results

Validation set = the last 5,000 training images (used for every choice); the test set was used once, for the float model.

| Model | Validation | Test |
| --- | --- | --- |
| float32 (PyTorch) | 97.62% | 97.26% |
| int8 reference (`ref_infer.py`) | 97.64% | – |
| int8 on the board (first 1,000 validation images) | 97.60% | – |

**On the board:** 1,000 images, all 10,000 logits **bit-identical** to `ref_infer.py` (so board accuracy is exactly the reference accuracy).

| | Value |
| --- | --- |
| Time | 293.7 s, 294 ms per image |
| Jobs | 4,750 (19 per batch of 4 images: 16 for layer 1, 3 for layer 2) |
| UART traffic | 25.8 KB per image |

Time is set by the UART link, not by the array. Cost per batch of 4 images is `⌈n_out/4⌉` tile jobs of `3 + 8K` bytes each,
so the first layer dominates. A batch of one image costs the same as a full batch (1.17 s measured), which is why
`--n 1` looks slow.
