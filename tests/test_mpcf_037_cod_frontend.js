const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const html = fs.readFileSync(path.join(__dirname, '..', 'index.html'), 'utf8');
const src = html.match(/function codLabel\(value\)\{[^\n]*\}/)[0];
const ctx = { esc: s => String(s).replace(/[&<>"']/g, '?') };
vm.createContext(ctx);
vm.runInContext(src, ctx);

test('codLabel always renders COD plus four digits', () => {
  assert.equal(ctx.codLabel(1), 'COD0001');
  assert.equal(ctx.codLabel('153'), 'COD0153');
  assert.equal(ctx.codLabel(9999), 'COD9999');
  assert.equal(ctx.codLabel(null), '—');
});

test('codLabel never renders out-of-range values as canonical codes', () => {
  for (const bad of [0, 10000, -5, 1.5, 'abc']) assert.match(ctx.codLabel(bad), /^COD INVÁLIDO/);
});

test('index.html no longer builds COD labels by concatenation and caps the input at 9999', () => {
  assert.doesNotMatch(html, /COD \$\{esc\(|COD\$\{esc\(|'COD '\+esc\(|COD '\+esc\(opValue/);
  assert.match(html, /id="p_cod" type="number" min="1" max="9999" step="1"/);
  assert.match(html, /\$\{codLabel\(order\.cod\)\}/);
});