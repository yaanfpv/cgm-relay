// Draws the example night on an OffscreenCanvas the page handed over, so the
// drawing never runs on the page's main thread. The page sends where the
// reader's scroll has reached; this glides its own drawn progress towards it
// with the same easing the page uses for the captions, painting one frame per
// display refresh until it lands, so it never waits on a message to draw.
import { paint, DEFAULTS } from './night-paint.js';

let canvas = null;
let ctx = null;
let params = { ...DEFAULTS };
let progress = 0;
let target = 0;
let looping = false;
let last = 0;

const nextFrame = (fn) =>
  typeof self.requestAnimationFrame === 'function' ? self.requestAnimationFrame(fn) : setTimeout(() => fn(performance.now()), 16);

function render() {
  ctx.setTransform(1, 0, 0, 1, 0, 0);
  paint(ctx, canvas.width, canvas.height, progress, params);
}

function frame(now) {
  const step = 1 - Math.exp(-Math.min(64, now - last) / params.followMs);
  last = now;
  progress += (target - progress) * step;
  if (Math.abs(target - progress) < 0.0002) progress = target;
  render();
  looping = progress !== target;
  if (looping) nextFrame(frame);
}

function glide() {
  if (looping || !ctx) return;
  looping = true;
  last = performance.now();
  nextFrame(frame);
}

self.onmessage = ({ data }) => {
  if (data.type === 'init') {
    canvas = data.canvas;
    ctx = canvas.getContext('2d');
    canvas.width = data.width;
    canvas.height = data.height;
    progress = target = data.progress;
    render();
  } else if (data.type === 'resize') {
    canvas.width = data.width;
    canvas.height = data.height;
    render();
  } else if (data.type === 'params') {
    params = { ...params, ...data.params };
    render();
  } else if (data.type === 'target') {
    target = data.target;
    glide();
  }
};
