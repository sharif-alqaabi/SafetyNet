# SafetyNet

A two-iPhone fall-response system for people living alone. One iPhone sits in the home as a **hub**, watching with its rear camera. When someone falls, the hub talks to them first, using Gemini Live to walk through a triage script. Family is then notified over iMessage: a calm check-in if the person is fine, a loud alert if they aren't.

> **Not a medical device.** This is a demo. It never dials 911. The "emergency" step sends an iMessage to a designated demo contact.

## How it works

1. The hub detects a possible fall, either from the pose trigger or by triple-tapping the **MONITORING** pill to simulate one.
2. Gemini Live speaks to the person and follows an NHS-style decision tree, calling tools as it goes.
3. The hub records an 8-second clip and posts the incident to the backend.
4. The backend sends iMessages through Photon Spectrum:
   - **Cleared:** a short, calm check-in to family.
   - **Not cleared:** a loud alert to family.
5. Some answers skip the coaching and go straight to family and last-measure: unresponsive, head injury while on blood thinners, can't move, or the person asks for an ambulance.
6. If family stays silent, a last-measure iMessage goes to the demo emergency contact.
7. A family member replying **HERE** on the thread marks the incident as "on the way".

## Repository layout

| Path | What it is |
| --- | --- |
| [`FallGuard/`](FallGuard/) | SwiftUI iOS app (iOS 17+). One app with a Hub / Family role toggle. |
| [`backend/`](backend/) | Node/Express server: incidents, clips, Photon iMessage alerts, family web card. |
| `firebase.json`, `.firebaserc` | Firebase project config (Gemini via Firebase AI Logic). |

## Roles

**Hub**: an iPhone with rear camera, mic and speaker, ideally on cable power in Guided Access, aimed at the area to watch.

**Family**: the same app with the hub toggle off. Enter the home code to see the latest incident card and clip. Without a second iPhone, open `http://<backend>/family/<incidentId>` in a browser.

## Requirements

- Xcode 16+ and a physical iPhone (the hub needs a camera)
- Node.js 18+
- A Firebase project with the Gemini Developer API enabled
- A [Photon](https://app.photon.codes) account with a phone number attached, for iMessage delivery

## Quick start

### 1. Backend

```bash
cd backend
cp .env.example .env
npm install
npm start
```

The server listens on port `8787`. Fill in `.env`:

| Variable | Purpose |
| --- | --- |
| `PORT` | Server port (default `8787`) |
| `PUBLIC_BASE_URL` | Public URL used in links inside iMessages |
| `SPECTRUM_PROJECT_ID`, `SPECTRUM_PROJECT_SECRET` | Photon credentials (Photon → Settings) |
| `SPECTRUM_WEBHOOK_SECRET` | Verifies inbound Photon webhooks |
| `FAMILY_NUMBER` | Family phone, iMessage-capable, E.164 (`+14155550100`) |
| `HUB_PHONE_NUMBER` | Optional: also message the hub's number |
| `DEMO_EMERGENCY_NUMBER` | Demo "emergency" contact that receives the last-measure text |
| `HOME_ADDRESS`, `HOME_CODE` | Address shown in alerts; code family uses to pair |
| `ALLOW_REAL_911` | Must stay `false` |

An iPhone can't reach `127.0.0.1` on your Mac. Use your Mac's LAN IP, or tunnel it:

```bash
cloudflared tunnel --url http://127.0.0.1:8787
```

Set `PUBLIC_BASE_URL` to the tunnel's https URL so card and clip links open from iMessage. For inbound "HERE" replies, register that host plus `/spectrum/webhook` in the Photon dashboard.

### 2. iOS app

1. Copy `FallGuard/FallGuard/GoogleService-Info.plist.example` to `GoogleService-Info.plist` and replace its contents with the real file from your Firebase project.
2. Open `FallGuard/FallGuard.xcodeproj` and set your Development Team.
3. Run on a physical iPhone. In **Settings**, set the API base to your backend and enter the home code.
4. Run a second iPhone with **This device is the home hub** turned off to act as family.
5. On the hub, triple-tap **MONITORING** to simulate a fall.

The Xcode project is generated from `FallGuard/project.yml` ([XcodeGen](https://github.com/yonaskolb/XcodeGen)). If you edit that file, regenerate with `xcodegen`.

## Backend API

| Method | Route | Purpose |
| --- | --- | --- |
| `GET` | `/health` | Liveness check |
| `POST` | `/incidents` | Create an incident |
| `GET` | `/incidents/:id` | Fetch an incident |
| `GET` | `/homes/:code/latest` | Latest incident for a home |
| `POST` | `/clips` | Upload clip frames |
| `GET` | `/clips/:id`, `/clips/:id/frame/:n` | Clip metadata and frames |
| `GET` | `/homes/:code/inbox` | Pending messages for a home |
| `POST` | `/homes/:code/inbox/ack` | Acknowledge inbox messages |
| `POST` | `/notify` | Send the family iMessage |
| `POST` | `/call`, `/conference` | Demo emergency iMessage (never a real call) |
| `GET` | `/family/:id` | Family web card |
| `POST` | `/spectrum/webhook` | Inbound Photon replies |

## Safety notes

- This is a hackathon-grade prototype, not a medical or life-safety product.
- `/call` refuses a `to` of 911, and `ALLOW_REAL_911` must stay `false`.
- Never commit `backend/.env` or `GoogleService-Info.plist`. Both are in `.gitignore`.

## More detail

- [`FallGuard/README.md`](FallGuard/README.md) for the iOS app
- [`backend/README.md`](backend/README.md) for the server and Photon setup
