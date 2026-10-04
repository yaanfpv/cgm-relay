// Draws the hero's minute field on an OffscreenCanvas the page handed over, so
// its one animation never runs on the page's main thread.
import { paint, finishedAt, DEFAULTS } from './field-paint.js';

let canvas = null;
let ctx = null;
let params = { ...DEFAULTS };
let startedAt = null;
let finished = false;
let pending = false;

const nextFrame = (fn) =>
  typeof self.requestAnimationFrame === 'function' ? self.requestAnimationFrame(fn) : setTimeout(() => fn(performance.now()), 16);

function request() {
  if (pending || !ctx) return;
  pending = true;
  nextFrame(draw);
}

function draw(now) {
  pending = false;
  const end = finishedAt(params);
  const t = finished ? end : startedAt === null ? 0 : (now - startedAt) / 1000;
  ctx.setTransform(1, 0, 0, 1, 0, 0);
  paint(ctx, canvas.width, canvas.height, t, params);
  if (finished || startedAt === null) return;
  if (t < end) request();
  else {
    finished = true;
    self.postMessage({ type: 'finished' });
  }
}

self.onmessage = ({ data }) => {
  if (data.type === 'init') {
    canvas = data.canvas;
    ctx = canvas.getContext('2d');
    canvas.width = data.width;
    canvas.height = data.height;
    finished = data.finished;
    if (finished) self.postMessage({ type: 'finished' });
  } else if (data.type === 'resize') {
    canvas.width = data.width;
    canvas.height = data.height;
  } else if (data.type === 'params') {
    params = { ...params, ...data.params };
  } else if (data.type === 'play') {
    startedAt = performance.now();
    finished = false;
  }
  request();
};
