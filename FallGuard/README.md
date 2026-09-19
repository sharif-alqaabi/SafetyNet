# FallGuard iOS

One SwiftUI app. Settings toggle: **This device is the home hub**.

## Hub

1. Put `GoogleService-Info.plist` (Firebase project with Gemini Developer API) in `FallGuard/`.
2. Select your Development Team in Xcode.
3. Open `FallGuard.xcodeproj`, run on a physical iPhone.
4. Settings: address, family number (via backend env), home code.
5. Triple-tap the red **MONITORING** pill to simulate a fall.
6. Live tries `gemini-3.8-live`, then `gemini-3.1-flash-live-preview`.

Guided Access recommended. Cable power. Rear camera aimed at the taped X.

## Family

Same app, toggle hub off. Paste the same home code. Or open `http://<backend>/family/<incidentId>` on a laptop.

Photon iMessages family (and the hub number if set). A cleared fall is a calm check-in note. An urgent fall is a loud alert. Reply **HERE** on that thread to mark on-the-way. No voice notes or calls yet.

## Not a medical device

Demo calls `DEMO_EMERGENCY_NUMBER`. Never real 911.
