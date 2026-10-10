const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { execSync } = require('node:child_process');

const root = path.join(__dirname, '..');
const read = f => fs.readFileSync(path.join(root, 'database', 'migrations', f), 'utf8').replace(/\r\n/g, '\n');
const m34 = read('MPCF-034_COD_IDENTIFIER_FULL_NUMBER_FIX_V1.sql');
const m37 = read('MPCF-037_COD_CANONICAL_4DIGIT_V1.sql');
const m29 = read('MPCF-029_LABORATORY_QUALITY_V1.sql');
const m33 = read('MPCF-033_FINISHED_PRODUCT_INVENTORY_V1.sql');

const fnBody = (s, start) => {
  const i = s.indexOf(start);
  return s.slice(i, s.indexOf('\n$$;\n', s.indexOf('as $$', i)) + 5);
};
const LAB = 'create or replace function public.create_laboratory_sample(p_payload jsonb)';
const INV = 'create or replace function private.record_finished_product_entry_from_packing()';
const noComments = s => s.split('\n').filter(l => !l.trim().startsWith('--')).join('\n');

test('MPCF-034 stays as historical SQL (unmodified, superseded by MPCF-037)', () => {
  const out = execSync('git status --short -- database/migrations/MPCF-034_COD_IDENTIFIER_FULL_NUMBER_FIX_V1.sql', { cwd: root }).toString();
  assert.equal(out.trim(), '');
  assert.match(m34, /v_test_code := 'COD' \|\| v_cod::text \|\| v_suffix;/);
});

test('the current (4-digit) rule lives in MPCF-037, not in MPCF-034', () => {
  assert.match(fnBody(m37, LAB), /v_test_code := 'COD' \|\| lpad\(v_cod::text, 4, '0'\) \|\| v_suffix;/);
  assert.match(fnBody(m37, INV), /v_code := 'COD' \|\| lpad\(v_cod::text, 4, '0'\);/);
  assert.doesNotMatch(noComments(m37), /'COD' \|\| v_cod::text/);
});

test('MPCF-037 functions equal MPCF-034 except for the 4-digit code and the 1..9999 guard', () => {
  const guard = "  if v_cod is null or v_cod not between 1 and 9999 then\n    raise exception 'VALIDATION: cod must be between 1 and 9999';\n  end if;\n";
  const lab = fnBody(m34, LAB)
    .replace("'COD' || v_cod::text || v_suffix", "'COD' || lpad(v_cod::text, 4, '0') || v_suffix")
    .replace("  if not found then raise exception 'VALIDATION: production stage not found'; end if;\n", "  if not found then raise exception 'VALIDATION: production stage not found'; end if;\n" + guard);
  const inv = fnBody(m34, INV)
    .replace("  if not found then return new; end if;\n", "  if not found then return new; end if;\n" + guard)
    .replace("v_code := 'COD' || v_cod::text;", "v_code := 'COD' || lpad(v_cod::text, 4, '0');");
  assert.equal(fnBody(m37, LAB), lab);
  assert.equal(fnBody(m37, INV), inv);
});

test('historical migrations 029, 033, 034, 035 and 036 are left untouched in Git', () => {
  for (const f of ['MPCF-029_LABORATORY_QUALITY_V1.sql', 'MPCF-033_FINISHED_PRODUCT_INVENTORY_V1.sql', 'MPCF-034_COD_IDENTIFIER_FULL_NUMBER_FIX_V1.sql', 'MPCF-035_PRODUCT_ISOL_V1.sql', 'MPCF-036_SALES_V1.sql']) {
    const out = execSync(`git status --short -- database/migrations/${f}`, { cwd: root }).toString();
    assert.equal(out.trim(), '', f);
  }
  assert.ok(m29.includes('lpad(v_cod::text, 2'));
  assert.ok(m33.includes('lpad(v_cod::text, 2'));
});