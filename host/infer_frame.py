"""Frame protocol for on-chip MNIST inference (4 images per frame).

PC -> FPGA   [START 0xA6] [seq] [payload: 784 steps x 4 bytes] [checksum]
               seq       0..127, echoed in the reply
               payload   step k = pixel k of image 0, 1, 2, 3 (each byte 0..127)
               checksum  sum of the 3136 payload bytes mod 128
FPGA -> PC   OK    [0xA6] [seq] [d0] [d1] [d2] [d3]      d = predicted digit 0..9, one per image
             ERROR [0xE6] [seq]                          checksum mismatch

Every START / reply-header byte has its top bit set; every other byte is 0..127, so a byte with the
top bit set can only mean "a new frame starts here". FrameReceiver is the byte-level state machine the
FPGA controller implements; it is also the software model of the board (FakeInferBoard).
"""
import numpy as np

START = 0xA6
REPLY_OK = 0xA6
REPLY_ERR = 0xE6
N_IMG = 4
N_PIX = 784
PAYLOAD_LEN = N_IMG * N_PIX            # 3136
FRAME_LEN = 1 + 1 + PAYLOAD_LEN + 1    # start + seq + payload + checksum
OK_REPLY_LEN = 2 + N_IMG
ERR_REPLY_LEN = 2


class ReplyError(Exception):
    pass


def checksum(payload):
    return sum(payload) & 0x7F


def build_frame(pixels, seq):
    """pixels: (n, 784) ints 0..127 with n <= 4 (padded with zero images). Returns the bytes to send."""
    pixels = np.asarray(pixels)
    if pixels.ndim != 2 or pixels.shape[1] != N_PIX or not 1 <= pixels.shape[0] <= N_IMG:
        raise ValueError(f"pixels must be (1..{N_IMG}, {N_PIX}), got {pixels.shape}")
    if pixels.min() < 0 or pixels.max() > 127:
        raise ValueError("pixel values must be in 0..127 (top bit is reserved for frame markers)")
    if not 0 <= seq <= 127:
        raise ValueError("seq must be 0..127")
    padded = np.zeros((N_IMG, N_PIX), dtype=np.uint8)
    padded[: pixels.shape[0]] = pixels
    payload = padded.T.tobytes()                      # step order: pixel k of images 0..3, then k + 1, ...
    return bytes([START, seq]) + payload + bytes([checksum(payload)])


def parse_reply(read, expected_seq, n_images=N_IMG):
    """read(n) -> up to n bytes (like serial.Serial.read). Returns the digits of the first n_images images."""
    head = read(2)
    if len(head) < 2:
        raise ReplyError(f"short reply: {len(head)} of 2 header bytes")
    if head[0] == REPLY_ERR:
        raise ReplyError(f"board reported a checksum error (seq {head[1]})")
    if head[0] != REPLY_OK:
        raise ReplyError(f"bad reply header 0x{head[0]:02x}")
    if head[1] != expected_seq:
        raise ReplyError(f"sequence mismatch: got {head[1]}, expected {expected_seq}")
    digits = read(N_IMG)
    if len(digits) < N_IMG:
        raise ReplyError(f"short reply: {len(digits)} of {N_IMG} digit bytes")
    if any(d > 9 for d in digits):
        raise ReplyError(f"digit out of range in reply: {list(digits)}")
    return list(digits[:n_images])


class FrameReceiver:
    """Byte-at-a-time receiver: the model of the FPGA frame parser (WAIT_START, SEQ, PAYLOAD, CHECK).

    classify(images) -> 4 digits, where images is an (4, 784) uint8 array.
    feed(byte) returns the reply bytes produced by that byte (empty most of the time).
    """

    WAIT_START, SEQ, PAYLOAD, CHECK = range(4)

    def __init__(self, classify):
        self.classify = classify
        self.state = self.WAIT_START
        self.aborted_frames = 0

    def feed(self, b):
        top = b & 0x80
        if self.state != self.WAIT_START and top:        # top bit set inside a frame: it was damaged
            self.aborted_frames += 1
            self.state = self.WAIT_START                  # ... and this byte may be a new START
        if self.state == self.WAIT_START:
            if b == START:
                self.state = self.SEQ
            return b""
        if self.state == self.SEQ:
            self.seq = b
            self.buf = bytearray()
            self.sum = 0
            self.state = self.PAYLOAD
            return b""
        if self.state == self.PAYLOAD:
            self.buf.append(b)
            self.sum = (self.sum + b) & 0x7F
            if len(self.buf) == PAYLOAD_LEN:
                self.state = self.CHECK
            return b""
        # CHECK
        self.state = self.WAIT_START
        if b != self.sum:
            return bytes([REPLY_ERR, self.seq])
        images = np.frombuffer(bytes(self.buf), dtype=np.uint8).reshape(N_PIX, N_IMG).T
        digits = self.classify(images)
        return bytes([REPLY_OK, self.seq]) + bytes(int(d) for d in digits)


class FakeInferBoard:
    """Software board with the same write / read / reset_input_buffer interface as FakeBoard."""

    def __init__(self, classify):
        self.rx = FrameReceiver(classify)
        self.reply = b""

    def reset_input_buffer(self):
        self.reply = b""

    def write(self, data):
        for b in data:
            self.reply += self.rx.feed(b)
        return len(data)

    def read(self, n):
        out, self.reply = self.reply[:n], self.reply[n:]
        return out

    def close(self):
        pass

    def flush(self):
        pass