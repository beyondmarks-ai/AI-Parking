# ESP32-CAM setup for ParkGuard

## Hardware

- AI Thinker ESP32-CAM
- USB-to-TTL programmer set to **5 V**
- A stable 5 V supply (weak power causes resets and broken video)

Connect `5V -> 5V`, `GND -> GND`, programmer `TX -> U0R`, and programmer
`RX -> U0T`. Connect `IO0 -> GND` only while uploading.

## Flash the camera

1. Install the ESP32 board package in Arduino IDE.
2. Open **File > Examples > ESP32 > Camera > CameraWebServer**.
3. Select `CAMERA_MODEL_AI_THINKER` and enter the 2.4 GHz Wi-Fi SSID/password.
4. Select **AI Thinker ESP32-CAM**, connect `IO0` to `GND`, and upload.
5. Remove `IO0` from `GND`, press reset, and open Serial Monitor at 115200.
6. Note the printed camera IP, such as `192.168.1.50`.

## Enable automatic discovery

Add this include near the top of the `CameraWebServer` example:

```cpp
#include <ESPmDNS.h>
```

Immediately after `startCameraServer();`, add:

```cpp
if (MDNS.begin("parkguard-cam")) {
  MDNS.addService("parkguard-cam", "tcp", 81);
  MDNS.addServiceTxt("parkguard-cam", "tcp", "path", "/stream");
}
```

Upload the firmware once more. ParkGuard will then discover the
`_parkguard-cam._tcp.local` service whenever the app opens, fill the current
IP address, and start live video. The address can change after a router reboot
without requiring an app update. The **Find automatically** button repeats the
search on demand.

## Connect ParkGuard

1. Put the Android phone or computer on the same Wi-Fi network.
2. Verify `http://192.168.1.50` opens in a browser and starts a stream.
3. In ParkGuard, open **Cameras**, enter `192.168.1.50`, and select
   **Start live video**.

The standard example serves MJPEG at `http://<ip>:81/stream` and still images
at `http://<ip>/capture`. A custom firmware using another port/path can be used
by entering its full MJPEG URL.

## Detection architecture

ESP32-CAM cannot reliably run the parking detector used by ParkGuard. The
recommended flow is:

```text
ESP32-CAM MJPEG -> detection worker (YOLO/tracking) -> ParkGuard API
                 -> Flutter app live video         -> violations database
```

Use 320x240 or 640x480 and 8-12 FPS for a stable first prototype. Reserve the
camera's IP in the Wi-Fi router so the configured URL does not change.

If video does not load, confirm the camera IP in a phone browser, disable AP
isolation/guest Wi-Fi, use a stronger 5 V supply, and keep both devices on the
same subnet.
# Changing camera Wi-Fi from the app

1. Connect the app to the ESP32-CAM and open **Cameras**.
2. Tap **Change camera Wi-Fi**.
3. Enter the new Wi-Fi name and password, then tap **Save and restart**.
4. Connect the phone to that network and tap **Find automatically**.

The credentials are stored on the ESP32-CAM and survive power cycles. If the
network cannot be reached for 20 seconds, connect the phone to the
`ParkGuard-Setup` recovery hotspot using password `parkguard123`, then use
`192.168.4.1` as the camera address.

## Vehicle-number OCR demo

### Using a second phone

Both the phone hosting the hotspot and another phone connected to that hotspot
can use the camera address. The updated build fixes a `Bind failed` error on the
second phone: the advertised gateway is only used as a socket source when it
is one of that phone's own current interface addresses. Other phones use the
normal network route. Install the updated APK on each phone that shows this
error, then tap **Find automatically**. Keep the phone connected to the same
Wi-Fi network as the ESP32-CAM.

### Scan a written number

1. Open **Cameras**, connect the ESP32-CAM, and wait for **Camera ready**.
2. Hold the written number upright in good light, filling most of the live view.
3. Tap **Read vehicle number**. The latest live frame is processed on the phone
   with the bundled Latin-script ML Kit recognizer; no image upload is needed.
4. **Results** shows the captured image, recognized text and any matching plate
   candidates. Compare the text with the page; handwriting may be misread.
5. Tap **Scan another number** to return to the camera and try again.

This reads text for demonstration only. It does not verify a registration,
look up vehicle details, detect a parking violation or issue a fine. Empty OCR
results stay empty; the app does not substitute a sample vehicle number.
