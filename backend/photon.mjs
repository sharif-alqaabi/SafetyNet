import { spawn } from "node:child_process";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";

let app;
let im;
let inboundStarted = false;
let onInboundText = async () => {};
const spacesByPhone = new Map();

function spectrumProjectId() {
  return process.env.SPECTRUM_PROJECT_ID || process.env.PROJECT_ID || "";
}

function spectrumProjectSecret() {
  return process.env.SPECTRUM_PROJECT_SECRET || process.env.PROJECT_SECRET || "";
}

export function photonReady() {
  return Boolean(spectrumProjectId() && spectrumProjectSecret());
}

export function setInboundHandler(handler) {
  onInboundText = handler;
}

export async function initPhoton() {
  if (!photonReady()) {
    console.log("Photon skipped — set SPECTRUM_PROJECT_ID and SPECTRUM_PROJECT_SECRET");
    return null;
  }
  if (app) return app;

  const { Spectrum } = await import("spectrum-ts");
  const { imessage } = await import("spectrum-ts/providers/imessage");
  const webhookSecret = (process.env.SPECTRUM_WEBHOOK_SECRET || "").trim();
  app = await Spectrum({
    projectId: spectrumProjectId(),
    projectSecret: spectrumProjectSecret(),
    providers: [imessage.config()],
    ...(webhookSecret ? { webhookSecret } : {}),
  });
  im = imessage(app);
  startInboundLoop();
  console.log("Photon Spectrum ready (iMessage text)");
  return app;
}

export function spectrumApp() {
  return app;
}

export async function sendAlert({ to, body, link, clipUrl, urgent = true }) {
  if (!to) throw new Error("No destination number");
  const space = await openDm(to);
  let sent;
  try {
    sent = await space.send(body);
  } catch (error) {
    console.warn("Photon send failed", error.message);
    throw error;
  }
  console.log("Photon sent", { to: phoneKey(to), id: sent?.id || null });
  return { id: sent?.id || null, to, channel: "imessage" };
}

export async function placeVoiceBriefing({ to, spokenScript, urgent = true }) {
  const space = await openDm(to);
  const { effect, imessage } = await import("spectrum-ts/providers/imessage");
  const { voice } = await import("spectrum-ts");
  const heading = urgent
    ? effect(spokenScript, imessage.effect.message.slam)
    : spokenScript;
  const sent = await space.send(heading);
  const note = await synthVoiceNote(spokenScript);
  if (note) {
    try {
      await space.send(
        voice(note.buffer, {
          name: "fallguard-briefing.m4a",
          mimeType: "audio/mp4",
          duration: note.duration,
        })
      );
    } catch (error) {
      console.warn("Photon voice note failed", error.message);
    } finally {
      await fs.rm(note.dir, { recursive: true, force: true }).catch(() => {});
    }
  }
  return {
    sid: sent?.id || `photon-${Date.now()}`,
    to,
    channel: "imessage-voice",
    sip: "Spectrum Voice PSTN uses SIP at sip.spectrum.photon.codes:5061 — briefing is delivered as iMessage + voice note from this server.",
  };
}

export async function pingBoth({ family, hub, body, link }) {
  if (!photonReady()) {
    console.log("Photon patch skipped", { family, hub, body });
    return [];
  }
  const results = [];
  if (family) results.push(await sendAlert({ to: family, body, link, urgent: true }));
  if (hub) results.push(await sendAlert({ to: hub, body, link, urgent: false }));
  return results;
}

async function openDm(to) {
  if (!im) await initPhoton();
  if (!im) throw new Error("Photon is not configured");
  const key = phoneKey(to);
  const existing = spacesByPhone.get(key);
  if (existing) {
    console.log("Photon using inbound thread", { to: key });
    return existing;
  }
  try {
    const user = await im.user(normalizeE164(to));
    return await im.space.create(user);
  } catch (error) {
    console.warn("Photon open DM failed", error.message);
    throw new Error(
      "Photon could not open an iMessage thread. Text the Spectrum line first, then retry."
    );
  }
}

function cacheSpace(from, space) {
  const key = phoneKey(from);
  if (key && space) spacesByPhone.set(key, space);
}

function phoneKey(value) {
  return String(value || "").replace(/\D/g, "").slice(-10);
}

function startInboundLoop() {
  if (!app || inboundStarted) return;
  inboundStarted = true;
  void (async () => {
    try {
      for await (const [space, message] of app.messages) {
        if (message.direction !== "inbound") continue;
        const text =
          message.content?.type === "text"
            ? message.content.text
            : typeof message.content?.text === "string"
              ? message.content.text
              : "";
        const from = message.sender?.id || "";
        if (!text && !from) continue;
        cacheSpace(from, space);
        await onInboundText({ from, text, space, message });
      }
    } catch (error) {
      console.warn("Photon inbound loop ended", error.message);
      inboundStarted = false;
    }
  })();
}

function normalizeE164(value) {
  const raw = String(value || "").trim();
  if (raw.startsWith("+")) return raw;
  const digits = raw.replace(/\D/g, "");
  if (digits.length === 10) return `+1${digits}`;
  if (digits.length === 11 && digits.startsWith("1")) return `+${digits}`;
  return raw.startsWith("+") ? raw : `+${digits}`;
}

async function synthVoiceNote(script) {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), "fallguard-voice-"));
  const aiff = path.join(dir, "note.aiff");
  const m4a = path.join(dir, "note.m4a");
  try {
    await run("say", ["-o", aiff, String(script).slice(0, 800)]);
    await run("afconvert", ["-f", "m4af", "-d", "aac", aiff, m4a]);
    const buffer = await fs.readFile(m4a);
    const words = String(script).trim().split(/\s+/).length;
    return { buffer, dir, duration: Math.max(3, Math.round(words / 2.2)) };
  } catch (error) {
    console.warn("TTS voice note skipped", error.message);
    await fs.rm(dir, { recursive: true, force: true }).catch(() => {});
    return null;
  }
}

function run(cmd, args) {
  return new Promise((resolve, reject) => {
    const child = spawn(cmd, args, { stdio: ["ignore", "ignore", "pipe"] });
    let err = "";
    child.stderr.on("data", (chunk) => {
      err += chunk;
    });
    child.on("error", reject);
    child.on("close", (code) => {
      if (code === 0) resolve();
      else reject(new Error(`${cmd} ${code} ${err}`.trim()));
    });
  });
}

export { normalizeE164 };
