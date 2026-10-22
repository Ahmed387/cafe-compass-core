/**
 * An original, sultry Latin lounge (cha-cha) groove generated live with the Web
 * Audio API: a tumbao bass, a piano montuno, clave, congas, a shaker and the
 * "cha-cha" güiro, with a muted trumpet singing an original melody. Nothing is
 * downloaded and no existing song or recording is used.
 */

const BPM = 112;
const BEAT = 60 / BPM;

type Bar = { bass: [number, number, number]; chord: number[] };
// A minor, eight bars: Am7 | Am7 | Dm7 | E7 | Dm7 | E7 | Am7 | Am7
const AM: Bar = { bass: [45, 52, 45], chord: [60, 64, 67, 69] };
const DM: Bar = { bass: [38, 45, 38], chord: [60, 62, 65, 69] };
const E7: Bar = { bass: [40, 47, 40], chord: [59, 62, 64, 68] };
const FORM: Bar[] = [AM, AM, DM, E7, DM, E7, AM, AM];

// The trumpet's tune, written for this page: [beat in bar, MIDI note, beats long].
const MELODY: Array<Array<[number, number, number]>> = [
  [[0.5, 72, 0.5], [1, 71, 0.5], [1.5, 69, 1.5], [3, 76, 1]],
  [[0, 74, 0.5], [0.5, 72, 0.5], [1, 71, 1], [2.5, 69, 1.5]],
  [[0.5, 74, 0.5], [1, 72, 0.5], [1.5, 69, 0.5], [2, 77, 1.5], [3.5, 76, 0.5]],
  [[0, 74, 1], [1, 71, 0.5], [1.5, 68, 1.5], [3, 64, 1]],
  [[0.5, 77, 0.5], [1, 76, 0.5], [1.5, 74, 1], [2.5, 72, 1], [3.5, 74, 0.5]],
  [[0, 76, 1.5], [1.5, 74, 0.5], [2, 71, 0.5], [2.5, 68, 1.5]],
  [[0, 69, 1], [1, 72, 0.5], [1.5, 76, 1], [2.5, 81, 1.5]],
  [[0, 76, 2.5]],
];
// Piano montuno: syncopated eighths, alternating low and high voicing.
const MONTUNO: Array<[number, boolean]> = [
  [0, false], [0.5, true], [1.5, false], [2, true], [2.5, false], [3.5, true],
];
// 2-3 son clave across two bars.
const CLAVE: number[][] = [[1, 2], [0, 1.5, 3]];

const hz = (midi: number) => 440 * 2 ** ((midi - 69) / 12);

export class AmbientMusic {
  private ctx: AudioContext | null = null;
  private master: GainNode | null = null;
  private room: ConvolverNode | null = null;
  private noise: AudioBuffer | null = null;
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
    this.nextBarTime = ctx.currentTime + 0.2;
    // Look-ahead scheduler: queue every bar a little before it is due.
    this.timer = window.setInterval(() => this.schedule(), 200);
    this.schedule();
  }

  stop() {
    if (this.timer !== null) window.clearInterval(this.timer);
    this.timer = null;
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
    warmth.frequency.value = 7000;
    master.connect(warmth).connect(ctx.destination);

    // A warm lounge room: noise decaying over ~1.8s as the impulse response.
    const length = Math.floor(ctx.sampleRate * 1.8);
    const impulse = ctx.createBuffer(2, length, ctx.sampleRate);
    for (let ch = 0; ch < 2; ch += 1) {
      const data = impulse.getChannelData(ch);
      for (let i = 0; i < length; i += 1) data[i] = (Math.random() * 2 - 1) * (1 - i / length) ** 3;
    }
    const room = ctx.createConvolver();
    room.buffer = impulse;
    const roomLevel = ctx.createGain();
    roomLevel.gain.value = 0.28;
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
      this.playBar(this.nextBarTime, this.bar);
      this.nextBarTime += BEAT * 4;
      this.bar += 1;
    }
  }

  private playBar(t: number, index: number) {
    const slot = index % FORM.length;
    const bar = FORM[slot]!;
    const next = FORM[(slot + 1) % FORM.length]!;
    const at = (beat: number) => t + beat * BEAT;

    // Tumbao bass: the root, the fifth on the "and" of 2, the next root pushed onto 4.
    this.bass(at(0), bar.bass[0], 1.2);
    this.bass(at(1.5), bar.bass[1], 1);
    this.bass(at(3), next.bass[0], 1);

    for (const [beat, high] of MONTUNO) this.piano(at(beat), bar.chord, high);

    // Percussion: clave, shaker eighths, congas on 4-and, güiro on "cha-cha".
    for (const beat of CLAVE[index % 2]!) this.click(at(beat), 1900, 0.09);
    for (let e = 0; e < 8; e += 1) this.shaker(at(e / 2), e % 2 === 0 ? 0.035 : 0.02);
    this.conga(at(3), 220, 0.18);
    this.conga(at(3.5), 220, 0.15);
    this.conga(at(1), 330, 0.07);
    this.guiro(at(3), BEAT * 0.4);
    this.guiro(at(3.5), BEAT * 0.4);

    // The trumpet sings the tune every other time round the form, then rests.
    if (Math.floor(index / FORM.length) % 2 === 0) {
      for (const [beat, note, len] of MELODY[slot]!) this.trumpet(at(beat), note, len * BEAT);
    }
  }

  private bass(t: number, note: number, beats: number) {
    const ctx = this.ctx!;
    const osc = ctx.createOscillator();
    osc.type = "triangle";
    osc.frequency.value = hz(note);
    const tone = ctx.createBiquadFilter();
    tone.type = "lowpass";
    tone.frequency.value = 500;
    const amp = ctx.createGain();
    amp.gain.setValueAtTime(0, t);
    amp.gain.linearRampToValueAtTime(0.34, t + 0.01);
    amp.gain.exponentialRampToValueAtTime(0.0001, t + BEAT * beats);
    osc.connect(tone).connect(amp).connect(this.master!);
    osc.start(t);
    osc.stop(t + BEAT * beats + 0.02);
  }

  private piano(t: number, chord: number[], high: boolean) {
    const ctx = this.ctx!;
    const notes = high ? chord.map((n) => n + 12) : chord;
    notes.forEach((note) => {
      const osc = ctx.createOscillator();
      osc.type = "triangle";
      osc.frequency.value = hz(note);
      const amp = ctx.createGain();
      amp.gain.setValueAtTime(0, t);
      amp.gain.linearRampToValueAtTime(high ? 0.022 : 0.03, t + 0.005);
      amp.gain.exponentialRampToValueAtTime(0.0001, t + BEAT * 0.45);
      osc.connect(amp);
      amp.connect(this.master!);
      amp.connect(this.room!);
      osc.start(t);
      osc.stop(t + BEAT * 0.5);
    });
  }

  private click(t: number, freq: number, level: number) {
    const ctx = this.ctx!;
    const osc = ctx.createOscillator();
    osc.type = "sine";
    osc.frequency.value = freq;
    const amp = ctx.createGain();
    amp.gain.setValueAtTime(level, t);
    amp.gain.exponentialRampToValueAtTime(0.0001, t + 0.06);
    osc.connect(amp);
    amp.connect(this.master!);
    amp.connect(this.room!);
    osc.start(t);
    osc.stop(t + 0.07);
  }

  private conga(t: number, freq: number, level: number) {
    const ctx = this.ctx!;
    const osc = ctx.createOscillator();
    osc.type = "sine";
    osc.frequency.setValueAtTime(freq * 1.5, t);
    osc.frequency.exponentialRampToValueAtTime(freq, t + 0.04);
    const amp = ctx.createGain();
    amp.gain.setValueAtTime(level, t);
    amp.gain.exponentialRampToValueAtTime(0.0001, t + 0.3);
    osc.connect(amp);
    amp.connect(this.master!);
    amp.connect(this.room!);
    osc.start(t);
    osc.stop(t + 0.32);
  }

  private noiseHit(t: number, filter: BiquadFilterType, freq: number, level: number, length: number, swell: boolean) {
    const ctx = this.ctx!;
    const src = ctx.createBufferSource();
    src.buffer = this.noise;
    const band = ctx.createBiquadFilter();
    band.type = filter;
    band.frequency.value = freq;
    const amp = ctx.createGain();
    amp.gain.setValueAtTime(swell ? 0 : level, t);
    if (swell) amp.gain.linearRampToValueAtTime(level, t + length * 0.8);
    amp.gain.exponentialRampToValueAtTime(0.0001, t + length);
    src.connect(band).connect(amp).connect(this.master!);
    src.start(t, Math.random());
    src.stop(t + length + 0.02);
    return amp;
  }

  private shaker(t: number, level: number) {
    this.noiseHit(t, "highpass", 6000, level, 0.07, false);
  }

  private guiro(t: number, length: number) {
    // A scrape: noise gated by a fast ratchet, swelling into the next beat.
    const amp = this.noiseHit(t, "bandpass", 2600, 0.05, length, true);
    const ctx = this.ctx!;
    const ratchet = ctx.createOscillator();
    ratchet.type = "square";
    ratchet.frequency.value = 38;
    const depth = ctx.createGain();
    depth.gain.value = 0.025;
    ratchet.connect(depth).connect(amp.gain);
    ratchet.start(t);
    ratchet.stop(t + length);
  }

  private trumpet(t: number, note: number, length: number) {
    const ctx = this.ctx!;
    const osc = ctx.createOscillator();
    osc.type = "sawtooth";
    osc.frequency.value = hz(note);
    // A little scoop into the note and a late vibrato, like a muted trumpet.
    osc.detune.setValueAtTime(-40, t);
    osc.detune.linearRampToValueAtTime(0, t + 0.06);
    const vibrato = ctx.createOscillator();
    vibrato.frequency.value = 5.5;
    const depth = ctx.createGain();
    depth.gain.setValueAtTime(0, t);
    depth.gain.linearRampToValueAtTime(hz(note) * 0.006, t + Math.max(length * 0.7, 0.05));
    vibrato.connect(depth).connect(osc.frequency);
    const mute = ctx.createBiquadFilter();
    mute.type = "bandpass";
    mute.frequency.value = 1400;
    mute.Q.value = 1.4;
    const amp = ctx.createGain();
    amp.gain.setValueAtTime(0, t);
    amp.gain.linearRampToValueAtTime(0.11, t + 0.03);
    amp.gain.setValueAtTime(0.1, t + length * 0.75);
    amp.gain.linearRampToValueAtTime(0, t + length);
    osc.connect(mute).connect(amp);
    amp.connect(this.master!);
    amp.connect(this.room!);
    osc.start(t);
    vibrato.start(t);
    osc.stop(t + length + 0.05);
    vibrato.stop(t + length + 0.05);
  }
}
