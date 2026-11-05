import argparse
import time
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn

import data

WEIGHTS_DIR = Path(__file__).resolve().parent / "weights"


def numpy_accuracy(params, X, Y):
    """Forward pass in plain numpy from the exported arrays (checks the export, incl. the transpose)."""
    n_layers = len(params) // 2
    a = X
    for i in range(1, n_layers + 1):
        a = a @ params[f"W{i}"] + params[f"b{i}"]
        if i < n_layers:
            a = np.maximum(a, 0)
    return float(np.mean(a.argmax(axis=1) == Y))


@torch.no_grad()
def torch_accuracy(model, X, Y):
    model.eval()
    return (model(X).argmax(dim=1) == Y).float().mean().item()


def train(hidden=(64,), epochs=20, lr=1e-3, batch_size=128, seed=0, n_val=5000, verbose=True):
    X, Y, X_test, Y_test = data.load_mnist()
    Xt = torch.from_numpy(X[:-n_val]); Yt = torch.from_numpy(Y[:-n_val].astype(np.int64))
    Xv = torch.from_numpy(X[-n_val:]); Yv = torch.from_numpy(Y[-n_val:].astype(np.int64))

    torch.manual_seed(seed)
    sizes = [784, *hidden, 10]
    layers = []
    for i, (n_in, n_out) in enumerate(zip(sizes[:-1], sizes[1:])):
        layers.append(nn.Linear(n_in, n_out))
        if i < len(sizes) - 2:
            layers.append(nn.ReLU())
    model = nn.Sequential(*layers)               # no softmax: CrossEntropyLoss includes it

    opt = torch.optim.Adam(model.parameters(), lr=lr)
    sched = torch.optim.lr_scheduler.CosineAnnealingLR(opt, T_max=epochs)
    loss_fn = nn.CrossEntropyLoss()
    gen = torch.Generator().manual_seed(seed)

    history = []
    for epoch in range(1, epochs + 1):
        model.train()
        perm = torch.randperm(len(Xt), generator=gen)
        total = 0.0
        for start in range(0, len(Xt), batch_size):
            idx = perm[start:start + batch_size]
            opt.zero_grad()
            loss = loss_fn(model(Xt[idx]), Yt[idx])
            loss.backward()
            opt.step()
            total += loss.item() * len(idx)
        sched.step()
        val_acc = torch_accuracy(model, Xv, Yv)
        history.append({"epoch": epoch, "train_loss": total / len(Xt), "val_acc": val_acc})
        if verbose:
            print(f"epoch {epoch:2d}  loss {total / len(Xt):.4f}  val {val_acc:.2%}  lr {sched.get_last_lr()[0]:.5f}")

    return model, history, (Xv, Yv), (X_test, Y_test)


def export(model, path):
    params = {}
    linears = [m for m in model if isinstance(m, nn.Linear)]
    for i, lin in enumerate(linears, start=1):
        params[f"W{i}"] = lin.weight.detach().numpy().T.astype(np.float32).copy()    # (in, out)
        params[f"b{i}"] = lin.bias.detach().numpy()[None, :].astype(np.float32).copy()
    path.parent.mkdir(parents=True, exist_ok=True)
    np.savez(path, **params)
    return params


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--hidden", type=int, nargs="+", default=[64])
    ap.add_argument("--epochs", type=int, default=20)
    ap.add_argument("--lr", type=float, default=1e-3)
    ap.add_argument("--batch", type=int, default=128)
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--test", action="store_true", help="also report test accuracy (once, at the end)")
    args = ap.parse_args()

    t0 = time.perf_counter()
    model, hist, (Xv, Yv), (X_test, Y_test) = train(
        tuple(args.hidden), args.epochs, args.lr, args.batch, args.seed)
    print(f"trained in {time.perf_counter() - t0:.1f} s")

    name = "_".join(str(h) for h in args.hidden)
    path = WEIGHTS_DIR / f"mlp_{name}_float.npz"
    params = export(model, path)
    print("saved", path)

    # check the export: reload and run the numpy forward pass, must match PyTorch
    with np.load(path, allow_pickle=False) as d:
        loaded = {k: d[k] for k in d.files}
    torch_val = hist[-1]["val_acc"]
    np_val = numpy_accuracy(loaded, Xv.numpy(), Yv.numpy())
    print(f"validation: torch {torch_val:.3%}   numpy-from-npz {np_val:.3%}")
    assert abs(torch_val - np_val) <= 0.002, "export mismatch: check the transpose / layout"

    if args.test:
        print(f"test accuracy (float32): {numpy_accuracy(loaded, X_test, Y_test.astype(np.int64)):.3%}")


if __name__ == "__main__":
    main()
