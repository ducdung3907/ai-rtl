import numpy as np
from pathlib import Path
from torchvision import datasets

ROOT = Path(__file__).resolve().parent / "data"

def load_mnist(raw=False):
    train = datasets.MNIST(ROOT, train=True,  download=True)
    test  = datasets.MNIST(ROOT, train=False, download=True)

    X_train = train.data.numpy().reshape(-1, 784)
    X_test  = test.data.numpy().reshape(-1, 784)
    Y_train = train.targets.numpy().astype(np.uint8)
    Y_test  = test.targets.numpy().astype(np.uint8)

    if raw:
        return X_train, Y_train, X_test, Y_test
    return (X_train.astype(np.float32) / 255.0, Y_train,
            X_test.astype(np.float32) / 255.0, Y_test)
