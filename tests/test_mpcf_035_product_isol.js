const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.join(__dirname, '..');
const sql = fs.readFileSync(path.join(root, 'database', 'migrations', 'MPCF-035_PRODUCT_ISOL_V1.sql'), 'utf8').replace(/\r\n/g, '\n');
const inventorySql = fs.readFileSync(path.join(root, 'database', 'migrations', 'MPCF-033_FINISHED_PRODUCT_INVENTORY_V1.sql'), 'utf8').replace(/\r\n/g, '\n');
const html = fs.readFileSync(path.join(root, 'index.html'), 'utf8').replace(/\r\n/g, '\n');

function functionBody(signature) {
  const start = sql.indexOf(signature);
  assert.notEqual(start, -1, `Missing SQL function ${signature}`);
  const bodyStart = sql.indexOf('as $$', start);
  const end = sql.indexOf('\n$$;', bodyStart);
  assert.notEqual(end, -1, `Unclosed SQL function ${signature}`);
  return sql.slice(start, end + 4);
}

const dispatch = functionBody('create or replace function public.dispatch_finished_product(p_payload jsonb)');
const consolidate = functionBody('create or replace function public.consolidate_finished_products(p_payload jsonb)');
const lineage = functionBody('create or replace function public.get_product_isol_consolidation(p_isol_product_id uuid)');

test('MPCF-035 adds only operational records linked to the MOD-007 inventory ledger', () => {
  assert.match(sql, /create table public\.product_isol_operations/);
  assert.match(sql, /create table public\.product_isol_consolidation_inputs/);
  assert.match(sql, /finished_product_id uuid not null references public\.finished_products\(id\)/);
  assert.match(sql, /operation_id uuid not null[\s\S]*references public\.product_isol_operations\(id, organization_id\)/);
  assert.match(sql, /MPCF-035 PRODUCT \/ ISOL V1 PREPARED - NOT EXECUTED/);
  assert.doesNotMatch(sql, /drop table|truncate|delete from/i);
});

test('inventory screen uses live MOD-007 data and contains dispatch and consolidation controls', () => {
  const start = html.indexOf('async function productos()');
  const end = html.indexOf('function traza()', start);
  const productsView = html.slice(start, end);
  assert.match(productsView, /productIsolView/);
  assert.doesNotMatch(productsView, /DB\.isol|SEED\.isol/);
  assert.match(html, /rpc\('get_finished_product_inventory'\)/);
  assert.match(html, /DESPACHAR/);
  assert.match(html, /CONSOLIDAR/);
  assert.match(html, /product_type==='COD'&&Number\(item\.balance_kg\)>0/);
  assert.ok(html.includes("&&/^ISOL \\d{5}$/.test(String(item.product_code))?"));
});

test('partial COD and ISOL dispatch is validated and recorded as an inventory SALIDA', () => {
  assert.match(dispatch, /produccion\.write/);
  assert.match(dispatch, /AUTH_REQUIRED/);
  assert.match(dispatch, /organization_id = v_organization_id/);
  assert.match(dispatch, /v_quantity <= 0/);
  assert.match(dispatch, /quantity exceeds finished product balance/);
  assert.match(dispatch, /for update/);
  assert.match(dispatch, /'SALIDA', v_quantity/);
  assert.match(dispatch, /'PRODUCT_ISOL_DESPACHO'/);
  assert.match(html, /rpc\('dispatch_finished_product'/);
  assert.match(html, /quantity<=0/);
  assert.match(html, /quantity>Number\(selectedProduct\.balance_kg\)/);
});

test('dispatch rejects zero, negative, and over-balance quantities', () => {
  assert.match(dispatch, /v_quantity <= 0/);
  assert.match(dispatch, /v_quantity > v_balance/);
  assert.match(html, /quantity<=0/);
  assert.match(html, /quantity>Number\(selectedProduct\.balance_kg\)/);
});

test('dispatch prevents retries from creating duplicate movements', () => {
  assert.match(sql, /perform pg_advisory_xact_lock\(hashtextextended/);
  assert.match(sql, /product_isol_operations_request_uidx unique \(organization_id, request_id\)/);
  assert.match(dispatch, /request_payload <> p_payload/);
  assert.match(dispatch, /'replayed', true/);
  assert.match(sql, /finished_product_movements_product_isol_operation_uidx/);
});

test('consolidation accepts two or more COD inputs and validates every selected quantity', () => {
  assert.match(consolidate, /jsonb_typeof\(p_payload->'inputs'\) is distinct from 'array'/);
  assert.match(consolidate, /jsonb_array_length\(p_payload->'inputs'\) = 0/);
  assert.match(consolidate, /a COD may appear only once/);
  assert.match(consolidate, /every COD quantity must be > 0/);
  assert.match(consolidate, /COD quantity exceeds finished product balance/);
  assert.match(consolidate, /product_type = 'COD'/);
  assert.match(consolidate, /order by \(value->>'finished_product_id'\)::uuid/);
  assert.match(consolidate, /v_total := v_total \+ v_source_quantity/);
  assert.match(html, /querySelectorAll\('\[id\^="product_isol_select_"\]:checked'\)/);
  assert.match(html, /rpc\('consolidate_finished_products'/);
});

test('consolidation supports multiple inputs without a fixed COD count and checks availability per COD', () => {
  assert.equal((consolidate.match(/for v_input in/g) || []).length, 2);
  assert.match(consolidate, /v_source_quantity > v_source_balance/);
  assert.match(html, /input\.quantity_kg>Number\(item\.balance_kg\)/);
  assert.doesNotMatch(consolidate, /limit\s+\d+/i);
  assert.equal((consolidate.match(/jsonb_array_elements\(p_payload->'inputs'\)/g) || []).length, 6);
});

test('consolidation writes all source exits and a new ISOL entry in one RPC', () => {
  assert.match(consolidate, /v_new_product_code := 'ISOL ' \|\| to_char\(v_created_at, 'DDDYY'\)/);
  assert.match(consolidate, /v_new_product_id := gen_random_uuid\(\)/);
  assert.match(consolidate, /id, organization_id, product_type, product_code, product_name, unit, entered_at/);
  assert.match(consolidate, /DUPLICATE: an ISOL has already been generated for this organization and date/);
  assert.match(consolidate, /v_organization_id::text \|\| ':ISOL:' \|\| v_created_at::date::text/);
  assert.match(consolidate, /v_new_product_id, v_organization_id, 'ISOL', v_new_product_code/);
  assert.doesNotMatch(consolidate, /'ISOL-' \|\| upper\(v_new_product_id::text\)/);
  assert.match(consolidate, /insert into public\.product_isol_consolidation_inputs/);
  assert.match(consolidate, /'SALIDA', v_source_quantity/);
  assert.match(consolidate, /insert into public\.finished_product_movements[\s\S]*'ENTRADA', v_total/);
  assert.match(consolidate, /'PRODUCT_ISOL_CONSOLIDACION'/);
  assert.match(consolidate, /'quantity_kg', v_total/);
  assert.match(consolidate, /'replayed', false/);
});

test('ISOL DDDYY identifier follows creation day-of-year and two-digit year', () => {
  const date = new Date(Date.UTC(2026, 1, 10));
  const dayOfYear = Math.floor((date - Date.UTC(date.getUTCFullYear(), 0, 0)) / 86400000);
  const expected = 'ISOL ' + String(dayOfYear).padStart(3, '0') + String(date.getUTCFullYear()).slice(-2);
  assert.equal(expected, 'ISOL 04126');
  assert.match(consolidate, /to_char\(v_created_at, 'DDDYY'\)/);
  assert.match(consolidate, /entered_at[\s\S]*v_created_at/);
  assert.match(sql, /id uuid primary key default gen_random_uuid\(\)/);
  assert.doesNotMatch(consolidate, /product_code\s*:=\s*'ISOL-'|v_new_product_code\s*:=\s*'ISOL-' \|\|/);
});

test('same-organization ISOL generation is serialized and rejects a duplicate daily code', () => {
  const lock = consolidate.indexOf("':ISOL:' || v_created_at::date::text");
  const duplicateCheck = consolidate.indexOf('an ISOL has already been generated for this organization and date');
  const insert = consolidate.indexOf('insert into public.finished_products');
  assert.ok(lock > 0);
  assert.ok(duplicateCheck > lock);
  assert.ok(insert > duplicateCheck);
  assert.match(consolidate, /fp\.product_code = v_new_product_code/);
});

test('all consolidation outputs and the ISOL entry remain inside the same atomic RPC', () => {
  const sourceMovement = consolidate.indexOf("'SALIDA', v_source_quantity");
  const isolateEntry = consolidate.indexOf("'ENTRADA', v_total");
  const result = consolidate.indexOf("'replayed', false");
  assert.ok(sourceMovement > 0);
  assert.ok(isolateEntry > sourceMovement);
  assert.ok(result > isolateEntry);
  assert.match(consolidate, /raise exception 'VALIDATION:/);
});

test('COD-to-ISOL lineage returns each source COD and its consumed quantity', () => {
  assert.match(lineage, /produccion\.read/);
  assert.match(lineage, /src\.product_code/);
  assert.match(lineage, /ci\.quantity_kg/);
  assert.match(lineage, /'inputs'/);
  assert.match(html, /rpc\('get_product_isol_consolidation'/);
  assert.match(html, /Origen COD/);
});

test('operations and source links are private, append-only, and have no direct browser write grant', () => {
  assert.match(sql, /alter table public\.product_isol_operations enable row level security/);
  assert.match(sql, /alter table public\.product_isol_consolidation_inputs enable row level security/);
  assert.match(sql, /revoke all on public\.product_isol_operations from public, anon, authenticated/);
  assert.match(sql, /revoke all on public\.product_isol_consolidation_inputs from public, anon, authenticated/);
  assert.match(sql, /product_isol_operations_append_only/);
  assert.match(sql, /product_isol_consolidation_inputs_append_only/);
  assert.match(sql, /grant execute on function public\.dispatch_finished_product\(jsonb\) to authenticated/);
  assert.match(sql, /grant execute on function public\.consolidate_finished_products\(jsonb\) to authenticated/);
  assert.doesNotMatch(sql, /grant (insert|update|delete)/i);
});

test('balance is not stored in operation records and excess remains in the derived ISOL balance', () => {
  const operations = sql.match(/create table public\.product_isol_operations \([\s\S]*?\n\);/)[0];
  assert.doesNotMatch(operations, /\bbalance\b/i);
  assert.match(inventorySql, /'balance_kg', t\.entries_kg - t\.exits_kg/);
  assert.match(sql, /'balance_kg', v_balance - v_quantity/);
  assert.match(consolidate, /'quantity_kg', v_total/);
});
