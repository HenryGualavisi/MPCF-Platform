const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');

const migrationPath = path.join(
  __dirname,
  '..',
  'database',
  'migrations',
  'MPCF-030_LABORATORY_COMPOSITION_CODE_FIX_V1.sql'
);
const sql = fs.readFileSync(migrationPath, 'utf8');

function expectedCompositionCode(consumption) {
  const providers = Object.entries(consumption)
    .map(([name, kilograms]) => ({ name, kilograms }))
    .sort((left, right) => left.name.localeCompare(right.name));
  const totalKilograms = providers.reduce((sum, provider) => sum + provider.kilograms, 0);

  if (providers.length === 1) return providers[0].name;

  const shares = providers.map(provider => {
    const exact = provider.kilograms * 100 / totalKilograms;
    return { ...provider, percent: Math.floor(exact), remainder: exact - Math.floor(exact) };
  });
  let pointsRemaining = 100 - shares.reduce((sum, provider) => sum + provider.percent, 0);

  for (const provider of [...shares].sort((left, right) =>
    right.remainder - left.remainder || left.name.localeCompare(right.name)
  )) {
    if (pointsRemaining === 0) break;
    provider.percent += 1;
    pointsRemaining -= 1;
  }

  return `M_${shares.map(provider => `${provider.name}_${provider.percent}`).join('_')}`;
}

test('MPCF-030 only replaces get_laboratory_lfw and retains the LFW formula', () => {
  assert.equal((sql.match(/create or replace function/gi) || []).length, 1);
  assert.match(sql, /create or replace function private\.get_laboratory_lfw\(p_production_order_id uuid\)/);
  assert.doesNotMatch(sql, /create table|alter table|create policy|grant execute|current_user_has_permission/i);
  assert.match(sql, /sum\(covered_kg \* result_value\) \/ nullif\(sum\(covered_kg\), 0\) as weighted_value/);
  assert.match(sql, /round\(at\.weighted_value, 2\)/);
});

test('a single provider uses its name without a mix prefix or share', () => {
  const composition = expectedCompositionCode({ ECUACANNABIS: 626 });
  assert.equal(composition, 'ECUACANNABIS');
  assert.doesNotMatch(composition, /^M_|_100$/);
});

test('multiple providers use mixed composition with integer shares totaling 100%', () => {
  const consumption = { ECUACANNABIS: 626, HEOMGROUP: 165 };
  const composition = expectedCompositionCode(consumption);
  const shares = [...composition.matchAll(/_(\d+)(?=_|$)/g)].map(match => Number(match[1]));

  assert.equal(composition, 'M_ECUACANNABIS_79_HEOMGROUP_21');
  assert.equal(shares.reduce((sum, share) => sum + share, 0), 100);
});

test('SQL uses single-provider and largest-remainder composition rules', () => {
  assert.match(sql, /when count\(\*\) = 1 then max\(provider_name\)/);
  assert.match(sql, /when count\(\*\) > 1 then 'M_' \|\| string_agg/);
  assert.match(sql, /row_number\(\) over \([\s\S]*raw_percent - floor\(raw_percent\) desc/);
  assert.match(sql, /remainder_rank <= 100 - base_total/);
});