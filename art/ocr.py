import socket
import time
import os

SOCK_PATH = "/tmp/ledaw_ocr.sock"

# Clean up stale socket
if os.path.exists(SOCK_PATH):
    os.unlink(SOCK_PATH)

server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(SOCK_PATH)
server.listen(1)

print("waiting for zig to connect...")
conn, _ = server.accept()
print("connected")

# Simulate OCR sending text every second
texts = [
    '{"text":"hello world","boxes":[[10,20,200,50]]}',
    '{"text":"twinkle twinkle","boxes":[[5,15,210,55]]}',
    '{"text":"C4 E4 G4","boxes":[[20,30,180,60]]}',
]

i = 0
while True:
    msg = texts[i % len(texts)] + "\n"
    try:
        conn.sendall(msg.encode())
    except BrokenPipeError:
        break
    i += 1
    time.sleep(1)
