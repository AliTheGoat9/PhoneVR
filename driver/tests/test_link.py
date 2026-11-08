"""Loopback test: acts like the phone. Build and start test_link first, then run this.

    g++ -std=c++17 -I../src test_link.cpp -o test_link -pthread && ./test_link &
    python3 test_link.py
"""
import socket
import struct
import sys
import time

POSE_FMT = "<IHHIQ4f3ff"  # magic, version, flags, seq, time, q[4], gyro[3], ipd
CFG_FMT = "<IHHffHHff"  # magic, version, reserved, tanX, tanY, eyeW, eyeH, hz, ipd

assert struct.calcsize(POSE_FMT) == 52
assert struct.calcsize(CFG_FMT) == 28

rx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
rx.bind(("127.0.0.1", 15001))
rx.settimeout(3)

tx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
for seq, flags in enumerate([0, 1, 2], start=1):
    pkt = struct.pack(POSE_FMT, 0x50525650, 1, flags, seq, 123456789 + seq, 0.0, 0.258819, 0.0, 0.965926, 0.1, 0.2, 0.3, 63.5)
    assert pkt[:4] == b"PVRP", pkt[:4]
    tx.sendto(pkt, ("127.0.0.1", 15555))
    time.sleep(0.01)
tx.sendto(b"garbage", ("127.0.0.1", 15555))  # must be ignored

data, _ = rx.recvfrom(256)
magic, version, _, tx_, ty_, ew, eh, hz, ipd = struct.unpack(CFG_FMT, data)
print("config:", data[:4], version, round(tx_, 2), round(ty_, 2), ew, eh, hz, ipd)
assert data[:4] == b"PVRC" and version == 1 and (ew, eh) == (1496, 1344) and abs(ipd - 63.5) < 1e-4
print("python side OK")
sys.exit(0)
