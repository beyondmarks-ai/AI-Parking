Based on flutter_mjpeg 2.0.4 (https://github.com/mylisabox/flutter_mjpeg).
Original license retained in LICENSE.

Adds optional pauseWhenHidden (default true). ParkGuard sets it false because
scrolling the preview away otherwise disposes and reuses the same external
HTTP client and can create overlapping requests to a single-client ESP32
stream server. Leaving the camera page and Stop live video still dispose the
player; the owning view also closes its HTTP client.

Extends the SDK upper bound to Dart 4 for the app's Dart 3 SDK.
