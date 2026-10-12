# ParkGuard AI Flutter application

The live app now uses **image-only plate + bay analysis**, with inside = fine
and outside = no fine on the LCD. See [IMAGE_ANALYZER.md](IMAGE_ANALYZER.md) for
the current flow, testing, limits and deployment. Older OCR details below describe
the previous implementation and retained compatibility routes.

Flutter dashboard foundation for an AI smart-parking violation system. Credentials and RTSP URLs must never be embedded in the app.

## Run locally

```powershell
flutter pub get
flutter run -d windows
```

## Azure architecture

```text
Flutter -> Container Apps API -> PostgreSQL / Blob Storage / Azure AI Vision
RTSP -> GPU worker (Frigate + YOLO + Fast-ALPR) -> API event endpoint
```

Live vehicle-number OCR first checks multiple sharp frames with on-device OCR.
Uncertain readings can use GPT-4.1 mini via `POST /api/v1/ocr/foundry`, with
credentials kept on the backend. See [FOUNDRY_OCR.md](FOUNDRY_OCR.md).

In **Cameras**, tap **Mark no-parking bay**, then tap the four outer corners in
order and **Use whole bay**. The entire polygon is the no-parking region; red
strips are not used. Scanning waits for calibration. Movement inside the bay
triggers background OCR while video continues; confirmed numbers go to the
LCD relay and private Azure snapshot storage. A plate observed in the bay is
flagged for review, not automatically fined.

The bay is saved on this Android device per camera URL. Keep the whole bay and
plate visible. Redraw after moving/rotating the camera or changing its lens/view;
an image-aspect-ratio change automatically disables scanning until recalibrated.
Camera movement with the same aspect ratio cannot be detected reliably. A new
IP/URL requires marking that camera's bay again.

Use `scripts/provision-azure.ps1` after choosing the Azure region and globally unique names. It creates the non-GPU foundation. The mobile app calls a protected API, which owns OCR calls and Key Vault access.

Run with a configured API endpoint:

```powershell
flutter run --dart-define=API_BASE_URL=https://YOUR-API.azurecontainerapps.io
```

If C: has limited space, build Android with Gradle and temporary storage on D:

```powershell
.\scripts\build-android-d-drive.ps1
```

## ESP32-CAM live video

Flash the Arduino `CameraWebServer` example, put the ESP32-CAM and the app on
the same Wi-Fi network, then open **Cameras** in ParkGuard. Enter the IP printed
in Arduino Serial Monitor (for example `192.168.1.50`) and select **Start live
video**. The app expands a bare IP to `http://192.168.1.50:81/stream`.

With the small mDNS firmware addition in the setup guide, ParkGuard discovers
the camera and starts the stream automatically, even if its DHCP address
changes.

See [ESP32_CAM_SETUP.md](ESP32_CAM_SETUP.md) for wiring and flashing steps.

The ESP32-CAM supplies video and relays LCD commands. Live motion detection and
local OCR run in the foreground Android app; uncertain OCR and private snapshot
storage use the backend. Backgrounding the app pauses live scanning.

# AI-Parking
