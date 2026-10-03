const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const test = require('node:test');

const root = path.join(__dirname, '..');
const html = fs.readFileSync(path.join(root, 'index.html'), 'utf8');
const migration = fs.readFileSync(
  path.join(root, 'database', 'migrations', 'MPCF-029_LABORATORY_QUALITY_V1.sql'),
  'utf8'
);

function getFunctionLine(name) {
  const line = html.split(/\r?\n/).find(candidate =>
    candidate.startsWith(`function ${name}(`) ||
    candidate.startsWith(`async function ${name}(`)
  );
  assert.ok(line, `Expected ${name} to exist in index.html`);
  return line;
}

const laboratoryUi = vm.createContext({
  LABORATORY_ATTRIBUTES: {
    BIOMASS: [['CBDA_BIOMASS', 'CBDA BIOMASA']]
  },
  esc: value => String(value ?? '')
});
vm.runInContext([
  getFunctionLine('laboratorySampleIsOperational'),
  getFunctionLine('laboratoryResultMap'),
  getFunctionLine('laboratorySampleFor'),
  getFunctionLine('laboratoryResultForm')
].join('\n'), laboratoryUi);

test('validated sample remains historical but its capture form is closed', () => {
  const sample = {
    id: 'sample-a',
    sample_type: 'BIOMASS',
    analytical_status: 'VALIDADO',
    results: [{ attribute_code: 'CBDA_BIOMASS', result_value: 12.5 }]
  };

  laboratoryUi.sample = sample;
  const form = vm.runInContext('laboratoryResultForm(sample)', laboratoryUi);

  assert.match(form, /cerrada operativamente/i);
  assert.doesNotMatch(form, /Guardar resultados|Marcar resultados registrados|Validar/);
  assert.match(getFunctionLine('renderLaboratoryContext'), /samples\.map\(sample/);
  assert.match(getFunctionLine('renderLaboratoryContext'), /sample\.results/);
  assert.match(getFunctionLine('saveLaboratoryResults'), /laboratorySampleIsOperational\(sample\)/);
  assert.match(getFunctionLine('setLaboratoryStatus'), /laboratorySampleIsOperational\(sample\)/);
});

test('only an uncovered provider and lot combination has no existing sample', () => {
  const context = {
    samples: [{
      sample_type: 'BIOMASS',
      production_process_event_id: 'extraction',
      supplier_organization_id: 'provider-a',
      agricultural_lot_id: 'lot-a',
      analytical_status: 'VALIDADO'
    }]
  };
  const findSample = vm.runInContext('laboratorySampleFor', laboratoryUi);

  assert.equal(findSample(context, {
    production_process_event_id: 'extraction',
    supplier_organization_id: 'provider-a',
    agricultural_lot_id: 'lot-a'
  }, 'BIOMASS').analytical_status, 'VALIDADO');
  assert.equal(findSample(context, {
    production_process_event_id: 'extraction',
    supplier_organization_id: 'provider-b',
    agricultural_lot_id: 'lot-b'
  }, 'BIOMASS'), undefined);
});

test('result updates remain idempotent and validated samples reject further writes', () => {
  assert.match(migration, /on conflict \(test_id, sample_id, attribute_code\) do update set/);
  assert.match(migration, /if v_sample_status = 'VALIDADO' then[\s\S]*?operationally closed/);
  assert.match(migration, /if v_sample\.analytical_status = 'VALIDADO' then[\s\S]*?operationally closed/);
  assert.match(migration, /before insert or update or delete on public\.laboratory_results/);
  assert.match(migration, /before update or delete on public\.laboratory_samples/);
});

test('production analytical attributes remain read-only and LFW keeps its existing formula', () => {
  assert.match(migration, /create or replace function public\.get_production_laboratory_attributes/);
  assert.match(getFunctionLine('productionLaboratoryPanel'), /ATRIBUTOS ANALÍTICOS · SOLO LECTURA/);
  assert.match(migration, /sum\(covered_kg \* result_value\) \/ nullif\(sum\(covered_kg\), 0\) as weighted_value/);
  assert.match(migration, /where s\.analytical_status in \('RESULTADO REGISTRADO', 'VALIDADO'\)/);
});
