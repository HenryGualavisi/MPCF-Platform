const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');

const root = path.join(__dirname, '..');
const html = fs.readFileSync(path.join(root, 'index.html'), 'utf8');
const sql = fs.readFileSync(
  path.join(root, 'database', 'migrations', 'MPCF-031_LABORATORY_REALTIME_HISTORY_V1.sql'),
  'utf8'
);
const executableSql = sql.replace(/--.*$/gm, '');

function getFunctionDefinition(name) {
  const source = html.split(/\r?\n/).filter(line => line.startsWith(`function ${name}(`)).pop();
  assert.ok(source, `Expected function ${name} to exist in index.html`);
  return source;
}

test('Laboratory subscribes to shared production and laboratory realtime sources', () => {
  assert.match(html, /channel\(`laboratory-/);
  assert.match(html, /on\('postgres_changes',\{event:'\*',schema:'public',table\},scheduleLaboratoryRefresh\)/);
  for (const table of [
    'production_inputs',
    'production_orders',
    'production_process_events',
    'biomass_receptions',
    'big_bags',
    'organizations',
    'laboratory_samples',
    'laboratory_tests',
    'laboratory_results'
  ]) {
    assert.match(html, new RegExp(`'${table}'`));
  }
  assert.match(html, /stopLaboratoryRealtime\(\);laboratoryViewBeforeCp15/);
});

test('operational and historical lists use packaging validation and cap history at seven', () => {
  assert.match(sql, /s\.sample_type = 'STAGE_OUTPUT'[\s\S]*?s\.analytical_status = 'VALIDADO'[\s\S]*?e\.event_type = 'EMPAQUE'/);
  assert.match(html, /all\.filter\(order=>!order\.laboratory_completed\)/);
  assert.match(html, /all\.filter\(order=>order\.laboratory_completed\)[\s\S]*?\.slice\(0,7\)/);
  assert.match(html, /history\.map\(order=>row\(order,true\)\)/);
  assert.match(html, /readOnly\?'Ver':'Abrir'/);
});

test('rendered history shows exactly the seven newest completions and keeps completed production operational until packaging validation', () => {
  let rendered = '';
  const context = vm.createContext({
    LABORATORY_STATE: {
      orders: [
        { id: 'open', cod: 120, production_date: '2026-10-01', status: 'CERRADA', laboratory_completed: false },
        ...Array.from({ length: 9 }, (_, index) => ({
          id: `done-${index + 1}`,
          cod: index + 1,
          production_date: `2026-09-${String(index + 1).padStart(2, '0')}`,
          status: 'CERRADA',
          laboratory_completed: true,
          laboratory_completed_at: `2026-09-${String(index + 1).padStart(2, '0')}T12:00:00Z`
        }))
      ],
      context: null,
      orderId: null,
      readOnly: false,
      realtimeMessage: null,
      realtimeError: false
    },
    document: { getElementById: () => ({ set innerHTML(value) { rendered = value; } }) },
    esc: value => String(value ?? ''),
    renderLaboratoryContext() {},
    updateLaboratoryRealtimeStatus() {}
  });

  vm.runInContext(getFunctionDefinition('renderLaboratoryOrders'), context);
  vm.runInContext('renderLaboratoryOrders()', context);

  assert.match(rendered, /COD120/);
  assert.match(rendered, /COD09/);
  assert.match(rendered, /COD03/);
  assert.doesNotMatch(rendered, /COD02|COD01/);
  assert.equal((rendered.match(/>Ver<\/button>/g) || []).length, 7);
  assert.equal((rendered.match(/>Abrir<\/button>/g) || []).length, 1);
});

test('historical COD are read-only in the UI and guarded against database writes', () => {
  assert.match(html, /if\(!LABORATORY_STATE\.readOnly\)return;const target=document\.getElementById\('laboratory_context'\)/);
  assert.match(html, /target\.querySelectorAll\('button'\)\.forEach\(button=>button\.remove\(\)\)/);
  assert.match(html, /if\(LABORATORY_STATE\.readOnly\)\{alert\('El COD completado es solo lectura\.'/);
  assert.match(sql, /before insert or update or delete on public\.laboratory_samples/);
  assert.match(sql, /before insert or update or delete on public\.laboratory_results/);
  assert.match(sql, /create trigger laboratory_tests_completed_order_read_only\s+before insert or update or delete on public\.laboratory_tests\s+for each row execute function private\.prevent_laboratory_completed_order_mutations\(\)/);
  assert.match(sql, /completed laboratory order is read-only/);
  const mpcf029 = fs.readFileSync(path.join(__dirname, '..', 'database', 'migrations', 'MPCF-029_LABORATORY_QUALITY_V1.sql'), 'utf8');
  assert.match(mpcf029, /update public\.laboratory_tests\s+set analytical_status = p_status[\s\S]*?update public\.laboratory_samples\s+set analytical_status = p_status/);
  assert.doesNotMatch(sql, /delete\s+from\s+public\.(production_orders|laboratory_samples|laboratory_tests|laboratory_results)/i);
});

test('CP15 migration is additive and changes only the read privilege required by Realtime', () => {
  assert.match(sql, /create or replace function public\.get_laboratory_orders\(\)/);
  assert.match(sql, /alter publication supabase_realtime add table/);
  assert.match(sql, /grant select on public\.laboratory_samples, public\.laboratory_tests, public\.laboratory_results\s+to authenticated/i);
  assert.doesNotMatch(executableSql, /create table|alter table|create policy|drop policy|grant (?:insert|update|delete|all)|grant execute|get_laboratory_lfw|composition_code/i);
});
