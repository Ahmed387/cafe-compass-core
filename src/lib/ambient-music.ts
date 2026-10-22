/**
 * A calm, original lo-fi ambience generated live with the Web Audio API:
 * soft chord pads, a gentle pentatonic pluck and a little echo. Nothing is
 * downloaded and there is no licensed track to clear.
 */

const CHORDS = [
  [48, 55, 64, 71], // Cmaj7
  [45, 52, 60, 67], // Am7
  [41, 48, 57, 64], // Fmaj7
  [43, 50, 59, 64], // G6
];
const MELODY = [72, 74, 76, 79, 81, 84]; // C major pentatonic
const CHORD_SECONDS = 8;

const hz = (midi: number) => 440 * 2 ** ((midi - 69) / 12);

export class AmbientMusic {
  private ctx: AudioContext | null = null;
  private master: GainNode | null = null;
  private echo: DelayNode | null = null;
  private timers: number[] = [];
  private chordIndex = 0;

  get running() {
    return this.ctx?.state === "running" && this.timers.length > 0;
  }

  async start() {
    if (this.running) return;
    if (!this.ctx) this.build();
    await this.ctx!.resume();
    this.master!.gain.setTargetAtTime(0.22, this.ctx!.currentTime, 1.5);
    this.playChord();
    this.timers.push(window.setInterval(() => this.playChord(), CHORD_SECONDS * 1000));
    this.schedulePluck();
  }

  stop() {
    this.timers.forEach((id) => {
      window.clearInterval(id);
      window.clearTimeout(id);
    });
    this.timers = [];
    if (this.ctx && this.master) {
      this.master.gain.setTargetAtTime(0, this.ctx.currentTime, 0.4);
      const ctx = this.ctx;
      window.setTimeout(() => void ctx.suspend(), 1500);
    }
  }

  setMuted(muted: boolean) {
    if (!this.ctx || !this.master) return;
    this.master.gain.setTargetAtTime(muted ? 0 : 0.22, this.ctx.currentTime, 0.3);
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
    const tone = ctx.createBiquadFilter();
    tone.type = "lowpass";
    tone.frequency.value = 1800;
    const echo = ctx.createDelay(2);
    echo.delayTime.value = 0.42;
    const feedback = ctx.createGain();
    feedback.gain.value = 0.35;
    echo.connect(feedback).connect(echo);
    echo.connect(tone);
    master.connect(tone).connect(ctx.destination);
    this.ctx = ctx;
    this.master = master;
    this.echo = echo;
  }

  private playChord() {
    const ctx = this.ctx!;
    const now = ctx.currentTime;
    const notes = CHORDS[this.chordIndex % CHORDS.length]!;
    this.chordIndex += 1;
    for (const note of notes) {
      for (const detune of [-6, 6]) {
        const osc = ctx.createOscillator();
        osc.type = "triangle";
        osc.frequency.value = hz(note);
        osc.detune.value = detune;
        const amp = ctx.createGain();
        amp.gain.setValueAtTime(0, now);
        amp.gain.linearRampToValueAtTime(0.05, now + 2.5);
        amp.gain.linearRampToValueAtTime(0.04, now + CHORD_SECONDS - 1);
        amp.gain.linearRampToValueAtTime(0, now + CHORD_SECONDS + 2);
        osc.connect(amp).connect(this.master!);
        osc.start(now);
        osc.stop(now + CHORD_SECONDS + 2.2);
      }
    }
  }

  private schedulePluck() {
    const id = window.setTimeout(() => {
      this.timers = this.timers.filter((t) => t !== id);
      if (!this.ctx) return;
      this.pluck();
      this.schedulePluck();
    }, 1400 + Math.random() * 2200);
    this.timers.push(id);
  }

  private pluck() {
    const ctx = this.ctx!;
    const now = ctx.currentTime;
    const osc = ctx.createOscillator();
    osc.type = "sine";
    osc.frequency.value = hz(MELODY[Math.floor(Math.random() * MELODY.length)]!);
    const amp = ctx.createGain();
    amp.gain.setValueAtTime(0, now);
    amp.gain.linearRampToValueAtTime(0.07, now + 0.02);
    amp.gain.exponentialRampToValueAtTime(0.0001, now + 2.2);
    osc.connect(amp);
    amp.connect(this.master!);
    amp.connect(this.echo!);
    osc.start(now);
    osc.stop(now + 2.3);
  }
}
