import numpy as np, serial, sys
sys.path.insert(0, "host")
from run_jobs import make_job, build_job
ser = serial.Serial("COM3", 2_000_000, timeout=2)
for trial in range(5):
    A, B = make_job(4, 31, np.random.default_rng(trial))
    exp = (A.astype(np.int32) @ B.astype(np.int32)).astype("<i4").tobytes()
    ser.reset_input_buffer(); ser.write(build_job(A, B))
    got = ser.read(64)
    i = next((k for k in range(min(len(got), 64)) if got[k] != exp[k]), None)
    print(f"trial {trial}: got {len(got)}/64, first difference at byte {i}")
ser.close()