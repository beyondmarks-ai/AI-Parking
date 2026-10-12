# Verified plate reading

Motion-triggered scanning is on by default. Movement starts a background burst
immediately, without waiting for the vehicle to stop. Local OCR can retry two
seconds after completion for 15 seconds after the latest movement; a static
scene otherwise stays idle. New movement opens/extends the window. No button
press or tab switch is required. Each burst collects up to eight frames over 1.1 seconds at
150 ms intervals and selects up to three distinct sharp frames. Selection and
JPEG cropping run in a background isolate. Sharpness ranks images relative to
one another; it cannot recover missing characters or guarantee legibility.

ML Kit reads the selected frames locally. Digit-bearing text bounds provide a
padded crop for Foundry; if no text can be located, the full selected frame is
sent instead. Two agreeing local frames confirm a number without a Foundry call.
Uncertain readings use the existing GPT-4.1 mini deployment in Azure OpenAI / Foundry.
The model receives the crop independently, without being shown local guesses.

A local and cloud reading must agree, or two distinct cloud frames must agree
when local OCR found nothing. Any conflicting or multiple plate readings remain
unconfirmed. Exact duplicate frames do not count as independent observations.
Agreement is a reliability check, not proof of a correct registration reading.

Unclear scans retry locally within the movement window. Cloud verification requires digit-bearing
text or a recent vehicle detection, is limited to two bursts per encounter, and
bursts are at least 30 seconds apart (each can use up to two image requests).
The empty scene does not trigger cloud requests. A new encounter is inferred
after at least three successful local scans over eight seconds with no digits
and fresh detector observations showing no vehicle. This is a conservative
presence heuristic, not identity tracking; detector mistakes can affect re-arming.
Native OCR errors, a lost stream, or pause do not count as vehicle departure.

Only confirmed plates update Results and the persistent last-number label on
Cameras. Confirmation does not switch tabs or stop the stream. The same
successfully relayed number is suppressed until departure is observed; a
different confirmed number is sent immediately. Failed relay requests can retry
on subsequent confirmations. The automatic-scanning switch pauses OCR without
stopping the preview; Stop live video stops both. Manual Read remains optional
and follows the same confirmation rules and cloud limits.

Disconnect/reconnect and pause cancel pending results. Camera motion alone is
never treated as a parking violation. The confirmed number is sent to the LCD
relay first; existing Azure Vision zone assessment runs afterwards for the exact
plate. A confirmed fine can then update the LCD. A failed assessment invents no fine.

## Deployment

- Existing backend: `https://parkguard-api.mangoflower-ccde483b.centralindia.azurecontainerapps.io`
- Azure OpenAI resource: `guardian-ai-openai-617db5`, resource group `guardian-ai-rg`
- Foundry endpoint: `https://guardian-ai-openai-617db5.openai.azure.com`
- Vision request URL: `https://guardian-ai-openai-617db5.openai.azure.com/openai/deployments/guardian-vision/chat/completions?api-version=2024-10-21`
- Model: `gpt-4.1-mini`; deployment name: `guardian-vision`
- Backend route: `POST /api/v1/ocr/foundry` with a JPEG body
- Server settings: `FOUNDRY_ENDPOINT`, `FOUNDRY_MODEL`, `FOUNDRY_API_KEY`
- Key is a Container Apps secret, never a Flutter build setting.

The backend uses strict JSON output, a 256-token output cap, and high-detail
image input to preserve plate characters. No automatic fallback to Sonnet is used.
The motion/archive update requires the new `ParkGuard-motion-archive.apk` and
the capture-archive backend revision. No model/storage credential goes to the phone.

The endpoint limits images to 4 MB / 8 million pixels, two concurrent requests,
and 30 calls/minute per server process. The existing prototype API has public
ingress; these limits are resource bounds, not user authentication.

Run `scripts/deploy-foundry-ocr.ps1` to build the backend in the existing ACR and
update only ParkGuard. Existing DB/Vision/registry settings are preserved.
Build the phone app with:

```powershell
.\scripts\build-android-d-drive.ps1 -Mode release -ApiBaseUrl 'https://parkguard-api.mangoflower-ccde483b.centralindia.azurecontainerapps.io'
```

`py -3.11 backend/verify_foundry.py <backend-url>` verifies cloud transcription
using a generated sample plate and a blank image. It does not contact the camera
or send to LCD. Without a URL it tests the GPT-4.1 mini deployment directly.

For wiring, camera IO14 must reach controller RX2/GPIO16 with common ground and
the result receiver firmware at 9600 baud. An HTTP `sent` acknowledgment confirms
the camera endpoint accepted the command, not that the physical LCD received it.
The earlier demo firmware still displays a fixed sample at startup; that sample
is not evidence of a successful OCR relay.

The live view supplies the burst: this is app-side capture, not autonomous OCR
on the ESP32. Foundry needs internet access and incurs normal model usage costs.
One camera stream stays mounted across Analyse, Results, and Cameras tabs.
Keep the app in the foreground: backgrounding the app pauses its camera stream
and cancels OCR; returning resumes automatically. Focus and lighting still matter.

## Current live mode

The live OCR flow described above has been replaced by image-only analysis.
See [IMAGE_ANALYZER.md](IMAGE_ANALYZER.md). Legacy routes remain compatible, but
the app now calls `/api/v1/parking/analyze` directly and does not use local OCR.

## Private snapshots

### Virtual no-parking bay

The live app now requires an operator-calibrated four-corner convex bay. Tap
**Mark no-parking bay**, outline the entire outer boundary in order, then save.
The calibration is stored privately on Android per camera URL. The live image
continues underneath the temporary frozen-frame editor. Redraw when the camera
moves; a changed aspect ratio fails closed, but same-aspect view changes cannot
be detected automatically. All four corners must be visible before calibration.

Only motion and image sharpness inside the bay are considered. Local and cloud
OCR receive images with the outside masked; the original supporting JPEG is
archived unmodified. Thus the plate itself must be visible inside the image
polygon. This is an image-region observation, not ground-plane vehicle tracking,
a dwell-time determination or an automatic fine. Vehicle-detector presence uses
the box's bottom centre inside the bay as supplementary evidence, never as the
only trigger. The live path does not call the legacy red-strip assessment route.

The optional `X-Parking-Zone` upload header contains version 1, image aspect ratio
and four normalized points. The backend validates its geometry and aspect ratio,
then saves `parking_zone` and `zone_observation=client_plate_in_bay_needs_review`
as private blob metadata. It does not independently certify vehicle occupancy.
Older clients without zone metadata remain compatible.

Confirmed observations are uploaded in the background to `PUT /api/v1/captures/{uuid}`.
The JPEG is a source frame that supported the confirmed number, not a screenshot
of the phone UI. Azure storage account `pgai617db570`, private container
`plate-snapshots`, holds `{uuid}.jpg` with metadata: plate, UTC capture time,
OCR provider, SHA-256, and `client_ocr_confirmed_not_reviewed` review status.
These are plate observations, not automatic violation records or fines.

The phone queues at most three snapshots in memory and retries temporary failures
up to twice using the same UUID. Duplicate uploads are idempotent; conflicting
content cannot overwrite an existing capture. Failed latest snapshots can retry
on a subsequent confirmation after 30 seconds. The queue is not durable across
app termination; older failed queued items are not guaranteed to retry. The camera
screen reports saved/not-saved status for the latest snapshot. Live video and OCR
do not wait for uploads.

Run `scripts/deploy-capture-archive.ps1` to deploy. The backend receives only a
container-scoped read/create SAS stored as a Container Apps secret; it has no
overwrite/delete/list permission. It expires after 90 days: rerun the script to
renew it before expiry. Existing Foundry and DB settings remain intact.
The credential deployed on 2026-10-12 expires on 2027-01-10 at 07:57 UTC.

There is no public snapshot download/list route or public blob access. Access
saved JPEGs and metadata through authenticated Azure storage tools/portal.
The existing prototype API is public: the upload endpoint has size/dimension,
concurrency, and 12-uploads/minute/process limits, but no user authentication.
Add authenticated device access before exposing this beyond the prototype.
Snapshots persist until an authorized operator deletes them; normal storage
charges apply. No deletion/retention policy is changed automatically.

`py -3.11 backend/verify_capture_archive.py <backend-url>` stores one labeled
synthetic test plate and repeats its upload to check idempotency. No live camera
is used. Keep or remove that test blob via authenticated Azure tools as desired.
