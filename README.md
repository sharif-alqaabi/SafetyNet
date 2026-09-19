# FallGuard

Two-iPhone fall response: hub iPhone (rear camera + Gemini Live) coaches the person on the floor first. Family is texted over Photon iMessage — a short check-in if they are cleared, a loud alert if not. Unresponsive, head + blood thinners, can't move, or they ask for an ambulance skip straight to family and last-measure. Relatives who stay silent get a last-measure iMessage to the demo emergency contact.

Not a medical device. Demo contacts a designated number over Photon. Never dials real 911.

## Layout

- `FallGuard/` — SwiftUI iOS app (Hub / Family role toggle)
- `backend/` — incidents, clips, Photon Spectrum iMessage, demo emergency text

## Hub

Rear camera, mic, speaker. Simulate (3-tap status pill) or pose trigger → Gemini Live speaks the NHS tree and calls tools.

## Family

No camera. Pair with the home code. Card + iMessage. Reply HERE on the thread to mark on-the-way.

## Run

1. `cd backend && cp .env.example .env && npm install && npm start`
2. Drop a real `GoogleService-Info.plist` into `FallGuard/FallGuard/`
3. Open `FallGuard/FallGuard.xcodeproj`, set your Team, run on two iPhones (or hub + laptop `/family/:id`)
4. Triple-tap **MONITORING** to simulate a fall

See `FallGuard/README.md` and `backend/README.md`.
