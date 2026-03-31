import socket
import json
import cv2

SOCK_PATH = "/tmp/ledaw_ocr.sock"
CAMERA_NAME = "UVC Camera"
GRID_SIZE = 32

def find_camera(name):
    """Find camera by name. Uses AVFoundation to get native resolution, then matches against OpenCV indices."""
    import AVFoundation
    import CoreMedia

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

        gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
        small = cv2.resize(gray, (GRID_SIZE, GRID_SIZE))

        msg = json.dumps({
            "px": small.tobytes().hex(),
            "w": GRID_SIZE,
            "h": GRID_SIZE,
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
