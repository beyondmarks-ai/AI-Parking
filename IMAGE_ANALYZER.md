# Image-only parking demo

The active Android live-camera path now uses GPT-4.1 mini in Azure directly:
`ImageParkingAnalyzer` -> `POST /api/v1/parking/analyze`. It does not call ML Kit,
the legacy OCR endpoints, or the local TFLite detector. Legacy modules/tests are
retained for compatibility, not used by live scanning.

The app chooses one sharp original full frame from a 650 ms burst. The backend
validates the saved bay and sends that original plus a thin yellow-boundary
reference image to the existing `guardian-vision` deployment. Outside pixels
remain visible. No local reading or previous plate is given to the model.

For one visible vehicle (including a toy car with an attached handwritten plate):

- Clear overlap of its body with the bay interior: plate + fine.
- Entire vehicle clearly outside the bay: plate + no fine.
- Unreadable plate, ambiguous boundary, multiple vehicles, or unclear view: no
  new LCD decision. Empty scene is not reported as an outside/no-fine vehicle.

`PARKING_FINE_AMOUNT` is a backend setting, default `500` rupees. This implements
the user's prototype display rule, not a legally issued fine. It does not infer
dwell time, legal restrictions, registration validity or vehicle ownership.
The LCD retains its previous result when the latest view is uncertain; the app
reports that uncertainty. Check the app before treating an old LCD result as current.

Motion anywhere in the camera view can request a check, with at least 8 seconds
between starts and 2 seconds after completion. Still scenes are checked every
30 seconds. Errors back off 30 seconds. Checks stop when automatic scanning is
off or the app is backgrounded; video continues while checks/uploads run.
Internet and billed Azure image inference are required. No two-attempt lockout.

LCD deduplication includes plate, position and amount, so the same plate moving
outside updates to `NO FINE`. Firmware `Esp32LcdHello` prints only the plate on
row 1 and `Fine Rs <amount>` or `NO FINE` on row 2. Startup no longer displays a
fake plate. Camera HTTP acceptance still does not prove a physical LCD update.

Confirmed inside-bay violations also play a short buzzer on the Android phone,
using media volume. This happens independently of LCD delivery. The same plate
does not buzz again until it is observed outside, the scene is confirmed empty,
or the camera/bay is reloaded. Uncertain and outside observations stay silent.
The alert follows the existing image-analysis timing and requires a confirmed
plate and bay position; it is not an instantaneous motion alarm.

Original snapshots retain bay, plate and fine metadata in private Azure storage.
The optional archive headers are `X-Parking-Decision` (`inside`/`outside`) and
`X-Fine-Amount`; inconsistent pairs are rejected. Records carry
`prototype_display_decision_not_legal_notice`. No public downloads or retention
changes were added. The existing prototype API still needs authenticated device
access before production use.

Calibration is preserved per camera URL. Redraw after moving the camera; a changed
aspect ratio disables scanning. Same-aspect camera movement cannot be detected.

## Verification

`flutter test`, `flutter analyze`, and (from `backend`)
`py -3.11 -m unittest test_parking_analyzer test_capture_archive test_foundry_ocr`.

`py -3.11 backend/verify_parking_analyzer.py <backend-url>` tests generated car
images inside/outside and an empty scene; it never sends to the LCD or archives.
Live ADB testing must be announced before opening the camera/capturing.

Deployment image: `pgai617db570.azurecr.io/parkguard-api:image-analyzer-20261012-v1`.
Existing Foundry/DB/private storage credentials are retained; no app-side keys.

Following official OpenAI documentation, the response has a strict schema and
refusals/truncation fail closed. Schema compliance is not proof of visual accuracy:
small/rotated text and precise spatial reasoning can still fail.

- https://developers.openai.com/api/docs/guides/structured-outputs
- https://developers.openai.com/api/docs/guides/images-vision#limitations
