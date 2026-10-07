# ParkGuard AI Flutter application

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

Use `scripts/provision-azure.ps1` after choosing the Azure region and globally unique names. It creates the non-GPU foundation. The mobile app calls a protected API, which owns OCR calls and Key Vault access.

Run with a configured API endpoint:

```powershell
flutter run --dart-define=API_BASE_URL=https://YOUR-API.azurecontainerapps.io
```

# AI-Parking
