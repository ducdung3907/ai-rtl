import sys
import numpy as np
from run_jobs import open_port, build_job, parse_reply

N = 4
ser = open_port("COM3", 1000000, 2.0, N)

def board_matmul(A, B):
    """A is r x K, B is K x c (r, c <= 4). Returns the r x c result from the FPGA."""
    A = np.array(A, dtype=np.int8)
    B = np.array(B, dtype=np.int8)
    r, K = A.shape
    c = B.shape[1]
    Ap = np.zeros((N, K), np.int8); Ap[:r, :] = A    
    Bp = np.zeros((K, N), np.int8); Bp[:, :c] = B    
    ser.reset_input_buffer()
    ser.write(build_job(Ap, Bp))
    C = parse_reply(ser.read(4 * N * N), N)
    return C[:r, :c]

tests = [
    ([[2]], [[5]]),                            
    ([[1, 2], [3, 4]], [[5, 6], [7, 8]]),
    ([[1, 2, 3, 4, 5]], [[1], [1], [1], [1], [1]]),  
    ([[-128]], [[-128]]),                          
]
for A, B in tests:
    got = board_matmul(A, B)
    exp = np.array(A, dtype=np.int32) @ np.array(B, dtype=np.int32)
    print("A =", A, " B =", B)
    print("board:\n", got, "\nnumpy:\n", exp, "\n", "OK" if np.array_equal(got, exp) else "MISMATCH", "\n")

ser.close()