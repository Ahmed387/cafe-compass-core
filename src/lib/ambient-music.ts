/**
 * An original, slow 1940s "jazz noir" groove generated live with the Web Audio API:
 * a walking upright bass, soft piano chords, brushes on the snare, a lazy muted
 * sax line, a little vinyl crackle and a smoky room reverb. Nothing is downloaded
 * and there is no licensed recording behind it.
 */

const BPM = 68;
const BEAT = 60 / BPM;
const SWING = 0.62; // the off-beat eighth lands late, like a lazy swing

// C minor noir changes, one bar each: Cm9 | Fm9 | Dm7b5 | G7b9
const BARS = [
  { root: 36, chord: [51, 55, 58, 62], walk: [36, 39, 43, 44] },
  { root: 41, chord: [51, 56, 60, 63], walk: [41, 44, 48, 49] },
  { root: 38, chord: [50, 53, 56, 60], walk: [38, 41, 44, 42] },
  { root: 43, chord: [49, 53, 56, 59], walk: [43, 47, 50, 37] },
];
// C minor blues scale for the sax, around the middle of its range.
const SAX_NOTES = [60, 63, 65, 66, 67, 70, 72, 75];

const hz = (midi: number) => 440 * 2 ** ((midi - 69) / 12);
const pick = <T,>(list: T[]) => list[Math.floor(Math.random() * list.length)]!;

export class AmbientMusic {
  private ctx: AudioContext | null = null;
  private master: GainNode | null = null;
  private room: ConvolverNode | null = null;
  private noise: AudioBuffer | null = null;
  private crackle: AudioBufferSourceNode | null = null;
  private timer: number | null = null;
  private suspendTimer: number | null = null;
  private nextBarTime = 0;
  private bar = 0;
  private volume = 0.5;

  get running() {
    return this.ctx?.state === "running" && this.timer !== null;
  }

  async start() {
    if (this.running) return;
    if (!this.ctx) this.build();
    const ctx = this.ctx!;
    if (this.suspendTimer !== null) window.clearTimeout(this.suspendTimer);
    this.suspendTimer = null;
    await ctx.resume();
    this.master!.gain.setTargetAtTime(this.volume, ctx.currentTime, 1.2);
    this.startCrackle();
    this.nextBarTime = ctx.currentTime + 0.2;
    // Look-ahead scheduler: queue every bar a little before it is due.
    this.timer = window.setInterval(() => this.schedule(), 200);
    this.schedule();
  }

  stop() {
    if (this.timer !== null) window.clearInterval(this.timer);
    this.timer = null;
    this.crackle?.stop();
    this.crackle = null;
    if (this.ctx && this.master) {
      this.master.gain.setTargetAtTime(0, this.ctx.currentTime, 0.4);
      const ctx = this.ctx;
      this.suspendTimer = window.setTimeout(() => void ctx.suspend(), 1500);
    }
  }

  setMuted(muted: boolean) {
    if (!this.ctx || !this.master) return;
    this.master.gain.setTargetAtTime(muted ? 0 : this.volume, this.ctx.currentTime, 0.3);
  }

  dispose() {
    this.stop();
    void this.ctx?.close();
    this.ctx = null;
  }

  private build() {
    const ctx = new AudioContext();
    const master = ctx.createGain();
    master.gain.value = 0;
    const warmth = ctx.createBiquadFilter();
    warmth.type = "lowpass";
    warmth.frequency.value = 5200;
    master.connect(warmth).connect(ctx.destination);

    // A dark, smoky room: noise that decays over ~2.6s as the impulse response.
    const length = Math.floor(ctx.sampleRate * 2.6);
    const impulse = ctx.createBuffer(2, length, ctx.sampleRate);
    for (let ch = 0; ch < 2; ch += 1) {
      const data = impulse.getChannelData(ch);
      for (let i = 0; i < length; i += 1) data[i] = (Math.random() * 2 - 1) * (1 - i / length) ** 3;
    }
    const room = ctx.createConvolver();
    room.buffer = impulse;
    const roomLevel = ctx.createGain();
    roomLevel.gain.value = 0.35;
    room.connect(roomLevel).connect(master);

    const noise = ctx.createBuffer(1, ctx.sampleRate * 2, ctx.sampleRate);
    const nd = noise.getChannelData(0);
    for (let i = 0; i < nd.length; i += 1) nd[i] = Math.random() * 2 - 1;

    this.ctx = ctx;
    this.master = master;
    this.room = room;
    this.noise = noise;
  }

  private schedule() {
    const ctx = this.ctx!;
    while (this.nextBarTime < ctx.currentTime + 1.5) {
      this.playBar(this.nextBarTime, BARS[this.bar % BARS.length]!, this.bar);
      this.nextBarTime += BEAT * 4;
      this.bar += 1;
    }
  }

  private playBar(t: number, bar: (typeof BARS)[number], index: number) {
    // Walking bass on every beat.
    bar.walk.forEach((note, beat) => this.bass(t + beat * BEAT, note));
    // Piano: a soft chord on beat 1, a lighter stab on the swung "and" of 2.
    this.piano(t, bar.chord, 0.05, BEAT * 3);
    if (index % 2 === 1) this.piano(t + BEAT * (1 + SWING), bar.chord, 0.03, BEAT * 1.2);
    // Brushes: a swish on 2 and 4, a light tap on the swung eighths.
    for (let beat = 0; beat < 4; beat += 1) {
      const at = t + beat * BEAT;
      if (beat % 2 === 1) this.brush(at, 0.09, 0.22);
      this.brush(at + BEAT * SWING, 0.025, 0.06);
    }
    // The sax answers every other bar, so there is room to breathe.
    if (index % 2 === 0) this.saxPhrase(t + BEAT * 0.5);
  }

  private bass(t: number, note: number) {
    const ctx = this.ctx!;
    const osc = ctx.createOscillator();
    osc.type = "triangle";
    osc.frequency.value = hz(note);
    const tone = ctx.createBiquadFilter();
    tone.type = "lowpass";
    tone.frequency.value = 420;
    const amp = ctx.createGain();
    amp.gain.setValueAtTime(0, t);
    amp.gain.linearRampToValueAtTime(0.32, t + 0.015);
    amp.gain.exponentialRampToValueAtTime(0.0001, t + BEAT * 0.95);
    osc.connect(tone).connect(amp).connect(this.master!);
    osc.start(t);
    osc.stop(t + BEAT);
  }

  private piano(t: number, notes: number[], level: number, length: number) {
    const ctx = this.ctx!;
    notes.forEach((note, i) => {
      const at = t + i * 0.012; // a tiny roll, like fingers landing
      const osc = ctx.createOscillator();
      osc.type = "sine";
      osc.frequency.value = hz(note);
      const overtone = ctx.createOscillator();
      overtone.type = "sine";
      overtone.frequency.value = hz(note) * 2;
      const otLevel = ctx.createGain();
      otLevel.gain.value = 0.25;
      const amp = ctx.createGain();
      amp.gain.setValueAtTime(0, at);
      amp.gain.linearRampToValueAtTime(level, at + 0.01);
      amp.gain.exponentialRampToValueAtTime(0.0001, at + length);
      osc.connect(amp);
      overtone.connect(otLevel).connect(amp);
      amp.connect(this.master!);
      amp.connect(this.room!);
      osc.start(at);
      overtone.start(at);
      osc.stop(at + length + 0.05);
      overtone.stop(at + length + 0.05);
    });
  }

  private brush(t: number, level: number, length: number) {
    const ctx = this.ctx!;
    const src = ctx.createBufferSource();
    src.buffer = this.noise;
    const band = ctx.createBiquadFilter();
    band.type = "bandpass";
    band.frequency.value = 3200;
    band.Q.value = 0.6;
    const amp = ctx.createGain();
    amp.gain.setValueAtTime(0, t);
    amp.gain.linearRampToValueAtTime(level, t + length * 0.3);
    amp.gain.exponentialRampToValueAtTime(0.0001, t + length);
    src.connect(band).connect(amp).connect(this.master!);
    src.start(t, Math.random());
    src.stop(t + length + 0.02);
  }

  private saxPhrase(t: number) {
    // Two to four long, bluesy notes that drift down and land on a chord tone.
    let at = t;
    let note = pick(SAX_NOTES.slice(3));
    const count = 2 + Math.floor(Math.random() * 3);
    for (let i = 0; i < count; i += 1) {
      const length = BEAT * pick([0.75, 1, 1.5, 2]);
      this.sax(at, note, length);
      at += length + BEAT * pick([0, 0.25, 0.5]);
      const lower = SAX_NOTES.filter((n) => n < note);
      note = lower.length > 0 && Math.random() < 0.7 ? pick(lower.slice(-3)) : pick(SAX_NOTES);
    }
  }

  private sax(t: number, note: number, length: number) {
    const ctx = this.ctx!;
    const osc = ctx.createOscillator();
    osc.type = "sawtooth";
    osc.frequency.value = hz(note);
    // Slow, late vibrato, the way a tenor leans into a long note.
    const vibrato = ctx.createOscillator();
    vibrato.frequency.value = 4.8;
    const depth = ctx.createGain();
    depth.gain.setValueAtTime(0, t);
    depth.gain.linearRampToValueAtTime(hz(note) * 0.008, t + length * 0.6);
    vibrato.connect(depth).connect(osc.frequency);
    const tone = ctx.createBiquadFilter();
    tone.type = "lowpass";
    tone.Q.value = 2;
    tone.frequency.setValueAtTime(700, t);
    tone.frequency.linearRampToValueAtTime(1500, t + 0.12);
    tone.frequency.linearRampToValueAtTime(950, t + length);
    const amp = ctx.createGain();
    amp.gain.setValueAtTime(0, t);
    amp.gain.linearRampToValueAtTime(0.06, t + 0.08);
    amp.gain.setValueAtTime(0.06, t + length * 0.7);
    amp.gain.linearRampToValueAtTime(0, t + length);
    osc.connect(tone).connect(amp);
    amp.connect(this.master!);
    amp.connect(this.room!);
    osc.start(t);
    vibrato.start(t);
    osc.stop(t + length + 0.05);
    vibrato.stop(t + length + 0.05);
  }

  private startCrackle() {
    const ctx = this.ctx!;
    // Sparse random clicks over a faint hiss, like an old record.
    const buffer = ctx.createBuffer(1, ctx.sampleRate * 4, ctx.sampleRate);
    const data = buffer.getChannelData(0);
    for (let i = 0; i < data.length; i += 1) {
      data[i] = (Math.random() * 2 - 1) * 0.012 + (Math.random() < 0.0004 ? (Math.random() * 2 - 1) * 0.5 : 0);
    }
    const src = ctx.createBufferSource();
    src.buffer = buffer;
    src.loop = true;
    const tone = ctx.createBiquadFilter();
    tone.type = "highpass";
    tone.frequency.value = 1500;
    const amp = ctx.createGain();
    amp.gain.value = 0.35;
    src.connect(tone).connect(amp).connect(this.master!);
    src.start();
    this.crackle = src;
  }
}
