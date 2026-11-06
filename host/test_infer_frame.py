"""Tests for infer_frame.py (no hardware, no model): python host/test_infer_frame.py"""
import numpy as np

from infer_frame import (FRAME_LEN, N_IMG, N_PIX, PAYLOAD_LEN, REPLY_ERR, REPLY_OK, START,
                         FakeInferBoard, FrameReceiver, ReplyError, build_frame, checksum, parse_reply)

rng = np.random.default_rng(0)


def toy_classify(images):
    """Stand-in classifier: digit = (sum of the image's pixels) mod 10. Deterministic, depends on every pixel."""
    return [int(images[i].astype(int).sum() % 10) for i in range(N_IMG)]


def expect(pixels):
    p = np.zeros((N_IMG, N_PIX), np.uint8)
    p[: len(pixels)] = pixels
    return toy_classify(p)


def rand_pixels(n=4):
    return rng.integers(0, 128, size=(n, N_PIX), dtype=np.uint8)


def roundtrip(board, pixels, seq):
    board.reset_input_buffer()
    board.write(build_frame(pixels, seq))
    return parse_reply(board.read, seq, len(pixels))


def test_layout():
    px = rand_pixels()
    f = build_frame(px, 9)
    assert len(f) == FRAME_LEN == PAYLOAD_LEN + 3
    assert f[0] == START and f[1] == 9
    for k in (0, 1, 500, 783):                                   # step order: pixel k of image 0..3
        assert list(f[2 + 4 * k: 6 + 4 * k]) == [px[i][k] for i in range(4)]
    assert f[-1] == checksum(f[2:-1]) == int(px.astype(int).sum() % 128)
    assert all(b < 128 for b in f[1:])                             # only the start byte has the top bit set


def test_roundtrip_and_partial_batch():
    board = FakeInferBoard(toy_classify)
    for n in (4, 3, 1):
        px = rand_pixels(n)
        assert roundtrip(board, px, 5) == expect(px)[:n]


def test_seq_wraps_and_is_echoed():
    board = FakeInferBoard(toy_classify)
    for seq in (0, 1, 126, 127):
        assert roundtrip(board, rand_pixels(), seq) is not None


def test_bad_checksum_gives_error_reply():
    board = FakeInferBoard(toy_classify)
    f = bytearray(build_frame(rand_pixels(), 7))
    f[-1] = (f[-1] + 1) & 0x7F
    board.write(bytes(f))
    assert board.read(2) == bytes([REPLY_ERR, 7])


def test_corrupted_payload_is_caught():
    board = FakeInferBoard(toy_classify)
    f = bytearray(build_frame(rand_pixels(), 3))
    f[100] = (f[100] + 1) & 0x7F
    board.write(bytes(f))
    assert board.read(2) == bytes([REPLY_ERR, 3])


def test_junk_before_start_is_ignored():
    board = FakeInferBoard(toy_classify)
    px = rand_pixels()
    board.write(bytes([0x00, 0x55, 0x7F, 0xA5, 0xFF, 0x12]))      # includes top-bit bytes that are not START
    board.write(build_frame(px, 2))
    assert parse_reply(board.read, 2) == expect(px)


def test_dropped_payload_byte_resyncs_on_next_frame():
    board = FakeInferBoard(toy_classify)
    f1 = bytearray(build_frame(rand_pixels(), 10))
    del f1[1000]                                                    # one byte lost on the wire
    px2 = rand_pixels()
    board.write(bytes(f1))
    board.write(build_frame(px2, 11))                               # the next START (top bit) aborts frame 1
    assert board.rx.aborted_frames == 1
    assert parse_reply(board.read, 11) == expect(px2)               # no reply for frame 1, correct reply for frame 2


def test_extra_payload_byte_gives_error_then_recovers():
    board = FakeInferBoard(toy_classify)
    f1 = bytearray(build_frame(rand_pixels(), 20))
    f1.insert(1000, 17)                                             # one extra byte
    board.write(bytes(f1))
    assert board.read(2) == bytes([REPLY_ERR, 20])
    px = rand_pixels()
    assert roundtrip(board, px, 21) == expect(px)


def test_stray_top_bit_byte_aborts_frame_and_next_frame_works():
    board = FakeInferBoard(toy_classify)
    f = bytearray(build_frame(rand_pixels(), 30))
    f[50] = 0xC3                                                    # corrupted into a top-bit byte
    board.write(bytes(f))
    assert board.read(10) == b""                                    # aborted, no reply
    px = rand_pixels()
    assert roundtrip(board, px, 31) == expect(px)


def test_back_to_back_frames():
    board = FakeInferBoard(toy_classify)
    pxs = [rand_pixels() for _ in range(5)]
    board.write(b"".join(build_frame(p, s) for s, p in enumerate(pxs)))
    for s, p in enumerate(pxs):
        assert parse_reply(board.read, s) == expect(p)


def test_parse_reply_errors():
    def reader(data):
        buf = bytearray(data)
        def read(n):
            out = bytes(buf[:n]); del buf[:n]; return out
        return read
    for data, why in ((b"", "short"), (bytes([REPLY_OK]), "short"), (bytes([REPLY_OK, 3, 1, 2]), "short"),
                      (bytes([0x77, 3, 1, 2, 3, 4]), "header"), (bytes([REPLY_OK, 4, 1, 2, 3, 4]), "sequence"),
                      (bytes([REPLY_OK, 3, 1, 2, 3, 10]), "range"), (bytes([REPLY_ERR, 3]), "checksum")):
        try:
            parse_reply(reader(data), 3)
        except ReplyError as e:
            assert why in str(e), (data, str(e))
        else:
            raise AssertionError(f"no error for {data!r}")


def test_input_validation():
    for bad in (np.full((4, N_PIX), 128), np.full((4, N_PIX), -1), np.zeros((5, N_PIX)), np.zeros((4, 700))):
        try:
            build_frame(bad, 0)
        except ValueError:
            continue
        raise AssertionError("accepted bad input")
    try:
        build_frame(rand_pixels(), 128)
    except ValueError:
        pass
    else:
        raise AssertionError("accepted seq 128")


if __name__ == "__main__":
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_")]
    for t in tests:
        t()
        print("ok  ", t.__name__)
    print(f"{len(tests)} tests passed")