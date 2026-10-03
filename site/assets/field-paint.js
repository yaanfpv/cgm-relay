// Paints the hero's field: one night, 22:30 to 07:30, as a dot for each of its
// 540 minutes, in order, a row an hour on a wide canvas and a row a half hour on
// a narrow one. A pure function of time t in seconds, shared by its worker and
// the main-thread fallback. First the dots LibreLinkUp keeps (one every 15
// minutes) light pale; then a wave lights every other minute mint, the ones
// only CGM Relay keeps.

export const MINUTES = 540;
const STEP = 15;

export const DEFAULTS = {
  sparseFrom: 0.4,
  sparseSeconds: 1.4,
  waveFrom: 2.3,
  waveSeconds: 2.6,
  dotScale: 0.32,
};

export function finishedAt(params) {
  return params.waveFrom + params.waveSeconds + 0.8;
}

const clamp = (x) => Math.min(1, Math.max(0, x));
// A critically damped spring's step response, scaled so x = 1 lands exactly on 1.
const SPRING_END = 1 - Math.exp(-7) * 8;
const spring = (x) => {
  const k = clamp(x) * 7;
  return (1 - Math.exp(-k) * (1 + k)) / SPRING_END;
};
// A short swell as the wave passes a dot, zero outside its half second.
const swell = (since) => (since > 0 && since < 0.5 ? Math.sin((Math.PI * since) / 0.5) : 0);

const REST = 'rgba(230,242,239,0.12)';

export function paint(ctx, width, height, t, params = DEFAULTS) {
  ctx.clearRect(0, 0, width, height);
  const cols = width / height > 3 ? 60 : 30;
  const rows = MINUTES / cols;
  const cell = Math.min(width / cols, height / rows);
  const offX = (width - cell * cols) / 2;
  const offY = (height - cell * rows) / 2;
  const base = cell * params.dotScale;
  for (let m = 0; m < MINUTES; m++) {
    const cx = offX + ((m % cols) + 0.5) * cell;
    const cy = offY + (Math.floor(m / cols) + 0.5) * cell;
    const kept = m % STEP === 0;
    const sinceWave = t - (params.waveFrom + (m / MINUTES) * params.waveSeconds);
    const pulse = 0.45 * base * swell(sinceWave);
    let r;
    if (kept) {
      const s = spring((t - (params.sparseFrom + (m / MINUTES) * params.sparseSeconds)) / 0.35);
      r = base * (0.55 + 0.45 * s) + pulse;
      ctx.fillStyle = s > 0 ? `rgba(230,242,239,${0.12 + 0.83 * s})` : REST;
    } else {
      const w = spring(sinceWave / 0.4);
      r = base * (0.55 + 0.25 * w) + pulse;
      ctx.fillStyle = w > 0 ? `rgba(119,231,209,${0.12 + 0.8 * w})` : REST;
    }
    ctx.beginPath();
    ctx.arc(cx, cy, r, 0, Math.PI * 2);
    ctx.fill();
  }
}
