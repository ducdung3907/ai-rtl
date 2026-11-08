"""Draw a digit with the mouse; the FPGA reads it.

  python ml/draw_demo.py --port COM6      # v3 bitstream (infer_board_top) on the board
  python ml/draw_demo.py                  # no board: the software model of the board

What happens when you let go of the mouse:
  1. the drawing is turned into a 28x28 MNIST-style image: cropped to the stroke, scaled so the longer
     side is 20 pixels, then placed so its centre of mass sits in the middle (how MNIST was made)
  2. pixels 0..255 -> 0..127, one frame [A6][seq][pixels][checksum] goes to the board (the image goes in
     slot 0, the other 3 slots are blank)
  3. the board runs both layers and replies [A6][seq][digits]; the digit for slot 0 is shown
The PC also runs the same integer model (ref_infer), so you can see that the two always agree; its scores
are drawn as bars. Keys: c or right-click = clear, Enter = predict again.
"""
import argparse
import sys
import time
import tkinter as tk
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

sys.path.append(str(Path(__file__).resolve().parent.parent / "host"))
from infer_frame import FakeInferBoard, ReplyError, build_frame, parse_reply
from ref_infer import load_model, quantize_pixels, requant

CANVAS = 280        # drawing area in screen pixels (10x the 28x28 image)
PEN = 16            # stroke width; after scaling a 200-pixel-tall digit to 20 pixels this is about 2 pixels
CELL = 6            # size of one pixel in the 28x28 preview


def to_mnist(img):
    """PIL 'L' image, white strokes on black -> (28, 28) uint8 like an MNIST digit, or None if empty."""
    a = np.asarray(img)
    ys, xs = np.nonzero(a > 30)
    if len(xs) == 0:
        return None
    crop = img.crop((xs.min(), ys.min(), xs.max() + 1, ys.max() + 1))
    w, h = crop.size
    s = 20.0 / max(w, h)
    crop = crop.resize((max(1, round(w * s)), max(1, round(h * s))), Image.LANCZOS)
    c = np.asarray(crop, dtype=np.float64)
    total = c.sum()
    cy = (c.sum(axis=1) * np.arange(c.shape[0])).sum() / total
    cx = (c.sum(axis=0) * np.arange(c.shape[1])).sum() / total
    out = Image.new("L", (28, 28), 0)
    out.paste(crop, (int(round(14 - cx)), int(round(14 - cy))))
    return np.asarray(out, dtype=np.uint8)


def scores(q, x_q):
    """Integer model on pixels 0..127, (n, 784) -> (n, 10) output-layer scores (the same maths as the FPGA)."""
    acc1 = x_q.astype(np.int64) @ q["W1_q"].astype(np.int64) + q["b1_q"]
    a1 = requant(acc1, q["M1"], q["shift1"]).astype(np.int64)
    return a1 @ q["W2_q"].astype(np.int64) + q["b2_q"]


class Board:
    """One image in, one digit out, through the v3 frame protocol (real board or software model)."""

    def __init__(self, port, baud, q):
        if port == "fake":
            self.ser = FakeInferBoard(lambda imgs: scores(q, imgs.astype(np.int64)).argmax(axis=1))
        else:
            import serial
            self.ser = serial.Serial(port, baudrate=baud, timeout=1.0)
        self.seq = 0

    def classify(self, x_q):
        seq, self.seq = self.seq, (self.seq + 1) & 0x7F
        self.ser.reset_input_buffer()
        t0 = time.perf_counter()
        self.ser.write(build_frame(x_q, seq))
        digit = parse_reply(self.ser.read, seq, n_images=1)[0]
        return digit, time.perf_counter() - t0

    def close(self):
        self.ser.close()


class App:
    def __init__(self, root, board, q, port):
        self.root, self.board, self.q = root, board, q
        self.drawn = self.agreed = 0
        root.title("ai-rtl v3: draw a digit, the FPGA reads it")
        root.configure(bg="#1e1e1e")
        fg, dim = "#f0f0f0", "#9a9a9a"

        left = tk.Frame(root, bg="#1e1e1e")
        left.grid(row=0, column=0, padx=16, pady=16, sticky="n")
        tk.Label(left, text="Draw a digit (0-9)", fg=fg, bg="#1e1e1e", font=("Segoe UI", 13)).pack(anchor="w")
        self.canvas = tk.Canvas(left, width=CANVAS, height=CANVAS, bg="black", highlightthickness=1,
                                highlightbackground="#555", cursor="pencil")
        self.canvas.pack(pady=(6, 8))
        btns = tk.Frame(left, bg="#1e1e1e")
        btns.pack(fill="x")
        tk.Button(btns, text="Clear (c)", command=self.clear, width=12).pack(side="left")
        tk.Button(btns, text="Predict (Enter)", command=self.predict, width=14).pack(side="right")

        mid = tk.Frame(root, bg="#1e1e1e")
        mid.grid(row=0, column=1, padx=8, pady=16, sticky="n")
        tk.Label(mid, text="What the FPGA sees (28x28)", fg=dim, bg="#1e1e1e", font=("Segoe UI", 10)).pack(anchor="w")
        self.preview = tk.Canvas(mid, width=28 * CELL, height=28 * CELL, bg="black", highlightthickness=1,
                                 highlightbackground="#555")
        self.preview.pack(pady=(6, 12))
        self.cells = [[self.preview.create_rectangle(x * CELL, y * CELL, (x + 1) * CELL, (y + 1) * CELL,
                                                     width=0, fill="black") for x in range(28)] for y in range(28)]
        tk.Label(mid, text="FPGA says", fg=dim, bg="#1e1e1e", font=("Segoe UI", 10)).pack(anchor="w")
        self.digit = tk.Label(mid, text="-", fg="#4fc3f7", bg="#1e1e1e", font=("Segoe UI", 64, "bold"))
        self.digit.pack(anchor="w")
        self.info = tk.Label(mid, text="", fg=fg, bg="#1e1e1e", font=("Segoe UI", 10), justify="left")
        self.info.pack(anchor="w")

        right = tk.Frame(root, bg="#1e1e1e")
        right.grid(row=0, column=2, padx=16, pady=16, sticky="n")
        tk.Label(right, text="PC reference scores (same integer model)", fg=dim, bg="#1e1e1e",
                 font=("Segoe UI", 10)).pack(anchor="w")
        self.bars = tk.Canvas(right, width=260, height=10 * 26 + 8, bg="#1e1e1e", highlightthickness=0)
        self.bars.pack(pady=(6, 0))
        self.status = tk.Label(root, text=f"board: {port}", fg=dim, bg="#1e1e1e", font=("Segoe UI", 9))
        self.status.grid(row=1, column=0, columnspan=3, sticky="w", padx=16, pady=(0, 10))

        self.img = Image.new("L", (CANVAS, CANVAS), 0)
        self.pen = ImageDraw.Draw(self.img)
        self.last = None
        self.canvas.bind("<Button-1>", self.down)
        self.canvas.bind("<B1-Motion>", self.move)
        self.canvas.bind("<ButtonRelease-1>", self.up)
        self.canvas.bind("<Button-3>", lambda e: self.clear())
        root.bind("c", lambda e: self.clear())
        root.bind("<Return>", lambda e: self.predict())
        self.draw_bars(None, None)

    # ---- drawing
    def dot(self, x, y):
        r = PEN / 2
        self.canvas.create_oval(x - r, y - r, x + r, y + r, fill="white", outline="white")
        self.pen.ellipse((x - r, y - r, x + r, y + r), fill=255)

    def down(self, e):
        self.last = (e.x, e.y)
        self.dot(e.x, e.y)

    def move(self, e):
        if self.last:
            self.canvas.create_line(*self.last, e.x, e.y, fill="white", width=PEN, capstyle="round")
            self.pen.line((*self.last, e.x, e.y), fill=255, width=PEN)
            self.dot(e.x, e.y)
        self.last = (e.x, e.y)

    def up(self, e):
        self.last = None
        self.predict()

    def clear(self):
        self.canvas.delete("all")
        self.pen.rectangle((0, 0, CANVAS, CANVAS), fill=0)
        self.show_preview(np.zeros((28, 28), np.uint8))
        self.digit.config(text="-", fg="#4fc3f7")
        self.info.config(text="")
        self.draw_bars(None, None)

    # ---- inference
    def predict(self):
        img28 = to_mnist(self.img)
        if img28 is None:
            return
        self.show_preview(img28)
        x_q = quantize_pixels(img28.reshape(1, 784))
        ref = scores(self.q, x_q)[0]
        try:
            d, dt = self.board.classify(x_q)
        except ReplyError as e:
            self.digit.config(text="?", fg="#ef5350")
            self.info.config(text=f"no answer from the board:\n{e}")
            return
        self.drawn += 1
        ok = d == int(ref.argmax())
        self.agreed += ok
        self.digit.config(text=str(d), fg="#4fc3f7" if ok else "#ef5350")
        self.info.config(text=f"round trip {1000 * dt:.1f} ms (frame 3,139 bytes, reply 6)\n"
                              f"PC reference: {int(ref.argmax())} ({'same' if ok else 'DIFFERENT'})\n"
                              f"agreed {self.agreed} of {self.drawn} drawings")
        self.draw_bars(ref, d)

    def show_preview(self, img28):
        for y in range(28):
            for x in range(28):
                v = int(img28[y, x])
                self.preview.itemconfig(self.cells[y][x], fill=f"#{v:02x}{v:02x}{v:02x}")

    def draw_bars(self, ref, d):
        b = self.bars
        b.delete("all")
        top = max(1, int(ref.max())) if ref is not None else 1
        for k in range(10):
            y = 4 + 26 * k
            b.create_text(10, y + 10, text=str(k), fill="#f0f0f0", font=("Segoe UI", 11))
            b.create_rectangle(26, y + 2, 250, y + 18, outline="#333", width=1)
            if ref is not None and ref[k] > 0:
                w = 224 * int(ref[k]) / top
                b.create_rectangle(26, y + 2, 26 + w, y + 18, width=0,
                                   fill="#4fc3f7" if k == d else "#5f6b73")


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", default="fake", help="COM6, /dev/ttyUSB0, or fake (default: software model)")
    ap.add_argument("--baud", type=int, default=1_000_000)
    args = ap.parse_args()

    q = load_model()
    board = Board(args.port, args.baud, q)
    root = tk.Tk()
    App(root, board, q, args.port)
    try:
        root.mainloop()
    finally:
        board.close()
