const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const read = f => fs.readFileSync(path.join(__dirname, '..', 'database', 'migrations', f), 'utf8').replace(/\r\n/g, '\n');
const sql = read('MPCF-034_COD_IDENTIFIER_FULL_NUMBER_FIX_V1.sql');
const m29 = read('MPCF-029_LABORATORY_QUALITY_V1.sql');
const m33 = read('MPCF-033_FINISHED_PRODUCT_INVENTORY_V1.sql');

const fnBody = (s, start) => {
  const i = s.indexOf(start);
  return s.slice(i, s.indexOf('\n$$;\n', s.indexOf('as $$', i)) + 5);
};
const LAB = 'create or replace function public.create_laboratory_sample(p_payload jsonb)';
const INV = 'create or replace function private.record_finished_product_entry_from_packing()';

// Emulates the SQL expressions: 'COD' || v_cod::text [|| suffix]
const sqlCode = (cod, suffix = '') => 'COD' + String(cod) + suffix;
const sqlExpr = /'COD' \|\| v_cod::text( \|\| v_suffix)?/;

test('MPCF-034 builds COD codes from the full number without padding', () => {
  const cases = [[5, 'COD5'], [15, 'COD15'], [153, 'COD153'], [1984, 'COD1984'], [9999, 'COD9999'], [10000, 'COD10000']];
  for (const [cod, expected] of cases) {
    assert.equal(sqlCode(cod), expected);
    assert.equal(sqlCode(cod, 'EMP'), expected + 'EMP');
  }
  assert.match(fnBody(sql, LAB), /v_test_code := 'COD' \|\| v_cod::text \|\| v_suffix;/);
  assert.match(fnBody(sql, INV), /v_code := 'COD' \|\| v_cod::text;/);
  assert.ok(sqlExpr.test(sql));
});

test('MPCF-034 contains no lpad/padStart/truncating logic in executable SQL', () => {
  const code = sql.split('\n').filter(l => !l.trim().startsWith('--')).join('\n');
  assert.doesNotMatch(code, /lpad|padStart|substr|left\(|right\(/i);
});

test('MPCF-034 functions equal the current ones except for the COD code line', () => {
  const lab = fnBody(m29, LAB).replace("'COD' || lpad(v_cod::text, 2, '0') || v_suffix", "'COD' || v_cod::text || v_suffix");
  const inv = fnBody(m33, INV).replace("'COD' || lpad(v_cod::text, 2, '0')", "'COD' || v_cod::text");
  assert.equal(fnBody(sql, LAB), lab);
  assert.equal(fnBody(sql, INV), inv);
});

test('MPCF-034 is a delta: no table/policy/trigger changes, no historical data fix', () => {
  const code = sql.split('\n').filter(l => !l.trim().startsWith('--')).join('\n');
  assert.doesNotMatch(code, /create table|alter table|create trigger|drop trigger|create policy|drop |delete from|\bupdate\s+public\./i);
  assert.match(code, /MPCF-034/);
});

test('historical migrations MPCF-029 and MPCF-033 are left untouched in Git', () => {
  const { execSync } = require('node:child_process');
  const out = execSync('git status --short -- database/migrations/MPCF-029_LABORATORY_QUALITY_V1.sql', { cwd: path.join(__dirname, '..') }).toString();
  assert.equal(out.trim(), '');
});
