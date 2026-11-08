import socket
import struct
import sys

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.bind(("0.0.0.0", 5555))
sock.settimeout(5)
print("Listening on 0.0.0.0:5555 for 5 seconds...")
try:
    data, addr = sock.recvfrom(1024)
    print(f"Received {len(data)} bytes from {addr}!")
    if len(data) >= 52:
        magic, ver, flags, seq, ts, qx, qy, qz, qw, gx, gy, gz, ipd = struct.unpack("<IHHIQ4f3ff", data[:52])
        print(f"Magic: {hex(magic)}, Ver: {ver}, Flags: {flags}, Seq: {seq}")
        print(f"Quat: ({qx:.3f}, {qy:.3f}, {qz:.3f}, {qw:.3f}), IPD: {ipd:.1f}")
except socket.timeout:
    print("Timeout: no packets received within 5 seconds.")
