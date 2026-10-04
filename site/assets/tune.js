// The debug tuning panel, loaded only when the address ends in #tune. Each
// component registers its own group of numbers and gets its change callback;
// unregistering removes the group. A small strip in the corner holds the one
// or two numbers being dialled in, and the full panel holds every group.
// Hotkeys: T shows or hides the panel, R replays, C copies the current values.

const groups = new Map();
let panel = null;
let strip = null;

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

function slider(group, key) {
  const [min, max, step] = group.ranges[key] || [0, 100, 1];
  const row = el('label', 'tune-row');
  const name = el('span', 'tune-name', key);
  const input = el('input');
  Object.assign(input, { type: 'range', min, max, step, value: group.params[key] });
  const value = el('output', 'tune-value', String(group.params[key]));
  input.addEventListener('input', () => {
    group.params[key] = Number(input.value);
    value.textContent = input.value;
    for (const other of document.querySelectorAll(`[data-tune="${group.name}:${key}"]`)) {
      if (other !== input) other.value = input.value;
    }
    group.onChange();
  });
  input.dataset.tune = `${group.name}:${key}`;
  row.append(name, input, value);
  return row;
}

function values() {
  const out = {};
  for (const [name, group] of groups) out[name] = { ...group.params };
  return JSON.stringify(out, null, 2);
}

function copy() {
  navigator.clipboard?.writeText(values());
}

function render() {
  panel?.remove();
  strip?.remove();
  strip = el('div', 'tune-strip');
  panel = el('div', 'tune-panel');
  panel.hidden = true;
  panel.append(el('p', 'tune-help', 'T panel · R replay · C copy values'));
  for (const group of groups.values()) {
    for (const key of group.pinned || []) strip.append(slider(group, key));
    const section = el('fieldset', 'tune-group');
    section.append(el('legend', '', group.name));
    for (const key of Object.keys(group.params)) section.append(slider(group, key));
    const actions = el('div', 'tune-actions');
    const replay = el('button', '', 'Replay');
    replay.addEventListener('click', group.onReplay);
    const reset = el('button', '', 'Reset');
    reset.addEventListener('click', () => {
      Object.assign(group.params, group.defaults);
      group.onChange();
      render();
      panel.hidden = false;
    });
    actions.append(replay, reset);
    section.append(actions);
    panel.append(section);
  }
  const copyButton = el('button', 'tune-copy', 'Copy current values');
  copyButton.addEventListener('click', copy);
  panel.append(copyButton);
  const toggle = el('button', 'tune-toggle', 'Tune');
  toggle.addEventListener('click', () => (panel.hidden = !panel.hidden));
  strip.prepend(toggle);
  document.body.append(panel, strip);
}

export function register(group) {
  groups.set(group.name, group);
  render();
  return () => {
    groups.delete(group.name);
    render();
  };
}

addEventListener('keydown', (event) => {
  if (event.target instanceof HTMLInputElement || event.metaKey || event.ctrlKey) return;
  const key = event.key.toLowerCase();
  if (key === 't' && panel) panel.hidden = !panel.hidden;
  if (key === 'r') for (const group of groups.values()) group.onReplay();
  if (key === 'c') copy();
});

console.info('Tuning panel: T shows or hides it, R replays, C copies the current values.');
