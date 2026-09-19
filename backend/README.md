# FallGuard backend

Tiny Express server: incidents, 8s clip URLs, Photon Spectrum iMessage alerts, family HTML card.

Photon is text-only for now: family and the demo emergency contact get an iMessage (loud for urgent). No voice notes or PSTN calls. This server does not dial 911.

```bash
cd backend
cp .env.example .env
# SPECTRUM_PROJECT_ID / SPECTRUM_PROJECT_SECRET come from Photon → Settings
# FAMILY_NUMBER must be an iMessage-capable phone (E.164, e.g. +14155550100)
npm install
npm start
```

Photon will not enroll iMessage until a phone is on the Photon account (`account_phone_missing`). Add one from the avatar menu at [app.photon.codes](https://app.photon.codes), then refresh Get started.

The iPhone cannot use `127.0.0.1`. Set FallGuard Settings → API base to `http://YOUR_MAC_LAN_IP:8787`, or tunnel:

```bash
cloudflared tunnel --url http://127.0.0.1:8787
```

Point `PUBLIC_BASE_URL` at the https URL so card/clip links work in iMessage. Register that same host plus `/spectrum/webhook` in the Photon dashboard if you want inbound "HERE / on my way" replies.

`ALLOW_REAL_911` must stay `false`. `/call` is an iMessage to `FAMILY_NUMBER` or `DEMO_EMERGENCY_NUMBER` and refuses a `to` of 911.

Family laptop fallback: `GET /family/:id`.
