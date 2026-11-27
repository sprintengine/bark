/* ── Voice-reactive level meter ─────────────────────────────────
   The pill's waveform, as on the Mac: the last 0.8 s of the voice as thin
   bars, newest on the right, each bar's height and strength following the
   level it was heard at (a fifth of full height at rest). With reduced motion
   the bars hold still at a fixed height and light up from the left with the
   level instead. Levels come from the backend's `audio-level` events; the
   bars sit flat through silence instead of pulsing on a loop. */

const waveBars = Array.from(document.querySelectorAll<HTMLElement>(".wave span"));
// Gate matches the backend's per-window speech RMS threshold, so the bars
// consider "voice" exactly what the transcriber's gap detection does.
const METER_GATE_RMS = 0.004;
// A normal speaking voice at full scale; louder speech simply clamps.
const METER_FULL_RMS = 0.026;
// A bar at rest, as a fraction of the waveform's height.
const REST_HEIGHT = 0.2;
// Reduced motion: every bar at this height, lit or not.
const STILL_HEIGHT = 0.4;
// The history advances at 30 Hz, so 24 bars are the last 0.8 s.
const SAMPLE_MS = 1000 / 30;
const reducedMotionQuery = window.matchMedia("(prefers-reduced-motion: reduce)");

let meterTarget = 0;
let meterDisplay = 0;
let meterRafId: number | null = null;
let lastSample = 0;
// Oldest first; one value per bar.
const history: number[] = waveBars.map(() => 0);
// The meter keeps animating while this holds (the pill is recording).
let keepRunning: () => boolean = () => false;

function meterLevelFromRms(rms: number): number {
  const normalized = Math.min(1, Math.max(0, (rms - METER_GATE_RMS) / (METER_FULL_RMS - METER_GATE_RMS)));
  // Square root for a perceptual response: quiet speech still visibly moves.
  return Math.sqrt(normalized);
}

export function startMeter(isRecording: () => boolean): void {
  keepRunning = isRecording;
  meterTarget = 0;
  meterDisplay = 0;
  history.fill(0);
  lastSample = 0;
  if (meterRafId === null) meterFrame();
}

export function stopMeter(): void {
  meterTarget = 0;
  if (meterRafId !== null) {
    cancelAnimationFrame(meterRafId);
    meterRafId = null;
  }
  resetMeterBars();
}

function drawBar(bar: HTMLElement, height: number, level: number): void {
  bar.style.transform = `scaleY(${height.toFixed(3)})`;
  bar.style.opacity = (0.3 + 0.55 * level).toFixed(3);
}

function meterFrame(): void {
  meterRafId = requestAnimationFrame((time) => {
    const attack = 0.45;
    const decay = reducedMotionQuery.matches ? 0.08 : 0.18;
    meterDisplay += (meterTarget - meterDisplay) * (meterTarget > meterDisplay ? attack : decay);
    if (time - lastSample >= SAMPLE_MS) {
      lastSample = time;
      history.shift();
      history.push(meterDisplay);
    }
    if (reducedMotionQuery.matches) {
      const lit = meterDisplay * waveBars.length;
      waveBars.forEach((bar, i) => drawBar(bar, STILL_HEIGHT, lit > i + 0.5 ? 1 : 0));
    } else {
      waveBars.forEach((bar, i) => drawBar(bar, Math.max(REST_HEIGHT, history[i]), history[i]));
    }
    if (keepRunning() || history.some((value) => value > 0.02)) {
      meterFrame();
    } else {
      meterRafId = null;
      resetMeterBars();
    }
  });
}

/** Every bar at rest: a dotted line. */
export function resetMeterBars(): void {
  history.fill(0);
  for (const bar of waveBars) drawBar(bar, REST_HEIGHT, 0);
}

/** Feed one `audio-level` reading; true when it carries voice. */
export function setMeterLevel(rms: number): boolean {
  meterTarget = meterLevelFromRms(rms);
  return meterTarget > 0;
}
