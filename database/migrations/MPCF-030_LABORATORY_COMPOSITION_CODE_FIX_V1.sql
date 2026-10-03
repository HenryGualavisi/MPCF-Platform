-- ============================================================
-- MPCF-030 - LABORATORY COMPOSITION CODE FIX V1
-- TRAZIX HG / MPCF Platform
--
-- PREPARED - NOT EXECUTED.
-- Corrects only composition_code in private.get_laboratory_lfw().
-- The LFW formula, tables, permissions, RLS, samples and results
-- remain unchanged.
-- ============================================================

create or replace function private.get_laboratory_lfw(p_production_order_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public, private, pg_catalog
as $$
  with source_lots as (
    select
      br.supplier_organization_id,
      pi.agricultural_lot_id,
      sum(pi.quantity_kg) as consumed_kg
    from public.production_inputs pi
    join public.big_bags bb on bb.id = pi.big_bag_id
    join public.biomass_receptions br on br.id = bb.reception_id
    where pi.production_order_id = p_production_order_id
    group by br.supplier_organization_id, pi.agricultural_lot_id
  ),
  source_weights as (
    select
      supplier_organization_id,
      sum(consumed_kg) as consumed_kg,
      jsonb_agg(jsonb_build_object(
        'agricultural_lot_id', agricultural_lot_id,
        'consumed_kg', consumed_kg
      ) order by agricultural_lot_id) as agricultural_lots
    from source_lots
    group by supplier_organization_id
  ),
  provider_weights as (
    select supplier_organization_id, consumed_kg
    from source_weights
  ),
  source_results as (
    select
      sw.supplier_organization_id,
      r.attribute_code,
      sum(sl.consumed_kg * r.result_value) / nullif(sum(sl.consumed_kg), 0) as result_value,
      sum(sl.consumed_kg) as covered_kg
    from source_weights sw
    join source_lots sl
      on sl.supplier_organization_id = sw.supplier_organization_id
    join public.organizations o on o.id = sw.supplier_organization_id
    join public.laboratory_samples s
      on s.production_order_id = p_production_order_id
     and s.sample_type = 'BIOMASS'
     and s.supplier_organization_id = sw.supplier_organization_id
     and s.agricultural_lot_id is not distinct from sl.agricultural_lot_id
    join public.laboratory_tests t on t.sample_id = s.id
    join public.laboratory_results r on r.test_id = t.id and r.sample_id = s.id
    where s.analytical_status in ('RESULTADO REGISTRADO', 'VALIDADO')
      and r.attribute_code in ('CBDA_BIOMASS', 'CBD_BIOMASS', 'MOISTURE_BIOMASS')
    group by sw.supplier_organization_id, r.attribute_code
  ),
  attribute_totals as (
    select
      attribute_code,
      sum(covered_kg * result_value) / nullif(sum(covered_kg), 0) as weighted_value,
      sum(covered_kg) as covered_kg
    from source_results
    group by attribute_code
  ),
  total_weight as (
    select coalesce(sum(consumed_kg), 0) as consumed_kg from source_weights
  ),
  composition_raw as (
    select
      regexp_replace(upper(o.name), '[^A-Z0-9]+', '_', 'g') as provider_name,
      100 * pw.consumed_kg / nullif(tw.consumed_kg, 0) as raw_percent
    from provider_weights pw
    join public.organizations o on o.id = pw.supplier_organization_id
    cross join total_weight tw
    where tw.consumed_kg > 0
  ),
  composition_base as (
    select
      provider_name,
      floor(raw_percent)::integer as base_percent,
      row_number() over (
        order by raw_percent - floor(raw_percent) desc, provider_name
      ) as remainder_rank,
      sum(floor(raw_percent)::integer) over () as base_total
    from composition_raw
  ),
  composition_items as (
    select
      provider_name,
      base_percent + case
        when remainder_rank <= 100 - base_total then 1
        else 0
      end as share_percent
    from composition_base
  ),
  composition as (
    select case
      when count(*) = 1 then max(provider_name)
      when count(*) > 1 then 'M_' || string_agg(
        provider_name || '_' || share_percent::text,
        '_' order by provider_name
      )
      else null
    end as composition_code
    from composition_items
  )
  select jsonb_build_object(
    'composition_code', (select composition_code from composition),
    'total_consumed_kg', (select consumed_kg from total_weight),
    'sources', coalesce((
      select jsonb_agg(jsonb_build_object(
        'supplier_organization_id', supplier_organization_id,
        'consumed_kg', consumed_kg,
        'agricultural_lots', agricultural_lots
      ) order by supplier_organization_id)
      from source_weights
    ), '[]'::jsonb),
    'attributes', coalesce((
      select jsonb_object_agg(
        at.attribute_code,
        jsonb_build_object(
          'value', round(at.weighted_value, 2),
          'covered_kg', at.covered_kg,
          'total_kg', tw.consumed_kg,
          'status', case when abs(at.covered_kg - tw.consumed_kg) <= 0.001
                         then 'RESULTADO REGISTRADO' else 'PARCIAL' end
        )
      )
      from attribute_totals at
      cross join total_weight tw
    ), '{}'::jsonb)
  );
$$;

select 'MPCF-030 LABORATORY COMPOSITION CODE FIX V1 PREPARED - NOT EXECUTED' as status;