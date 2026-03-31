import socket
import os
import json
import cv2
import easyocr

SOCK_PATH = "/tmp/ledaw_ocr.sock"

reader = easyocr.Reader(['en'], gpu=True)

CAMERA_NAME = "UVC Camera"

def find_camera(name):
    """Find camera by name. Uses AVFoundation to get native resolution, then matches against OpenCV indices."""
    import AVFoundation
    import CoreMedia

    # Find target device's native resolution via AVFoundation
    target_res = None
    devices = AVFoundation.AVCaptureDevice.devicesWithMediaType_(AVFoundation.AVMediaTypeVideo)
    for d in devices:
        dev_name = d.localizedName()
        dims = CoreMedia.CMVideoFormatDescriptionGetDimensions(d.activeFormat().formatDescription())
        print(f"AVFoundation: {dev_name} ({dims.width}x{dims.height})")
        if name in dev_name:
            target_res = (dims.width, dims.height)

    if target_res is None:
        raise RuntimeError(f"Camera '{name}' not found")

    # OpenCV's AVFoundation backend uses different indices than the API.
    # Match by resolution.
    for i in range(len(devices)):
        cap = cv2.VideoCapture(i, cv2.CAP_AVFOUNDATION)
        if not cap.isOpened():
            break
        ret, frame = cap.read()
        if ret and (frame.shape[1], frame.shape[0]) == target_res:
            print(f"Using OpenCV index {i} ({frame.shape[1]}x{frame.shape[0]}) for {name}")
            return cap
        cap.release()

    raise RuntimeError(f"Camera '{name}' not found via OpenCV")

cap = find_camera(CAMERA_NAME)

print("connecting to zig...")
conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
conn.connect(SOCK_PATH)
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
