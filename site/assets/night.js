// Drives the example night from the reader's scroll: while the section is on
// screen, each animation frame reads how far through it the reader is and
// paints that point in the story, on a worker where the browser can hand it
// the canvas and on the main thread otherwise. Reduced motion shows the
// finished night with every caption, as does a browser running no script.
// Adding #tune to the address opens the debug tuning panel for its numbers.
import { paint, beatAt, clockAt, clockLabel, DEFAULTS, SPAN_MINUTES } from './night-paint.js';

const track = document.querySelector('[data-night]');
const canvas = track && track.querySelector('canvas');

if (canvas) {
  // A browser running no script keeps the static finished night in the markup;
  // this hands the chart over to the canvas.
  track.classList.add('is-drawn');
  const reduced = matchMedia('(prefers-reduced-motion: reduce)');
  const params = { ...DEFAULTS };
  const captions = [...track.querySelectorAll('[data-beat]')];
  const clock = track.querySelector('[data-clock-now]');
  let progress = reduced.matches ? 1 : 0;

  const size = () => {
    const box = canvas.getBoundingClientRect();
    const ratio = Math.min(window.devicePixelRatio || 1, 2);
    return { width: Math.round(box.width * ratio), height: Math.round(box.height * ratio) };
  };

  // placeEvents puts the "goes quiet" and "wakes" labels at the minutes the
  // parameters name, with their clock times.
  const placeEvents = () => {
    for (const el of track.querySelectorAll('[data-at]')) {
      const m = el.dataset.at === 'sleeps' ? params.sleepsAt : params.wakesAt;
      el.style.setProperty('--at', String(m / SPAN_MINUTES));
      const time = el.querySelector('[data-clock]');
      if (time) time.textContent = clockLabel(m);
    }
  };
  placeEvents();

  // showStory sets everything outside the canvas for progress p.
  const showStory = (p) => {
    const beat = beatAt(p, params);
    captions.forEach((c, i) => c.classList.toggle('is-current', i === beat));
    clock.textContent = clockLabel(clockAt(p, params));
    track.style.setProperty('--progress', String(p));
  };

  // Two ways to draw, with one shape: aim(t) says where the scroll has
  // reached, paintAt() says the page's own glide has moved, and retune()
  // follows a tuning change. The worker runs its own glide towards
  // the aim on its own frames; the fallback simply paints what the page's
  // glide reached.
  let aim;
  let paintAt;
  let retune;
  if ('transferControlToOffscreen' in canvas && typeof Worker === 'function') {
    const worker = new Worker(new URL('./night-worker.js', import.meta.url), { type: 'module' });
    const offscreen = canvas.transferControlToOffscreen();
    worker.postMessage({ type: 'init', canvas: offscreen, progress, ...size() }, [offscreen]);
    new ResizeObserver(() => worker.postMessage({ type: 'resize', ...size() })).observe(canvas);
    aim = (t) => worker.postMessage({ type: 'target', target: t });
    paintAt = () => {};
    retune = () => worker.postMessage({ type: 'params', params: { ...params } });
  } else {
    const ctx = canvas.getContext('2d');
    aim = () => {};
    paintAt = () => paint(ctx, canvas.width, canvas.height, progress, params);
    retune = paintAt;
    new ResizeObserver(() => {
      Object.assign(canvas, size());
      paintAt();
    }).observe(canvas);
  }
  showStory(progress);

  // Without .is-live the section is a plain stacked page: every caption and the
  // finished night, which is also what reduced motion and no script get.
  if (!reduced.matches) {
    track.classList.add('is-live');
    // While the section is on screen, read its position once a frame and
    // glide the drawn story towards it, so a mouse wheel's coarse steps or a
    // flick still draw smoothly at the display's rate. Off screen, once the
    // glide has landed, nothing runs at all.
    let visible = false;
    let looping = false;
    let target = progress;
    let last = 0;
    const frame = (now) => {
      if (visible) {
        const box = track.getBoundingClientRect();
        const travel = Math.max(1, box.height - innerHeight);
        const t = Math.min(1, Math.max(0, -box.top / travel));
        if (t !== target) {
          target = t;
          aim(t);
        }
      }
      const step = 1 - Math.exp(-Math.min(64, now - last) / params.followMs);
      last = now;
      let next = progress + (target - progress) * step;
      if (Math.abs(target - next) < 0.0002) next = target;
      if (next !== progress) {
        progress = next;
        showStory(progress);
        paintAt();
      }
      looping = visible || progress !== target;
      if (looping) requestAnimationFrame(frame);
    };
    new IntersectionObserver(([entry]) => {
      visible = entry.isIntersecting;
      if (visible && !looping) {
        looping = true;
        last = performance.now();
        requestAnimationFrame(frame);
      }
    }).observe(track);
  }

  if (location.hash === '#tune') {
    import('./tune.js').then(({ register }) =>
      register({
        name: 'The night',
        params,
        defaults: DEFAULTS,
        pinned: ['dotsEnd', 'relayEnd'],
        ranges: {
          phoneEnd: [0.05, 0.4, 0.01],
          dotsFrom: [0.1, 0.5, 0.01],
          dotsEnd: [0.2, 0.7, 0.01],
          relayFrom: [0.3, 0.8, 0.01],
          relayEnd: [0.4, 0.95, 0.01],
          catchUpFrom: [0.5, 0.98, 0.01],
          catchUpEnd: [0.6, 1, 0.01],
          sleepsAt: [30, 300, 1],
          wakesAt: [300, 540, 1],
          dipDepth: [0, 80, 1],
          dipWidth: [1, 20, 0.5],
          followMs: [5, 400, 5],
        },
        onChange: () => {
          placeEvents();
          showStory(progress);
          retune();
        },
        onReplay: () => track.scrollIntoView({ behavior: reduced.matches ? 'auto' : 'smooth' }),
      }),
    );
  }
}
