const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const sql = fs.readFileSync(path.join(__dirname, '..', 'database', 'migrations', 'MPCF-033_FINISHED_PRODUCT_INVENTORY_V1.sql'), 'utf8').replace(/\r\n/g, '\n');
const html = fs.readFileSync(path.join(__dirname, '..', 'index.html'), 'utf8').replace(/\r\n/g, '\n');

test('MPCF-033 entry comes from EMPAQUE COMPLETADO using packing_quantity_kg, idempotent', () => {
  assert.match(sql, /new\.event_type <> 'EMPAQUE'/);
  assert.match(sql, /new\.stage_status <> 'COMPLETADA'/);
  assert.match(sql, /new\.packing_quantity_kg, 'kg'/);
  assert.match(sql, /on conflict \(source_event_id\)/);
  assert.match(sql, /finished_product_movements_entry_uidx[\s\S]*where movement_type = 'ENTRADA'/);
  assert.match(sql, /after insert or update of stage_status, packing_quantity_kg on public\.production_process_events/);
});

test('MPCF-033 balance is derived, ledger is append-only and no overdraw', () => {
  const productsTable = sql.match(/create table if not exists public\.finished_products \([\s\S]*?\n\);/)[0];
  assert.doesNotMatch(productsTable, /balance|quantity|status/);
  assert.match(sql, /append-only/);
  assert.match(sql, /SALIDA exceeds finished product balance/);
  assert.match(sql, /movement_type in \('ENTRADA', 'SALIDA'\)/);
  assert.match(sql, /product_type in \('COD', 'ISOL'\)/);
});

test('MPCF-033 has RLS, no write grants, read-only RPCs and no manual entry RPC', () => {
  assert.match(sql, /alter table public\.finished_products enable row level security/);
  assert.match(sql, /alter table public\.finished_product_movements enable row level security/);
  assert.match(sql, /revoke all on public\.finished_products from public, anon, authenticated/);
  assert.doesNotMatch(sql, /grant (insert|update|delete)/i);
  assert.match(sql, /grant execute on function public\.get_finished_product_inventory\(\) to authenticated/);
  assert.doesNotMatch(sql, /create or replace function public\.(register|create|add|insert|update)_/);
});

test('MPCF-033 does not touch Production, Laboratory or other migrations', () => {
  assert.doesNotMatch(sql, /create or replace function public\.(register_packing|consume_material_transaction|set_laboratory_sample_status)/);
  assert.doesNotMatch(sql, /alter table public\.(production_|laboratory_)/);
  assert.doesNotMatch(sql, /drop table|truncate|delete from/i);
});

test('Inventory screen renders real columns, COD/ISOL type, no demo and no edit', () => {
  const start = html.indexOf('async function inventario()');
  const end = html.indexOf('bootAuth();', start);
  const code = html.slice(start, end);
  for (const col of ['Código', 'Tipo', 'Cantidad disponible', 'Unidad', '% CBD', 'Color', 'Estado', 'Fecha ingreso']) {
    assert.ok(code.includes('<th>' + col + '</th>'), col);
  }
  assert.ok(code.includes("rpc('get_finished_product_inventory')"));
  assert.ok(code.includes("rpc('get_finished_product_movements'"));
  assert.ok(!/DB\./.test(code));
  assert.ok(!/<input|\.insert\(|\.update\(/.test(code));
  assert.ok(html.includes("view('inventario',this)"));
  assert.ok(html.includes('inventario:inventario'));
});
