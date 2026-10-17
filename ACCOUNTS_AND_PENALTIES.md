# Accounts, penalty evidence and notifications

ParkGuard starts at a sign-in screen. New users create an account with their name,
email, password and vehicle registration. A normalized vehicle number belongs to
one account; users can register additional vehicles from their account screen.
Accounts use self-declared vehicle numbers in this demonstration.

The configured administrator signs in through the same screen. Administrators
retain camera discovery, live video, bay calibration, image analysis, the LCD
relay and phone buzzer. The dashboard icon in the header opens registered users,
their names and vehicles, penalty evidence, unpaid totals and demo payment status.
Ordinary users cannot access the camera/admin APIs or other accounts' evidence.

Keep the operator app scanning to generate detections. The ESP32 supplies the
image; the server validates its model's plate/inside-bay decision and atomically
stores a penalty and JPEG evidence. It matches the plate against registered
accounts. Unknown vehicles remain visible to administrators as unregistered.
Repeated observations of the same vehicle in one camera do not issue new
penalties until an outside/empty observation ends the encounter. Older frames
cannot overwrite a more recent encounter state. Camera addresses identify the
camera; changing an address begins a new monitoring source.

## User experience

The user's inbox shows only their vehicle's penalties, amount, detection time,
image and unread status. Opening a notification opens its penalty details.
The **Pay … — demo** button asks for confirmation and produces a demo receipt.
No payment provider is contacted, no bank details are requested, and no money is
collected. Repeated taps/retries return the same receipt. Server-side ownership
checks apply to payment, evidence and read-status operations.

## Android notifications

Firebase project `guardian-ai-617db5` contains Android app
`com.aiparking.parking_violation_app`. Grant notification permission when prompted.
An outbox in PostgreSQL sends high-priority FCM data messages to the matched
owner's devices. This works when the user's UI is closed, subject to Android's
normal network/battery restrictions (force-stopped apps cannot receive FCM until
reopened). The service checks the currently signed-in owner before showing the
notification. The notification contains no image or plate on the lock screen;
authenticated penalty details display the evidence after opening.

Sessions are random bearer tokens stored as SHA-256 hashes on the server and
encrypted with Android Keystore on the phone. Passwords use salted scrypt hashes.
Sign-out revokes its session and associated device tokens. A refreshed FCM token
is registered on app start/sign-in as well as Firebase's token callback.
The inbox persists independently of push delivery, and refreshes while open.

## Deployment

`scripts/deploy-account-portal.ps1` builds and updates the existing Azure API.
It takes administrator email/password and a local FCM service-account credential
file. Only the password hash and FCM credential are placed in Container Apps
secrets. Never commit the credential file. A minimum of one replica keeps the
outbox worker running. The Android Firebase config is public app configuration,
not the server's messaging credential.

The schema migration adds `portal_*` tables without deleting existing data.
Legacy camera, archive, analysis and review APIs now require an administrator's
bearer token. Install the account-enabled APK together with the backend update.
`BOOTSTRAP_ADMIN_EMAIL` and `BOOTSTRAP_ADMIN_HASH` insert the initial admin only
when its email does not already exist; they do not reset existing accounts.

## Verification

Run `flutter test --no-pub` and `flutter analyze --no-pub`.
Backend tests run with `backend/.venv/Scripts/python -m unittest
test_account_portal test_parking_analyzer test_capture_archive test_foundry_ocr`
from `backend`. Set `PORTAL_TEST_DATABASE_URL` to an isolated test PostgreSQL
database; tests create and drop their own randomly named schemas. They cover
account isolation, role enforcement, private evidence, duplicate detection,
out-of-order observations, atomic demo receipts, logout and shared-phone push
token reassignment. Do not point the test variable at a production database.
