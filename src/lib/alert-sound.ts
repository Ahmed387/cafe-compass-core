// Loud, attention-grabbing alert used by the kitchen display when a new order arrives.
// Uses the Web Audio API so no audio asset/network request is needed.

let ctx: AudioContext | null = null;

function getCtx(): AudioContext | null {
  if (typeof window === "undefined") return null;
  const Ctor =
    window.AudioContext ??
    (window as unknown as { webkitAudioContext?: typeof AudioContext }).webkitAudioContext;
  if (!Ctor) return null;
  if (!ctx) ctx = new Ctor();
  return ctx;
}

/** Must be called from a user gesture once, so browsers allow sound later. */
export async function unlockAlertSound(): Promise<boolean> {
  const audio = getCtx();
  if (!audio) return false;
  try {
    if (audio.state === "suspended") await audio.resume();
    return audio.state === "running";
  } catch {
    return false;
  }
}

function beep(
  audio: AudioContext,
  startAt: number,
  freq: number,
  duration: number,
  volume: number,
) {
  const osc = audio.createOscillator();
  const gain = audio.createGain();
  osc.type = "square";
  osc.frequency.setValueAtTime(freq, startAt);
  gain.gain.setValueAtTime(0, startAt);
  gain.gain.linearRampToValueAtTime(volume, startAt + 0.02);
  gain.gain.setValueAtTime(volume, startAt + duration - 0.05);
  gain.gain.linearRampToValueAtTime(0, startAt + duration);
  osc.connect(gain);
  gain.connect(audio.destination);
  osc.start(startAt);
  osc.stop(startAt + duration + 0.02);
}

/** Plays a strong triple chime; repeats `rounds` times. */
export function playNewOrderAlert(rounds = 2) {
  const audio = getCtx();
  if (!audio) return;
  if (audio.state === "suspended") void audio.resume();
  const t0 = audio.currentTime + 0.02;
  const pattern = [880, 1180, 1480];
  for (let r = 0; r < rounds; r += 1) {
    const base = t0 + r * 0.95;
    pattern.forEach((freq, i) => beep(audio, base + i * 0.22, freq, 0.18, 0.85));
  }
  if (typeof navigator !== "undefined" && "vibrate" in navigator) {
    try {
      navigator.vibrate?.([200, 100, 200, 100, 300]);
    } catch {
      /* ignore */
    }
  }
}
