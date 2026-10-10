const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const sql = fs.readFileSync(path.join(__dirname, '..', 'database', 'migrations', 'MPCF-037_COD_CANONICAL_4DIGIT_V1.sql'), 'utf8').replace(/\r\n/g, '\n');
const code = sql.split('\n').filter(l => !l.trim().startsWith('--')).join('\n');
const fnBody = start => {
  const i = sql.indexOf(start);
  return sql.slice(i, sql.indexOf('\n$$;\n', sql.indexOf('as $$', i)) + 5);
};
const LAB = fnBody('create or replace function public.create_laboratory_sample(p_payload jsonb)');
const INV = fnBody('create or replace function private.record_finished_product_entry_from_packing()');

// Emulates the SQL: guard 1..9999, then 'COD' || lpad(cod::text, 4, '0') [|| suffix]
const sqlCode = (cod, suffix = '') => {
  if (!Number.isInteger(cod) || cod < 1 || cod > 9999) throw new Error('VALIDATION: cod must be between 1 and 9999');
  return 'COD' + String(cod).padStart(4, '0') + suffix;
};

test('canonical COD codes use exactly four digits', () => {
  const cases = [[1, 'COD0001'], [15, 'COD0015'], [153, 'COD0153'], [501, 'COD0501'], [1984, 'COD1984'], [9999, 'COD9999']];
  for (const [cod, expected] of cases) {
    assert.equal(sqlCode(cod), expected);
    assert.equal(sqlCode(cod).length, 7);
  }
  for (const suffix of ['BIO', 'RES', 'EXT', 'DEC', 'EMP']) assert.equal(sqlCode(153, suffix), 'COD0153' + suffix);
});

test('COD 0 and 10000 are rejected, with no rollover', () => {
  assert.throws(() => sqlCode(0), /VALIDATION/);
  assert.throws(() => sqlCode(10000), /VALIDATION/);
  assert.throws(() => sqlCode(-1), /VALIDATION/);
  assert.doesNotMatch(code, /mod\s*\(|%\s*10000|rollover/i);
});

test('both generators use lpad to four digits and validate the 1..9999 range', () => {
  assert.match(LAB, /v_test_code := 'COD' \|\| lpad\(v_cod::text, 4, '0'\) \|\| v_suffix;/);
  assert.match(INV, /v_code := 'COD' \|\| lpad\(v_cod::text, 4, '0'\);/);
  for (const body of [LAB, INV]) {
    assert.match(body, /v_cod is null or v_cod not between 1 and 9999/);
    assert.match(body, /raise exception 'VALIDATION: cod must be between 1 and 9999'/);
  }
  assert.doesNotMatch(code, /substr|left\(|right\(/i);
});

test('existing validations, permissions, suffixes and idempotency are preserved', () => {
  assert.match(LAB, /private\.current_user_has_permission\('laboratorio\.write'\)/);
  for (const s of ["'BIO'", "'RES'", "'EXT'", "'DEC'", "'EMP'"]) assert.ok(LAB.includes(s), s);
  assert.match(LAB, /on conflict do nothing returning id into v_sample_id/);
  assert.match(LAB, /on conflict \(sample_id\) do nothing/);
  assert.match(INV, /on conflict \(source_event_id\) where source_event_id is not null do nothing/);
  assert.match(INV, /where movement_type = 'ENTRADA' do nothing/);
  assert.match(code, /grant execute on function public\.create_laboratory_sample\(jsonb\) to authenticated;/);
  assert.match(code, /revoke all on function private\.record_finished_product_entry_from_packing\(\) from public, anon, authenticated;/);
});

test('constraints are mandatory: preflight aborts explicitly, nothing is skipped silently', () => {
  assert.match(code, /production_orders_cod_range_check check \(cod between 1 and 9999\)/);
  assert.match(code, /production_orders_organization_cod_uidx\s+on public\.production_orders\(organization_id, cod\)/);
  assert.match(code, /if v_out_of_range > 0 then\s+raise exception 'MPCF-037 BLOQUEO/);
  assert.match(code, /if v_duplicates > 0 then\s+raise exception 'MPCF-037 BLOQUEO/);
  assert.doesNotMatch(code, /raise notice/i);
  assert.doesNotMatch(code, /if v_out_of_range = 0|if v_duplicates = 0/);
  assert.doesNotMatch(code, /delete from|truncate|\bupdate\s+public\.|create table|create trigger|create policy|alter column|drop (table|index|function|policy|trigger)/i);
});

test('preflight runs before any function or constraint change', () => {
  const pre = code.indexOf("raise exception 'MPCF-037 BLOQUEO: % orden(es)");
  assert.ok(pre > 0);
  assert.ok(pre < code.indexOf('create or replace function'));
  assert.ok(pre < code.indexOf('add constraint production_orders_cod_range_check'));
  assert.ok(pre < code.indexOf('create unique index'));
});

test('no explicit transaction control (single multi-statement script) and registers MPCF-037 only after verifying constraints', () => {
  assert.doesNotMatch(code, /^\s*(begin|commit|rollback);/mi);
  const verify = code.indexOf("raise exception 'MPCF-037 FALLO: production_orders_cod_range_check");
  const verifyIdx = code.indexOf("raise exception 'MPCF-037 FALLO: production_orders_organization_cod_uidx");
  const register = code.indexOf('insert into public.schema_migrations');
  assert.ok(verify > 0 && verifyIdx > verify);
  assert.ok(register > verifyIdx);
  assert.match(code, /convalidated/);
  assert.match(code, /indisunique and i\.indisvalid and i\.indpred is null/);
  assert.match(code, /array\['organization_id', 'cod'\]/);
  assert.equal((code.match(/insert into public\.schema_migrations/g) || []).length, 1);
});
test('MPCF-037 does not touch historical data, inventory, ISOL or sales', () => {
  assert.doesNotMatch(code, /product_isol|sales_orders|laboratory_results/);
  assert.doesNotMatch(code, /(alter|drop|create)\s+(table|index|unique index)[^;]*finished_product/i);
  assert.match(code, /MPCF-037/);
  assert.match(sql, /Ejecucion NO CONFIRMADA/);
  assert.doesNotMatch(code, /alter table public\.(finished|laboratory|sales|product_isol)|(update|delete from)\s+public\.(finished|laboratory|sales|product_isol)/i);
});

const PO = fnBody('create or replace function public.create_production_order(p_payload jsonb)');
const m26 = fs.readFileSync(path.join(__dirname, '..', 'database', 'migrations', 'MPCF-026_PRODUCTION_V1.sql'), 'utf8').replace(/\r\n/g, '\n');
const PO26 = (() => {
  const i = m26.indexOf('create or replace function public.create_production_order(p_payload jsonb)');
  return m26.slice(i, m26.indexOf('\n$$;\n', m26.indexOf('as $$', i)) + 5);
})();

test('create_production_order: COD unique per organization (no date), range 1..9999, no rollover', () => {
  assert.match(PO, /v_cod is not null and v_cod not between 1 and 9999/);
  assert.match(PO, /raise exception 'VALIDATION: cod must be between 1 and 9999'/);
  const dup = PO.slice(PO.indexOf('if exists ('), PO.indexOf("'DUPLICATE"));
  assert.match(dup, /organization_id = v_organization_id\s+and cod = v_cod/);
  assert.doesNotMatch(dup, /production_date/);
  assert.match(PO, /select coalesce\(max\(po\.cod\), 0\) \+ 1 into v_cod/);
  assert.match(PO, /if v_cod > 9999 then\s+raise exception 'VALIDATION: COD range exhausted \(max 9999\)'/);
  assert.doesNotMatch(PO, /mod\s*\(|%\s*10000/i);
});

test('create_production_order: concurrent creations are serialized per organization before assign/check/insert', () => {
  const lock = PO.indexOf("pg_advisory_xact_lock(hashtextextended(v_organization_id::text || ':PRODUCTION_COD', 0))");
  assert.ok(lock > 0);
  assert.ok(lock < PO.indexOf('select coalesce(max(po.cod)'));
  assert.ok(lock < PO.indexOf('if exists ('));
  assert.ok(lock < PO.indexOf('insert into public.production_orders'));
});

test('create_production_order keeps MPCF-026 auth, permission, organization, status and version validations', () => {
  for (const s of [
    "if v_user is null then raise exception 'AUTH_REQUIRED'; end if;",
    "private.current_user_has_permission('produccion.write')",
    "raise exception 'PERMISSION_DENIED: produccion.write';",
    "raise exception 'ORGANIZATION_REQUIRED'",
    "raise exception 'VALIDATION: production_date is required'",
    "raise exception 'VALIDATION: new production must be PROGRAMADA'",
    "raise exception 'VALIDATION: process_version must be V1'",
    'security definer',
    'set search_path = public, private, pg_catalog'
  ]) { assert.ok(PO.includes(s), s); assert.ok(PO26.includes(s), 'baseline ' + s); }
  assert.match(PO, /'cod',v_cod,\s+'cod_code','COD' \|\| lpad\(v_cod::text, 4, '0'\),/);
  assert.match(PO, /cod integer|v_cod integer/);
  assert.match(code, /revoke all on function public\.create_production_order\(jsonb\) from public;/);
  assert.match(code, /grant execute on function public\.create_production_order\(jsonb\) to authenticated;/);
});

test('preconditions abort if MPCF-029/033 objects are missing, before any change', () => {
  for (const rel of ['production_orders', 'production_process_events', 'laboratory_samples', 'laboratory_tests', 'finished_products', 'finished_product_movements', 'schema_migrations']) {
    assert.ok(code.includes(`('public.${rel}')`), rel);
  }
  assert.match(code, /raise exception 'MPCF-037 PRECONDICION: faltan tablas requeridas/);
  assert.match(code, /tg\.tgname = 'production_packing_finished_product_entry'/);
  assert.match(code, /p\.proname = 'current_user_has_permission'/);
  const pre = code.indexOf("raise exception 'MPCF-037 PRECONDICION: faltan tablas");
  assert.ok(pre > 0 && pre < code.indexOf("raise exception 'MPCF-037 BLOQUEO: % orden(es)"));
  assert.ok(pre < code.indexOf('create or replace function'));
});