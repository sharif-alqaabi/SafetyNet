import express from "express";
import multer from "multer";
import path from "node:path";
import fs from "node:fs";
import { fileURLToPath } from "node:url";
import {
  initPhoton,
  photonReady,
  pingBoth,
  sendAlert,
  setInboundHandler,
  spectrumApp,
} from "./photon.mjs";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
loadEnv(path.join(__dirname, ".env"));

const PORT = Number(process.env.PORT || 8787);
const PUBLIC_BASE = (process.env.PUBLIC_BASE_URL || `http://127.0.0.1:${PORT}`).replace(/\/$/, "");
const ALLOW_REAL_911 = process.env.ALLOW_REAL_911 === "true";
const HOME_ADDRESS = process.env.HOME_ADDRESS || "14 Oak Street";
const HOME_CODE = process.env.HOME_CODE || "OAK-14";

const incidents = new Map();
const clips = new Map();
const familyInbox = [];
const notifiedIncidents = new Set();
const clipRoot = path.join(__dirname, "public", "clips");
fs.mkdirSync(clipRoot, { recursive: true });
const upload = multer({ storage: multer.memoryStorage(), limits: { fileSize: 8_000_000 } });

const app = express();
app.post("/spectrum/webhook", express.raw({ type: "*/*" }), async (req, res) => {
  const spectrum = spectrumApp() || (await initPhoton());
  if (!spectrum) return res.status(503).json({ error: "Photon is not configured" });
  const result = await spectrum.webhook({ body: req.body, headers: req.headers }, async (_space, message) => {
    const text = message.content?.type === "text" ? message.content.text : "";
    await handleInbound({ from: message.sender?.id || "", text });
  });
  res.status(result.status).set(result.headers).send(Buffer.from(result.body));
});
app.use(express.json({ limit: "2mb" }));
app.use(express.urlencoded({ extended: false }));
app.use("/public", express.static(path.join(__dirname, "public")));

app.get("/health", (req, res) => {
  console.log("GET /health from", req.ip);
  res.json({
    ok: true,
    allowReal911: ALLOW_REAL_911,
    photon: photonReady(),
    channel: "spectrum-imessage",
  });
});

app.post("/incidents", (req, res) => {
  const body = normalizeIncident(req.body);
  console.log("POST /incidents", body.id || "(no id)");
  const existing = incidents.get(body.id);
  const merged = { ...(existing || {}), ...body, updated_at: new Date().toISOString() };
  if (!merged.created_at) merged.created_at = new Date().toISOString();
  incidents.set(merged.id, merged);
  res.json(merged);
});

app.get("/incidents/:id", (req, res) => {
  const incident = incidents.get(req.params.id);
  if (!incident) return res.status(404).json({ error: "not found" });
  res.json(incident);
});

app.get("/homes/:code/latest", (req, res) => {
  const list = [...incidents.values()]
    .filter((item) => (item.home_code || HOME_CODE) === req.params.code)
    .sort((a, b) => String(b.updated_at).localeCompare(String(a.updated_at)));
  res.json({ incident: list[0] || null });
});

app.post("/clips", upload.array("frames"), (req, res) => {
  const incidentId = req.body.incidentId || req.body.incident_id;
  if (!incidentId) return res.status(400).json({ error: "incidentId required" });
  const files = req.files || [];
  const id = `${incidentId}-${Date.now()}`;
  const dir = path.join(clipRoot, id);
  fs.mkdirSync(dir, { recursive: true });
  files.forEach((file, index) => {
    fs.writeFileSync(path.join(dir, `${index}.jpg`), file.buffer);
  });
  clips.set(id, {
    created: Date.now(),
    incidentId,
    count: files.length,
  });
  const url = `${PUBLIC_BASE}/clips/${id}`;
  const incident = incidents.get(incidentId);
  if (incident) {
    incident.clip_url = url;
    incident.live_url = `${PUBLIC_BASE}/family/${incidentId}`;
    incidents.set(incidentId, incident);
  }
  console.log("POST /clips", { id, frames: files.length });
  res.json({ url });
});

app.get("/clips/:id/frame/:n", (req, res) => {
  const file = path.join(clipRoot, req.params.id, `${req.params.n}.jpg`);
  if (!fs.existsSync(file)) return res.status(404).end();
  res.setHeader("Cache-Control", "public, max-age=3600");
  res.type("jpg").send(fs.readFileSync(file));
});

app.get("/clips/:id", (req, res) => {
  const clip = clips.get(req.params.id);
  const dir = path.join(clipRoot, req.params.id);
  if (!clip && !fs.existsSync(dir)) return res.status(404).send("expired");
  const count = clip?.count ?? fs.readdirSync(dir).filter((name) => name.endsWith(".jpg")).length;
  res.type("html").send(clipPlayerPage(req.params.id, count, false));
});

app.get("/homes/:code/inbox", (req, res) => {
  const incidentId = req.query.incident;
  const pending = familyInbox.filter((item) => {
    if (item.home_code !== req.params.code || item.delivered) return false;
    if (incidentId && item.incident_id !== incidentId && item.incidentId !== incidentId) return false;
    return true;
  });
  if (pending.length) console.log("GET inbox", req.params.code, incidentId || "any", pending.length);
  res.json({ messages: pending });
});

app.post("/homes/:code/inbox/ack", (req, res) => {
  const ids = new Set(req.body.ids || []);
  for (const item of familyInbox) {
    if (item.home_code === req.params.code && ids.has(item.id)) item.delivered = true;
  }
  res.json({ ok: "true" });
});

app.post("/notify", async (req, res) => {
  console.log("POST /notify", {
    id: req.body.incidentId || req.body.incident_id || "(no id)",
    urgency: req.body.urgency,
    summary: String(req.body.summary || "").slice(0, 80),
  });
  const { incident_id, incidentId, severity, summary, still_on_floor, stillOnFloor, clip_url, clipURL, live_url, liveURL, urgency } = req.body;
  const id = incidentId || incident_id;
  const resolved = String(urgency || "").toLowerCase() === "resolved" || severity === "low";
  const notifyKey = `${id || "none"}:${resolved ? "resolved" : "urgent"}`;
  if (notifiedIncidents.has(notifyKey)) {
    console.log("POST /notify skipped duplicate", notifyKey);
    return res.json({ ok: "true", link: liveURL || live_url || PUBLIC_BASE, channel: "imessage", duplicate: "true" });
  }
  notifiedIncidents.add(notifyKey);
  const incident = incidents.get(id);
  if (incident) {
    incident.family_notified = true;
    incident.cleared = resolved || incident.cleared;
    incident.severity = severity || incident.severity;
    incident.notes = [incident.notes, summary].filter(Boolean).join(" · ");
    incidents.set(id, incident);
  }
  const link = liveURL || live_url || (id ? `${PUBLIC_BASE}/family/${id}` : PUBLIC_BASE);
  const body = resolved
    ? `${summary || "FallGuard check-in"}\nThey said they are okay after a check. Card if you want to look: ${link}${clipURL || clip_url ? `\nClip: ${clipURL || clip_url}` : ""}`
    : `${summary || "FallGuard alert"}\nStill on floor: ${stillOnFloor ?? still_on_floor}\nWatch the fall and open the card: ${link}\nReply here to talk to Mary — I'll say it to her. Reply HERE if you are on the way.`;
  try {
    const message = await deliverMessage(process.env.FAMILY_NUMBER, {
      body,
      link,
      clipUrl: clipURL || clip_url,
      urgent: !resolved,
    });
    if (message?.skipped) {
      throw new Error("Photon skipped — check FAMILY_NUMBER and Spectrum credentials");
    }
    res.json({
      ok: "true",
      link,
      channel: "imessage",
      messageId: message?.id || "",
    });
  } catch (error) {
    console.error("Notify failed", error.message);
    res.status(502).json({ error: error.message || "Photon notify failed" });
  }
});

app.post("/call", async (req, res) => {
  console.log("POST /call skipped — demo stays on the one family text");
  res.json({ sid: null, to: process.env.FAMILY_NUMBER || "", role: req.body.to_role || req.body.toRole, patch: "false", channel: "imessage", skipped: "true" });
});

app.post("/conference", async (req, res) => {
  const incidentId = req.body.incident_id || req.body.incidentId;
  if (!incidentId) return res.status(400).json({ error: "incident_id required" });
  const room = `fallguard-${incidentId}`;
  const family = process.env.FAMILY_NUMBER;
  const hub = process.env.HUB_PHONE_NUMBER;
  const link = `${PUBLIC_BASE}/family/${incidentId}`;
  const results = await pingBoth({
    family,
    hub,
    link,
    body: `FallGuard: you are being patched to the home speaker. Reply HERE. Card: ${link}`,
  });
  const incident = incidents.get(incidentId);
  if (incident) {
    incident.family_patched = true;
    incident.family_answered = true;
    incidents.set(incidentId, incident);
  }
  res.json({
    ok: "true",
    room,
    channel: "imessage",
    calls: results.map((item) => item?.id).filter(Boolean).join(","),
  });
});

app.get("/family/:id", (req, res) => {
  const incident = incidents.get(req.params.id) || {
    id: req.params.id,
    person_name: "Mary",
    address: HOME_ADDRESS,
    room: "kitchen",
    mechanism: "unknown",
    direction: "unknown",
    impact: [],
    hurt: [],
    hurt_note: "",
    time_down_sec: 0,
    responsive: false,
    severity: "high",
    notes: "Waiting for hub",
    recommend_911: false,
    cleared: false,
  };
  res.type("html").send(familyPage(incident));
});

app.listen(PORT, async () => {
  setInboundHandler(handleInbound);
  await initPhoton();
  console.log(`FallGuard backend on ${PUBLIC_BASE}`);
  console.log(`Notify/call layer: ${photonReady() ? "Photon Spectrum (iMessage)" : "Photon not configured"}`);
  if (ALLOW_REAL_911) console.warn("ALLOW_REAL_911 is true — refuse this for the demo.");
});

function resolveNumber(role) {
  if (role === "emergency_demo") return process.env.DEMO_EMERGENCY_NUMBER;
  return process.env.FAMILY_NUMBER;
}

function fallbackScript(incidentId) {
  const incident = incidents.get(incidentId) || {};
  const name = incident.person_name || "Mary";
  const room = incident.room || "kitchen";
  const responsive = incident.responsive ? "responsive" : "not responding";
  return `FallGuard at ${incident.address || HOME_ADDRESS}. ${name} just fell in the ${room}. They are ${responsive}. Reply HERE if you are on the way. If this were live, call 911 to ${incident.address || HOME_ADDRESS}.`;
}

async function deliverMessage(to, payload) {
  if (!photonReady()) {
    throw new Error("Photon is not configured");
  }
  if (!to) {
    throw new Error("FAMILY_NUMBER is empty");
  }
  return sendAlert({ to, ...payload });
}

async function handleInbound({ from, text, space }) {
  const family = digits(process.env.FAMILY_NUMBER);
  const incoming = digits(from);
  if (!family || !incoming.endsWith(family.slice(-10))) return;
  const latest = [...incidents.values()].sort((a, b) =>
    String(b.updated_at).localeCompare(String(a.updated_at))
  )[0];
  if (!latest) return;
  const body = String(text || "").trim();
    if (!body) return;
    if (/^i('ll| will) tell |got it —/i.test(body)) return;
    const onTheWay = /\bhere\b|on my way|on the way|coming|\d+\s*minutes?\s+out/i.test(body);
  latest.family_answered = latest.family_answered || onTheWay;
  latest.notes = [latest.notes, `Family iMessage: ${body}`].filter(Boolean).join(" · ");
  latest.updated_at = new Date().toISOString();
  incidents.set(latest.id, latest);
  familyInbox.push({
    id: `fam-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`,
    home_code: latest.home_code || HOME_CODE,
    incident_id: latest.id,
    incidentId: latest.id,
    text: body,
    delivered: false,
    at: new Date().toISOString(),
  });
  const name = latest.person_name || "Mary";
  const reply = onTheWay
    ? `Got it — I'll tell ${name} you're on the way.`
    : `I'll tell ${name} now.`;
  try {
    if (space) await space.send(reply);
    else await sendAlert({ to: from, body: reply, urgent: false });
  } catch (error) {
    console.warn("Photon inbound reply failed", error.message);
  }
  console.log("Photon inbound from family", { from, text: body, incident: latest.id });
}

function digits(value) {
  return String(value || "").replace(/\D/g, "");
}

function normalizeIncident(body) {
  return {
    id: body.id || crypto.randomUUID(),
    home_code: body.home_code || body.homeCode || HOME_CODE,
    mechanism: body.mechanism,
    direction: body.direction,
    impact: body.impact || [],
    hurt: body.hurt || [],
    hurt_note: body.hurt_note || body.hurtNote || "",
    room: body.room,
    time_down_sec: body.time_down_sec ?? body.timeDownSec ?? 0,
    responsive: body.responsive ?? false,
    able_to_move: body.able_to_move ?? body.ableToMove ?? null,
    severity: body.severity || "high",
    address: body.address || HOME_ADDRESS,
    notes: body.notes || "",
    person_name: body.person_name || body.personName || "Mary",
    clip_url: body.clip_url || body.clipURL,
    live_url: body.live_url || body.liveURL,
    recommend_911: body.recommend_911 ?? body.recommend911 ?? false,
    asks_ambulance: body.asks_ambulance ?? body.asksAmbulance ?? false,
    cleared: body.cleared ?? false,
    family_notified: body.family_notified ?? body.familyNotified ?? false,
    family_answered: body.family_answered ?? body.familyAnswered ?? false,
    family_patched: body.family_patched ?? body.familyPatched ?? false,
    emergency_demo_called: body.emergency_demo_called ?? body.emergencyDemoCalled ?? false,
    created_at: body.created_at || body.createdAt,
    updated_at: body.updated_at || body.updatedAt,
  };
}

function escapeXml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function familyPage(incident) {
  const impact = Array.isArray(incident.impact) ? incident.impact.join(", ") : incident.impact || "—";
  const hurt = Array.isArray(incident.hurt) ? incident.hurt.join(", ") : incident.hurt || "—";
  const banner = incident.recommend_911 || incident.emergency_demo_called
    ? `<div class="panic">Call 911 — ${escapeXml(incident.address || HOME_ADDRESS)}</div>`
    : incident.cleared
      ? `<div class="ok">They said they are okay after a check. You can look in anytime.</div>`
      : "";
  return `<!doctype html>
<html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>FallGuard family</title>
<style>
  :root { color-scheme: light dark; --bg: #0f1115; --card: #1a1d24; --ink: #f4f1ea; --muted: #9aa3b2; --accent: #c73e3a; }
  body { margin: 0; font-family: "Iowan Old Style", "Palatino Linotype", serif; background: var(--bg); color: var(--ink); }
  main { max-width: 40rem; margin: 0 auto; padding: 1.5rem; }
  h1 { font-size: 2rem; margin: 0 0 .25rem; }
  .muted { color: var(--muted); }
  .card { background: var(--card); border-radius: 1rem; padding: 1rem 1.1rem; margin: 1rem 0; }
  .row { display: flex; gap: 1rem; padding: .35rem 0; }
  .k { width: 8rem; color: var(--muted); }
  .panic { background: #3b1010; color: #ffd4d0; padding: 1rem; border-radius: 1rem; font-weight: 700; }
  .ok { background: #14301c; color: #d4f0dc; padding: 1rem; border-radius: 1rem; }
  a { color: #f0c7a4; }
</style>
<main>
  ${banner}
  <p class="muted">Watching ${escapeXml(incident.person_name || "Mary")} · hub online</p>
  <h1>${escapeXml(incident.person_name || "Mary")} fell</h1>
  <p>${escapeXml(incident.address || HOME_ADDRESS)}</p>
  <div class="card">
    ${row("Mechanism", incident.mechanism)}
    ${row("Direction", incident.direction)}
    ${row("Impact", impact)}
    ${row("Possible hurt", hurt)}
    ${row("Hurt note", incident.hurt_note)}
    ${row("Room", incident.room)}
    ${row("Time down", `${incident.time_down_sec ?? 0}s`)}
    ${row("Responsive", incident.responsive ? "yes" : "no")}
    ${row("Severity", incident.severity)}
    ${row("Notes", incident.notes)}
  </div>
  ${incident.clip_url ? clipEmbed(incident.clip_url) : "<p class=\"muted\">Fall clip is still uploading… refresh in a moment.</p>"}
  <p class="muted">Reply to the iMessage to talk to ${escapeXml(incident.person_name || "Mary")} — FallGuard will say it to her. Not a medical device. If this were live, call 911 to ${escapeXml(incident.address || HOME_ADDRESS)}.</p>
</main>`;
}

function clipEmbed(url) {
  const match = String(url).match(/\/clips\/([^/?#]+)/);
  if (!match) return `<p><a href="${escapeXml(url)}">Watch the fall</a></p>`;
  const clip = clips.get(match[1]);
  const dir = path.join(clipRoot, match[1]);
  const count = clip?.count ?? (fs.existsSync(dir) ? fs.readdirSync(dir).filter((name) => name.endsWith(".jpg")).length : 0);
  if (!count) return `<p><a href="${escapeXml(url)}">Watch the fall</a></p>`;
  return `<div class="card">${clipPlayerPage(match[1], count, true)}</div>`;
}

function clipPlayerPage(id, count, embedded) {
  const frames = Array.from({ length: count }, (_, index) => `/clips/${id}/frame/${index}`);
  const player = `
<style>
  .fg-stage { background: #000; border-radius: 0.8rem; overflow: hidden; }
  .fg-stage img { width: 100%; display: block; aspect-ratio: 16/9; object-fit: contain; background: #000; }
  .fg-bar { display: flex; gap: .6rem; align-items: center; padding: .7rem 0 0; }
  .fg-bar button { background: #c73e3a; color: #fff; border: 0; border-radius: 999px; padding: .45rem .9rem; font-weight: 700; }
  .fg-muted { color: #9aa3b2; font-size: .9rem; }
</style>
<div class="fg-stage"><img id="fall" alt="Fall clip" src="${frames[0] || ""}"></div>
<div class="fg-bar"><button id="play" type="button">Play fall</button><span class="fg-muted" id="clock">0:00</span></div>
<script>
const frames = ${JSON.stringify(frames)};
const img = document.getElementById("fall");
const clock = document.getElementById("clock");
const btn = document.getElementById("play");
let i = 0, timer = null;
function show(n) {
  i = n;
  img.src = frames[n];
  const sec = Math.floor(n / 6);
  clock.textContent = "0:" + String(sec).padStart(2, "0");
}
function play() {
  if (timer) { clearInterval(timer); timer = null; btn.textContent = "Play fall"; return; }
  if (i >= frames.length - 1) show(0);
  btn.textContent = "Pause";
  timer = setInterval(() => {
    if (i >= frames.length - 1) { clearInterval(timer); timer = null; btn.textContent = "Play again"; return; }
    show(i + 1);
  }, 160);
}
btn.onclick = play;
if (${embedded ? "true" : "false"}) setTimeout(play, 400);
</script>`;
  if (embedded) return player;
  return `<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Fall clip</title><body style="margin:0;background:#111;color:#f4f1ea;font-family:system-ui;padding:1rem">${player}</body></html>`;
}

function row(key, value) {
  return `<div class="row"><div class="k">${escapeXml(key)}</div><div>${escapeXml(value || "—")}</div></div>`;
}

function loadEnv(file) {
  if (!fs.existsSync(file)) return;
  for (const line of fs.readFileSync(file, "utf8").split("\n")) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    const idx = trimmed.indexOf("=");
    if (idx < 1) continue;
    const key = trimmed.slice(0, idx).trim();
    const value = trimmed.slice(idx + 1).trim();
    if (!(key in process.env)) process.env[key] = value;
  }
}
