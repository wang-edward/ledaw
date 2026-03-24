import socket
import os
import json
import cv2
import easyocr

SOCK_PATH = "/tmp/ledaw_ocr.sock"

if os.path.exists(SOCK_PATH):
    os.unlink(SOCK_PATH)

server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(SOCK_PATH)
server.listen(1)

reader = easyocr.Reader(['en'], gpu=False)
cap = cv2.VideoCapture(0)

print("waiting for zig to connect...")
conn, _ = server.accept()
print("connected")

try:
    while True:
        ret, frame = cap.read()
        if not ret:
            continue

        result = reader.readtext(frame)

        boxes = []
        texts = []
        for (bbox, text, conf) in result:
            # bbox = [[x1,y1],[x2,y2],[x3,y3],[x4,y4]]
            x_min = int(min(p[0] for p in bbox))
            y_min = int(min(p[1] for p in bbox))
            x_max = int(max(p[0] for p in bbox))
            y_max = int(max(p[1] for p in bbox))
            boxes.append([x_min, y_min, x_max, y_max])
            texts.append(text)

        msg = json.dumps({
            "text": " ".join(texts),
            "boxes": boxes,
            "frame_w": frame.shape[1],
            "frame_h": frame.shape[0],
        }) + "\n"

        try:
            conn.sendall(msg.encode())
        except BrokenPipeError:
            break

except KeyboardInterrupt:
    pass
finally:
    cap.release()
    conn.close()
    server.close()
    if os.path.exists(SOCK_PATH):
        os.unlink(SOCK_PATH)
