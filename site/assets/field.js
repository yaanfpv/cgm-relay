// Plays the hero's minute field once, when the page opens: on a worker where
// the browser can hand it the canvas, on the main thread otherwise. Reduced
// motion shows every minute lit straight away. With #tune in the address the
// field's timings join the debug tuning panel.
import { paint, finishedAt, DEFAULTS } from './field-paint.js';

const figure = document.querySelector('[data-field]');
const canvas = figure && figure.querySelector('canvas');

if (canvas) {
  // The stylesheet draws a plain field of dots for a browser running no script;
  // this hands the field over to the canvas.
  figure.classList.add('is-drawn');
  const reduced = matchMedia('(prefers-reduced-motion: reduce)');
  const params = { ...DEFAULTS };
  const size = () => {
    const box = canvas.getBoundingClientRect();
    const ratio = Math.min(window.devicePixelRatio || 1, 2);
    return { width: Math.round(box.width * ratio), height: Math.round(box.height * ratio) };
  };
  const finish = () => figure.classList.add('is-finished');
  let play;
  let setParams;

  if ('transferControlToOffscreen' in canvas && typeof Worker === 'function') {
    const worker = new Worker(new URL('./field-worker.js', import.meta.url), { type: 'module' });
    const offscreen = canvas.transferControlToOffscreen();
    worker.postMessage({ type: 'init', canvas: offscreen, finished: reduced.matches, ...size() }, [offscreen]);
    worker.onmessage = ({ data }) => data.type === 'finished' && finish();
    new ResizeObserver(() => worker.postMessage({ type: 'resize', ...size() })).observe(canvas);
    play = () => worker.postMessage({ type: 'play' });
    setParams = () => worker.postMessage({ type: 'params', params: { ...params } });
  } else {
    const ctx = canvas.getContext('2d');
    let startedAt = null;
    let looping = false;
    // render paints the frame for now; only loop schedules the next one, so a
    // resize or a tuning change mid-play never starts a second chain.
    const render = (now) => {
      const end = finishedAt(params);
      const t = reduced.matches ? end : startedAt === null ? 0 : (now - startedAt) / 1000;
      paint(ctx, canvas.width, canvas.height, t, params);
      if (t >= end) finish();
      return t < end;
    };
    const loop = (now) => {
      looping = render(now) && startedAt !== null;
      if (looping) requestAnimationFrame(loop);
    };
    new ResizeObserver(() => {
      Object.assign(canvas, size());
      render(performance.now());
    }).observe(canvas);
    play = () => {
      startedAt = performance.now();
      if (!looping) {
        looping = true;
        requestAnimationFrame(loop);
      }
    };
    setParams = () => render(performance.now());
  }

  if (reduced.matches) finish();
  else play();

  if (location.hash === '#tune') {
    import('./tune.js').then(({ register }) =>
      register({
        name: 'The minute field',
        params,
        defaults: DEFAULTS,
        pinned: [],
        ranges: {
          sparseFrom: [0, 3, 0.05],
          sparseSeconds: [0.2, 5, 0.1],
          waveFrom: [0.5, 6, 0.05],
          waveSeconds: [0.5, 8, 0.1],
          dotScale: [0.1, 0.5, 0.01],
        },
        onChange: setParams,
        onReplay: () => {
          figure.classList.remove('is-finished');
          play();
        },
      }),
    );
  }
}
