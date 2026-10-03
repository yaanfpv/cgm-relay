// Paints the example night at one point in its story: a pure function of the
// story's progress p, from 0 to 1, shared by the worker and the main-thread
// fallback so both draw identical frames. Scrolling the section drives p.

const START_MIN = 22 * 60 + 30; // 22:30
const END_MIN = 7 * 60 + 30 + 24 * 60; // 07:30 the next morning
const SPAN = END_MIN - START_MIN;
const HISTORY_STEP = 15;

// DEFAULTS holds every number the story is tuned by: where each beat starts
// and ends as a fraction of the scroll, when the phone sleeps and wakes in
// minutes after 22:30, the shape of the dip, and followMs, how quickly the
// drawn story glides to the scroll position (night.js reads that one). The
// tuning panel edits a copy.
export const DEFAULTS = {
  phoneEnd: 0.2,
  dotsFrom: 0.2,
  dotsEnd: 0.46,
  relayFrom: 0.5,
  relayEnd: 0.74,
  catchUpFrom: 0.74,
  catchUpEnd: 0.97,
  sleepsAt: 130,
  wakesAt: 514,
  dipDepth: 46,
  dipWidth: 5.5,
  followMs: 110,
};

// beatAt names which of the four captions belongs to progress p. Each
// caption changes the moment the line reaches the stop before its beat, as
// the line eases through that stop into the next beat without holding.
export function beatAt(p, params) {
  if (p < params.phoneEnd) return 0;
  if (p < params.dotsEnd) return 1;
  if (p < params.relayEnd) return 2;
  return 3;
}

// A fixed-seed example night, one value a minute, in mg/dL: drifting, a
// short dip a little after two, and a rise towards morning.
function makeNight(dipDepth, dipWidth) {
  let seed = 20261003;
  const rand = () => {
    seed = (seed * 1664525 + 1013904223) >>> 0;
    return seed / 4294967296;
  };
  const values = [];
  let wander = 0;
  for (let m = 0; m <= SPAN; m++) {
    const clock = START_MIN + m;
    wander = wander * 0.97 + (rand() - 0.5) * 1.6;
    const drift = 8 * Math.sin(m / 70) + 5 * Math.sin(m / 23 + 1.3);
    const dip = -dipDepth * Math.exp(-(((clock - (2 * 60 + 7 + 24 * 60)) / dipWidth) ** 2));
    const dawn = 34 / (1 + Math.exp(-(clock - (5 * 60 + 20 + 24 * 60)) / 28));
    values.push(116 + drift + dip + dawn + wander);
  }
  return values;
}
let night = null;
let nightKey = '';
function nightFor(params) {
  const key = `${params.dipDepth}:${params.dipWidth}`;
  if (key !== nightKey) {
    night = makeNight(params.dipDepth, params.dipWidth);
    nightKey = key;
  }
  return night;
}

const clamp = (x) => Math.min(1, Math.max(0, x));
const between = (p, a, b) => clamp((p - a) / (b - a));
const smooth = (x) => x * x * (3 - 2 * x);

// The night is drawn on the page's night sky in both themes, so it has one palette.
const c = { ink: 'rgba(230,242,239,0.45)', faint: 'rgba(230,242,239,0.12)', relay: '#77E7D1', cursor: 'rgba(230,242,239,0.5)' };

// Where the two rows sit, as fractions of the canvas height; site.css places
// each row's label just above its band, so change the two together.
const ROWS = [
  { top: 0.17, bottom: 0.45 },
  { top: 0.67, bottom: 0.95 },
];
const LOW = 50;
const HIGH = 190;

// clockAt is the minute the story is showing at p, for the clock above the
// chart and its cursor: the phone's night, then LibreLinkUp's, then a sweep
// back to 22:30 so the Mac's pass starts where the night did, then the Mac's.
export function clockAt(p, params) {
  if (p <= params.phoneEnd) return params.sleepsAt * smooth(between(p, 0, params.phoneEnd));
  if (p < params.dotsFrom) return params.sleepsAt;
  if (p <= params.dotsEnd) return params.sleepsAt + (params.wakesAt - params.sleepsAt) * smooth(between(p, params.dotsFrom, params.dotsEnd));
  if (p < params.relayFrom) return params.wakesAt * (1 - smooth(between(p, params.dotsEnd, params.relayFrom)));
  if (p <= params.relayEnd) return SPAN * smooth(between(p, params.relayFrom, params.relayEnd));
  return SPAN;
}

export function paint(ctx, width, height, p, params = DEFAULTS) {
  const NIGHT = nightFor(params);
  ctx.clearRect(0, 0, width, height);
  // Line weights scale with the chart's width, with a floor so a phone's lines stay visible.
  const unit = Math.max(1.6, width / 900);
  const x = (m) => (m / SPAN) * width;
  const yIn = (row, v) => {
    const r = ROWS[row];
    return (r.bottom - ((v - LOW) / (HIGH - LOW)) * (r.bottom - r.top)) * height;
  };
  // valueAt reads the night between whole minutes, so a line's tip moves
  // smoothly with the scroll instead of stepping a minute at a time.
  const valueAt = (m) => {
    const i = Math.min(SPAN - 1, Math.floor(m));
    return NIGHT[i] + (NIGHT[i + 1] - NIGHT[i]) * (m - i);
  };
  const line = (row, from, to, colour, w) => {
    if (to <= from) return;
    ctx.strokeStyle = colour;
    ctx.lineWidth = w;
    ctx.lineJoin = 'round';
    ctx.lineCap = 'round';
    ctx.beginPath();
    ctx.moveTo(x(from), yIn(row, valueAt(from)));
    for (let m = Math.floor(from) + 1; m < to; m++) ctx.lineTo(x(m), yIn(row, NIGHT[m]));
    ctx.lineTo(x(to), yIn(row, valueAt(to)));
    ctx.stroke();
  };

  // The 70 and 180 guides in each row.
  ctx.lineWidth = unit;
  ctx.strokeStyle = c.faint;
  ctx.setLineDash([2 * unit, 5 * unit]);
  for (let row = 0; row < 2; row++) {
    for (const g of [70, 180]) {
      ctx.beginPath();
      ctx.moveTo(0, yIn(row, g));
      ctx.lineTo(width, yIn(row, g));
      ctx.stroke();
    }
  }
  ctx.setLineDash([]);

  const sleeps = params.sleepsAt;
  const wakes = params.wakesAt;

  // Beat one: the phone's app reads every minute until the phone sleeps.
  const phoneTo = sleeps * smooth(between(p, 0, params.phoneEnd));
  line(0, 0, phoneTo, c.ink, 1.6 * unit);

  // Beat two: all LibreLinkUp keeps for the hours it slept is a reading
  // every 15 minutes.
  const caught = smooth(between(p, params.catchUpFrom, params.catchUpEnd));
  // Every moving beat eases in and out, so the line never lurches off a stop.
  const dotsTo = sleeps + (wakes - sleeps) * smooth(between(p, params.dotsFrom, params.dotsEnd));
  if (p >= params.dotsFrom && caught < 1) {
    ctx.globalAlpha = 1 - caught;
    const first = Math.ceil(sleeps / HISTORY_STEP) * HISTORY_STEP;
    ctx.strokeStyle = c.ink;
    ctx.fillStyle = c.ink;
    ctx.lineWidth = 1.2 * unit;
    ctx.setLineDash([3 * unit, 4 * unit]);
    ctx.beginPath();
    ctx.moveTo(x(sleeps), yIn(0, NIGHT[sleeps]));
    let lastDot = sleeps;
    for (let m = first; m <= dotsTo; m += HISTORY_STEP) {
      ctx.lineTo(x(m), yIn(0, NIGHT[m]));
      lastDot = m;
    }
    // The dashes run on towards the next 15-minute reading as the clock
    // moves, so the line grows smoothly while the dots land on their own.
    if (dotsTo > lastDot && dotsTo < wakes) {
      const next = Math.min(SPAN, lastDot === sleeps ? first : lastDot + HISTORY_STEP);
      const f = (dotsTo - lastDot) / (next - lastDot);
      const from = yIn(0, lastDot === sleeps ? valueAt(sleeps) : NIGHT[lastDot]);
      ctx.lineTo(x(dotsTo), from + (yIn(0, NIGHT[next]) - from) * f);
    }
    ctx.stroke();
    ctx.setLineDash([]);
    for (let m = first; m <= dotsTo; m += HISTORY_STEP) {
      ctx.beginPath();
      ctx.arc(x(m), yIn(0, NIGHT[m]), 2.2 * unit, 0, Math.PI * 2);
      ctx.fill();
    }
    ctx.globalAlpha = 1;
  }

  // Beat three: CGM Relay had asked every minute, all night.
  const relayTo = SPAN * smooth(between(p, params.relayFrom, params.relayEnd));
  line(1, 0, relayTo, c.relay, 2 * unit);

  // Beat four: the phone wakes, and its app catches up on every minute from
  // the relay, then carries on.
  if (caught > 0) {
    line(0, sleeps, sleeps + (wakes - sleeps) * caught, c.relay, 1.8 * unit);
    if (caught >= 1) line(0, wakes, SPAN, c.ink, 1.6 * unit);
  }

  // A thin cursor at the minute the clock shows, from the first beat until
  // the relay's line has finished, the sweep back to 22:30 included.
  const cursor = cursorAlpha(p, params);
  if (cursor > 0) {
    const at = x(clockAt(p, params));
    ctx.globalAlpha = cursor;
    ctx.strokeStyle = c.cursor;
    ctx.lineWidth = unit;
    ctx.beginPath();
    ctx.moveTo(at, 0);
    ctx.lineTo(at, height);
    ctx.stroke();
    ctx.globalAlpha = 1;
  }
}

// cursorAlpha is the cursor's opacity at p: fading in as the story starts and
// out once the Mac's pass is done; it stays visible through the sweep back.
function cursorAlpha(p, params) {
  const fade = 0.02;
  if (p < params.relayEnd) return smooth(between(p, 0, fade));
  return 1 - smooth(between(p, params.relayEnd, params.relayEnd + fade * 2));
}

// clockLabel formats a minute since 22:30 as a 24-hour clock time.
export function clockLabel(m) {
  const total = (START_MIN + Math.round(m)) % (24 * 60);
  return `${String(Math.floor(total / 60)).padStart(2, '0')}:${String(total % 60).padStart(2, '0')}`;
}

export const SPAN_MINUTES = SPAN;
