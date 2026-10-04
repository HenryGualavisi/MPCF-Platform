const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');

const root = path.join(__dirname, '..');
const html = fs.readFileSync(path.join(root, 'index.html'), 'utf8').replace(/\r\n/g, '\n');
const migrationsDir = path.join(root, 'database', 'migrations');
const read = name => fs.readFileSync(path.join(migrationsDir, name), 'utf8').replace(/\r\n/g, '\n');
const sql025 = read('MPCF-025_CONSUMPTION_TRANSACTION_MULTI_BIG_BAG_V1.sql');
const sql032 = read('MPCF-032_CONSUMPTION_BLOCK_AFTER_EXTRACTION_V1.sql');

function functionBody(sql) {
  const start = sql.indexOf('create or replace function public.consume_material_transaction');
  return sql.slice(start, sql.indexOf('$$;', start) + 3);
}

test('MPCF-032 only adds the EXTRACCION guard to consume_material_transaction', () => {
  const guard = /\n  if exists \(\n    select 1\n    from public\.production_process_events e\n    where e\.production_order_id = v_production_order_id\n      and e\.event_type = 'EXTRACCION'\n      and e\.stage_status = 'COMPLETADA'\n  \) then\n    raise exception 'VALIDATION: biomass consumption is blocked because EXTRACCION is already COMPLETADA for this production order';\n  end if;\n/;
  const body032 = functionBody(sql032);
  assert.match(body032, guard);
  assert.equal(body032.replace(guard, ''), functionBody(sql025));
});

test('MPCF-032 guard runs before any lock, availability update or production_inputs insert', () => {
  const body = functionBody(sql032);
  const guardAt = body.indexOf("e.event_type = 'EXTRACCION'");
  assert.ok(guardAt > body.indexOf('production_order not found for organization'));
  for (const marker of ['for update', 'update public.material_availability', 'insert into public.production_inputs', 'insert into public.material_movements']) {
    assert.ok(body.indexOf(marker) > guardAt, `${marker} must come after the guard`);
  }
});

test('MPCF-032 changes no tables or Laboratory objects and keeps grants', () => {
  const executable = sql032.split('\n').filter(line => !line.trim().startsWith('--')).join('\n');
  assert.doesNotMatch(executable, /create table|alter table|create policy|drop policy|create trigger|drop /i);
  assert.doesNotMatch(executable, /laboratory_|get_laboratory|create_laboratory|composition_code/i);
  assert.match(sql032, /revoke all on function public\.consume_material_transaction\(jsonb\) from public;/);
  assert.match(sql032, /grant execute on function public\.consume_material_transaction\(jsonb\) to authenticated;/);
  assert.equal((sql032.match(/create or replace function/g) || []).length, 1);
});

function consumirOptions(orders, completedOrderIds) {
  const source = html.match(/async function consumir\(availabilityId\)\{[\s\S]*?\n\}\n(?=async function guardarConsumo)/);
  assert.ok(source, 'consumir() must exist in index.html');
  let modalHtml = '';
  const queries = [];
  const client = {
    from(table) {
      const query = { table, filters: [] };
      queries.push(query);
      const chain = {
        select() { return chain; },
        order() { return chain; },
        eq(column, value) { query.filters.push([column, value]); return chain; },
        then(resolve) {
          if (table === 'production_orders') return resolve({ data: orders, error: null });
          const wanted = query.filters.some(([c, v]) => c === 'stage_status' && v === 'COMPLETADA') &&
            query.filters.some(([c, v]) => c === 'event_type' && v === 'EXTRACCION');
          return resolve({ data: wanted ? completedOrderIds.map(id => ({ production_order_id: id })) : [], error: null });
        }
      };
      return chain;
    }
  };
  const context = vm.createContext({
    AUTH_STATE: { client, session: {} },
    BODEGA_STATE: { inventory: [{ availability: { id: 'a1', material_type: 'BIOMASA', quantity_available_kg: 100, reception_id: 'r1' }, bigBag: null }] },
    esc: value => String(value ?? ''),
    formatKg: value => String(value),
    getConsumptionEntries: () => [],
    modal: (_title, body) => { modalHtml = body; },
    alert: message => { throw new Error(message); }
  });
  vm.runInContext(source[0], context);
  return vm.runInContext("consumir('a1')", context).then(() => ({ modalHtml, queries }));
}

const orders = [
  { id: 'pending', cod: 1, production_date: '2026-10-01', shift: 'A', status: 'ABIERTA' },
  { id: 'active', cod: 2, production_date: '2026-10-01', shift: 'A', status: 'EN_PROCESO' },
  { id: 'completed', cod: 3, production_date: '2026-10-01', shift: 'A', status: 'EN_PROCESO' }
];

test('consumption destinations keep COD with EXTRACCION pending or active and hide completed ones', async () => {
  const { modalHtml, queries } = await consumirOptions(orders, ['completed']);
  assert.match(modalHtml, /value="pending"/);
  assert.match(modalHtml, /value="active"/);
  assert.doesNotMatch(modalHtml, /value="completed"/);
  const stageQuery = queries.find(q => q.table === 'production_process_events');
  assert.deepEqual(stageQuery.filters, [['event_type', 'EXTRACCION'], ['stage_status', 'COMPLETADA']]);
});

test('without completed EXTRACCION the destination list is unchanged', async () => {
  const { modalHtml } = await consumirOptions(orders, []);
  for (const id of ['pending', 'active', 'completed']) assert.match(modalHtml, new RegExp(`value="${id}"`));
});

test('no Laboratory or CP15 object is touched by the consumption change', () => {
  const consumir = html.match(/async function consumir\(availabilityId\)\{[\s\S]*?\n\}\n(?=async function guardarConsumo)/)[0];
  assert.doesNotMatch(consumir, /laboratory|laboratorio/i);
});
