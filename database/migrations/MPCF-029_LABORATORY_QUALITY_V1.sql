-- ============================================================
-- MPCF-029 - LABORATORY / QUALITY V1
-- TRAZIX HG / MPCF Platform
--
-- PREPARED - NOT EXECUTED.
-- Additive laboratory model for CP14. Validated samples remain
-- available as history and are closed to further operational changes.
-- Production, consumption, production stages and existing permissions
-- are not modified.
-- ============================================================

create table if not exists public.laboratory_samples (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  production_order_id uuid not null references public.production_orders(id),
  production_process_event_id uuid not null references public.production_process_events(id),
  sample_code text not null,
  sample_type text not null,
  supplier_organization_id uuid references public.organizations(id),
  agricultural_lot_id uuid references public.agricultural_lots(id),
  analytical_status text not null default 'MUESTRA TOMADA',
  sampled_at timestamptz not null default now(),
  sampled_by uuid references public.profiles(id),
  evidence_reference text,
  observations text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint laboratory_samples_code_not_empty check (length(trim(sample_code)) > 0),
  constraint laboratory_samples_type_check check (
    sample_type in ('BIOMASS', 'RESIDUE', 'EXTRACTION', 'STAGE_OUTPUT')
  ),
  constraint laboratory_samples_status_check check (
    analytical_status in (
      'PENDIENTE', 'MUESTRA TOMADA', 'EN ANÁLISIS',
      'RESULTADO REGISTRADO', 'VALIDADO'
    )
  ),
  constraint laboratory_samples_origin_check check (
    (sample_type = 'BIOMASS' and supplier_organization_id is not null) or
    (sample_type <> 'BIOMASS' and supplier_organization_id is null and agricultural_lot_id is null)
  )
);

create unique index if not exists laboratory_samples_biomass_origin_uidx
  on public.laboratory_samples(
    production_order_id,
    production_process_event_id,
    supplier_organization_id,
    coalesce(agricultural_lot_id, '00000000-0000-0000-0000-000000000000'::uuid)
  ) where sample_type = 'BIOMASS';

create unique index if not exists laboratory_samples_single_output_uidx
  on public.laboratory_samples(production_order_id, production_process_event_id, sample_type)
  where sample_type <> 'BIOMASS';

create index if not exists laboratory_samples_order_stage_idx
  on public.laboratory_samples(production_order_id, production_process_event_id);

create table if not exists public.laboratory_tests (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  production_order_id uuid not null references public.production_orders(id),
  production_process_event_id uuid not null references public.production_process_events(id),
  sample_id uuid not null unique references public.laboratory_samples(id),
  test_code text not null,
  analytical_status text not null default 'MUESTRA TOMADA',
  tested_at timestamptz,
  analyst_id uuid references public.profiles(id),
  evidence_reference text,
  observations text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint laboratory_tests_code_not_empty check (length(trim(test_code)) > 0),
  constraint laboratory_tests_status_check check (
    analytical_status in (
      'PENDIENTE', 'MUESTRA TOMADA', 'EN ANÁLISIS',
      'RESULTADO REGISTRADO', 'VALIDADO'
    )
  )
);

create index if not exists laboratory_tests_order_stage_idx
  on public.laboratory_tests(production_order_id, production_process_event_id);

create table if not exists public.laboratory_results (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  test_id uuid not null references public.laboratory_tests(id),
  sample_id uuid not null references public.laboratory_samples(id),
  attribute_code text not null,
  result_value numeric not null,
  unit text not null default '%',
  measured_at timestamptz not null default now(),
  recorded_by uuid references public.profiles(id),
  evidence_reference text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint laboratory_results_attribute_check check (
    attribute_code in (
      'CBDA_BIOMASS', 'CBD_BIOMASS', 'MOISTURE_BIOMASS',
      'CBDA_RESIDUE', 'CBD_RESIDUE', 'MOISTURE_RESIDUE',
      'CBDA_EXTRACTION', 'CBD_EXTRACTION',
      'CBDA_DECARBOXYLATION', 'CBD_DECARBOXYLATION',
      'CBD_PACKING'
    )
  ),
  constraint laboratory_results_percent_range check (result_value between 0 and 100),
  constraint laboratory_results_unit_check check (unit = '%'),
  constraint laboratory_results_test_sample_attribute_uidx unique (test_id, sample_id, attribute_code)
);

create index if not exists laboratory_results_sample_idx
  on public.laboratory_results(sample_id, attribute_code);

create or replace function private.validate_laboratory_record_context()
returns trigger
language plpgsql
security definer
set search_path = public, private, pg_catalog
as $$
declare
  v_event_type text;
  v_sample_type text;
  v_sample_order_id uuid;
  v_sample_event_id uuid;
  v_test_order_id uuid;
  v_test_event_id uuid;
begin
  if tg_table_name = 'laboratory_samples' then
    select e.event_type
      into v_event_type
    from public.production_orders po
    join public.production_process_events e
      on e.production_order_id = po.id
    where po.id = new.production_order_id
      and po.organization_id = new.organization_id
      and e.id = new.production_process_event_id
      and e.stage_status in ('ACTIVA', 'COMPLETADA');

    if not found then
      raise exception 'VALIDATION: laboratory sample requires an existing stage in the same production';
    end if;

    if (new.sample_type = 'BIOMASS' and v_event_type <> 'EXTRACCION') or
       (new.sample_type in ('RESIDUE', 'EXTRACTION') and v_event_type <> 'EXTRACCION') or
       (new.sample_type = 'STAGE_OUTPUT' and v_event_type not in ('DECARBOXILACION', 'EMPAQUE')) then
      raise exception 'VALIDATION: sample type does not match production stage';
    end if;

    if new.sample_type = 'BIOMASS' and not exists (
      select 1
      from public.production_inputs pi
      join public.big_bags bb on bb.id = pi.big_bag_id
      join public.biomass_receptions br on br.id = bb.reception_id
      where pi.production_order_id = new.production_order_id
        and br.supplier_organization_id = new.supplier_organization_id
        and pi.agricultural_lot_id is not distinct from new.agricultural_lot_id
    ) then
      raise exception 'VALIDATION: biomass sample origin is not present in actual production inputs';
    end if;

    return new;
  end if;

  if tg_table_name = 'laboratory_tests' then
    select s.sample_type, s.production_order_id, s.production_process_event_id
      into v_sample_type, v_sample_order_id, v_sample_event_id
    from public.laboratory_samples s
    where s.id = new.sample_id
      and s.organization_id = new.organization_id;

    if not found or v_sample_order_id <> new.production_order_id or
       v_sample_event_id <> new.production_process_event_id then
      raise exception 'VALIDATION: laboratory test context must match its sample';
    end if;

    return new;
  end if;

  if tg_table_name = 'laboratory_results' then
    select t.production_order_id, t.production_process_event_id, s.sample_type
      into v_test_order_id, v_test_event_id, v_sample_type
    from public.laboratory_tests t
    join public.laboratory_samples s on s.id = new.sample_id
    where t.id = new.test_id
      and t.sample_id = new.sample_id
      and t.organization_id = new.organization_id
      and s.organization_id = new.organization_id;

    if not found then
      raise exception 'VALIDATION: laboratory result test and sample do not match';
    end if;

    select e.event_type
      into v_event_type
    from public.production_process_events e
    where e.id = v_test_event_id;

    if not (
      (v_event_type = 'EXTRACCION' and (
        (v_sample_type = 'BIOMASS' and new.attribute_code in ('CBDA_BIOMASS', 'CBD_BIOMASS', 'MOISTURE_BIOMASS')) or
        (v_sample_type = 'RESIDUE' and new.attribute_code in ('CBDA_RESIDUE', 'CBD_RESIDUE', 'MOISTURE_RESIDUE')) or
        (v_sample_type = 'EXTRACTION' and new.attribute_code in ('CBDA_EXTRACTION', 'CBD_EXTRACTION'))
      )) or
      (v_event_type = 'DECARBOXILACION' and v_sample_type = 'STAGE_OUTPUT'
        and new.attribute_code in ('CBDA_DECARBOXYLATION', 'CBD_DECARBOXYLATION')) or
      (v_event_type = 'EMPAQUE' and v_sample_type = 'STAGE_OUTPUT'
        and new.attribute_code = 'CBD_PACKING')
    ) then
      raise exception 'VALIDATION: analytical attribute does not match sample and production stage';
    end if;

    return new;
  end if;

  return new;
end;
$$;

drop trigger if exists laboratory_samples_validate_context on public.laboratory_samples;
create trigger laboratory_samples_validate_context
before insert or update on public.laboratory_samples
for each row execute function private.validate_laboratory_record_context();

drop trigger if exists laboratory_tests_validate_context on public.laboratory_tests;
create trigger laboratory_tests_validate_context
before insert or update on public.laboratory_tests
for each row execute function private.validate_laboratory_record_context();

drop trigger if exists laboratory_results_validate_context on public.laboratory_results;
create trigger laboratory_results_validate_context
before insert or update on public.laboratory_results
for each row execute function private.validate_laboratory_record_context();

create or replace function private.guard_laboratory_operational_closure()
returns trigger
language plpgsql
security definer
set search_path = public, private, pg_catalog
as $$
declare
  v_sample_status text;
begin
  if tg_table_name = 'laboratory_samples' then
    if old.analytical_status = 'VALIDADO' then
      raise exception 'VALIDATION: validated laboratory sample is operationally closed';
    end if;
    if tg_op = 'DELETE' then return old; end if;
    return new;
  end if;

  if tg_op in ('UPDATE', 'DELETE') then
    select s.analytical_status into v_sample_status
    from public.laboratory_samples s
    where s.id = old.sample_id
    for update;
    if not found then
      raise exception 'VALIDATION: laboratory sample not found';
    end if;
    if v_sample_status = 'VALIDADO' then
      raise exception 'VALIDATION: validated laboratory sample is operationally closed';
    end if;
  end if;

  if tg_op in ('INSERT', 'UPDATE') then
    select s.analytical_status into v_sample_status
    from public.laboratory_samples s
    where s.id = new.sample_id
    for update;
    if not found then
      raise exception 'VALIDATION: laboratory sample not found';
    end if;
    if v_sample_status = 'VALIDADO' then
      raise exception 'VALIDATION: validated laboratory sample is operationally closed';
    end if;
    return new;
  end if;

  return old;
end;
$$;

drop trigger if exists laboratory_samples_operational_closure on public.laboratory_samples;
create trigger laboratory_samples_operational_closure
before update or delete on public.laboratory_samples
for each row execute function private.guard_laboratory_operational_closure();

drop trigger if exists laboratory_results_operational_closure on public.laboratory_results;
create trigger laboratory_results_operational_closure
before insert or update or delete on public.laboratory_results
for each row execute function private.guard_laboratory_operational_closure();

alter table public.laboratory_samples enable row level security;
alter table public.laboratory_tests enable row level security;
alter table public.laboratory_results enable row level security;

drop policy if exists laboratory_samples_read on public.laboratory_samples;
create policy laboratory_samples_read on public.laboratory_samples
for select to authenticated
using (
  organization_id = (select p.organization_id from public.profiles p where p.id = auth.uid())
  and (
    private.current_user_has_permission('laboratorio.read') or
    private.current_user_has_permission('produccion.read')
  )
);

drop policy if exists laboratory_samples_write on public.laboratory_samples;
create policy laboratory_samples_write on public.laboratory_samples
for all to authenticated
using (
  organization_id = (select p.organization_id from public.profiles p where p.id = auth.uid())
  and private.current_user_has_permission('laboratorio.write')
)
with check (
  organization_id = (select p.organization_id from public.profiles p where p.id = auth.uid())
  and private.current_user_has_permission('laboratorio.write')
);

drop policy if exists laboratory_tests_read on public.laboratory_tests;
create policy laboratory_tests_read on public.laboratory_tests
for select to authenticated
using (
  organization_id = (select p.organization_id from public.profiles p where p.id = auth.uid())
  and (
    private.current_user_has_permission('laboratorio.read') or
    private.current_user_has_permission('produccion.read')
  )
);

drop policy if exists laboratory_tests_write on public.laboratory_tests;
create policy laboratory_tests_write on public.laboratory_tests
for all to authenticated
using (
  organization_id = (select p.organization_id from public.profiles p where p.id = auth.uid())
  and private.current_user_has_permission('laboratorio.write')
)
with check (
  organization_id = (select p.organization_id from public.profiles p where p.id = auth.uid())
  and private.current_user_has_permission('laboratorio.write')
);

drop policy if exists laboratory_results_read on public.laboratory_results;
create policy laboratory_results_read on public.laboratory_results
for select to authenticated
using (
  organization_id = (select p.organization_id from public.profiles p where p.id = auth.uid())
  and (
    private.current_user_has_permission('laboratorio.read') or
    private.current_user_has_permission('produccion.read')
  )
);

drop policy if exists laboratory_results_write on public.laboratory_results;
create policy laboratory_results_write on public.laboratory_results
for all to authenticated
using (
  organization_id = (select p.organization_id from public.profiles p where p.id = auth.uid())
  and private.current_user_has_permission('laboratorio.write')
)
with check (
  organization_id = (select p.organization_id from public.profiles p where p.id = auth.uid())
  and private.current_user_has_permission('laboratorio.write')
);

revoke all on public.laboratory_samples from public, anon, authenticated;
revoke all on public.laboratory_tests from public, anon, authenticated;
revoke all on public.laboratory_results from public, anon, authenticated;

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
  composition as (
    select 'M_' || string_agg(
      regexp_replace(upper(o.code), '[^A-Z0-9]+', '_', 'g') || '_' ||
      replace(trim(trailing '.' from trim(trailing '0' from to_char(
        100 * pw.consumed_kg / nullif(tw.consumed_kg, 0), 'FM990D00'
      ))), ',', '.'),
      '_' order by o.code
    ) as composition_code
    from provider_weights pw
    join public.organizations o on o.id = pw.supplier_organization_id
    cross join total_weight tw
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

create or replace function public.get_laboratory_orders()
returns jsonb
language plpgsql
security definer
set search_path = public, private, pg_catalog
as $$
declare
  v_user uuid := auth.uid();
  v_organization_id uuid;
  v_orders jsonb;
begin
  if v_user is null then raise exception 'AUTH_REQUIRED'; end if;
  if not private.current_user_has_permission('laboratorio.read') then
    raise exception 'PERMISSION_DENIED: laboratorio.read';
  end if;

  select p.organization_id into v_organization_id
  from public.profiles p where p.id = v_user;
  if v_organization_id is null then raise exception 'ORGANIZATION_REQUIRED'; end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', po.id,
    'cod', po.cod,
    'production_date', po.production_date,
    'shift', po.shift,
    'status', po.status
  ) order by po.production_date desc, po.cod desc), '[]'::jsonb)
    into v_orders
  from public.production_orders po
  where po.organization_id = v_organization_id
    and exists (
      select 1 from public.production_inputs pi
      where pi.production_order_id = po.id
    );

  return v_orders;
end;
$$;

create or replace function public.get_laboratory_order_context(p_production_order_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, private, pg_catalog
as $$
declare
  v_user uuid := auth.uid();
  v_organization_id uuid;
  v_order public.production_orders%rowtype;
  v_context jsonb;
begin
  if v_user is null then raise exception 'AUTH_REQUIRED'; end if;
  if not private.current_user_has_permission('laboratorio.read') then
    raise exception 'PERMISSION_DENIED: laboratorio.read';
  end if;

  select p.organization_id into v_organization_id
  from public.profiles p where p.id = v_user;
  if v_organization_id is null then raise exception 'ORGANIZATION_REQUIRED'; end if;

  select * into v_order
  from public.production_orders po
  where po.id = p_production_order_id
    and po.organization_id = v_organization_id;
  if not found then raise exception 'VALIDATION: production order not found'; end if;

  select jsonb_build_object(
    'production_order', jsonb_build_object(
      'id', v_order.id,
      'cod', v_order.cod,
      'production_date', v_order.production_date,
      'shift', v_order.shift,
      'status', v_order.status
    ),
    'stages', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', e.id,
        'event_type', e.event_type,
        'sequence_no', e.sequence_no,
        'stage_status', e.stage_status
      ) order by e.sequence_no)
      from public.production_process_events e
      where e.production_order_id = v_order.id
        and e.event_type in ('EXTRACCION', 'DECARBOXILACION', 'EMPAQUE')
        and e.stage_status in ('ACTIVA', 'COMPLETADA')
    ), '[]'::jsonb),
    'consumption_groups', coalesce((
      select jsonb_agg(jsonb_build_object(
        'supplier_organization_id', grouped.supplier_organization_id,
        'supplier_name', grouped.supplier_name,
        'supplier_code', grouped.supplier_code,
        'agricultural_lot_id', grouped.agricultural_lot_id,
        'consumed_kg', grouped.consumed_kg,
        'big_bag_count', grouped.big_bag_count,
        'big_bags', grouped.big_bags
      ) order by grouped.supplier_name, grouped.agricultural_lot_id)
      from (
        select
          br.supplier_organization_id,
          coalesce(o.name, br.supplier_name_declared) as supplier_name,
          o.code as supplier_code,
          pi.agricultural_lot_id,
          sum(pi.quantity_kg) as consumed_kg,
          count(distinct bb.id) as big_bag_count,
          jsonb_agg(jsonb_build_object(
            'production_input_id', pi.id,
            'big_bag_id', bb.id,
            'big_bag_code', bb.big_bag_code,
            'reception_id', br.id,
            'reception_code', br.reception_code,
            'quantity_kg', pi.quantity_kg,
            'traceability_status', pi.traceability_status
          ) order by bb.big_bag_code) as big_bags
        from public.production_inputs pi
        join public.big_bags bb on bb.id = pi.big_bag_id
        join public.biomass_receptions br on br.id = bb.reception_id
        left join public.organizations o on o.id = br.supplier_organization_id
        where pi.production_order_id = v_order.id
        group by br.supplier_organization_id, coalesce(o.name, br.supplier_name_declared),
                 o.code, pi.agricultural_lot_id
      ) grouped
    ), '[]'::jsonb),
    'samples', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', s.id,
        'sample_code', s.sample_code,
        'sample_type', s.sample_type,
        'production_process_event_id', s.production_process_event_id,
        'supplier_organization_id', s.supplier_organization_id,
        'agricultural_lot_id', s.agricultural_lot_id,
        'analytical_status', s.analytical_status,
        'sampled_at', s.sampled_at,
        'sampled_by', s.sampled_by,
        'evidence_reference', s.evidence_reference,
        'test', to_jsonb(t),
        'results', coalesce((
          select jsonb_agg(to_jsonb(r) order by r.attribute_code)
          from public.laboratory_results r where r.test_id = t.id
        ), '[]'::jsonb)
      ) order by s.sample_type, s.sample_code)
      from public.laboratory_samples s
      left join public.laboratory_tests t on t.sample_id = s.id
      where s.production_order_id = v_order.id
    ), '[]'::jsonb),
    'lfw', private.get_laboratory_lfw(v_order.id)
  ) into v_context;

  return v_context;
end;
$$;

create or replace function public.create_laboratory_sample(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, private, pg_catalog
as $$
declare
  v_user uuid := auth.uid();
  v_organization_id uuid;
  v_order_id uuid := nullif(p_payload->>'production_order_id', '')::uuid;
  v_event_id uuid := nullif(p_payload->>'production_process_event_id', '')::uuid;
  v_supplier_id uuid := nullif(p_payload->>'supplier_organization_id', '')::uuid;
  v_lot_id uuid := nullif(p_payload->>'agricultural_lot_id', '')::uuid;
  v_sample_type text := upper(nullif(trim(p_payload->>'sample_type'), ''));
  v_event_type text;
  v_cod integer;
  v_supplier_code text;
  v_suffix text;
  v_sample_id uuid;
  v_test_id uuid;
  v_sample_code text;
  v_test_code text;
begin
  if v_user is null then raise exception 'AUTH_REQUIRED'; end if;
  if not private.current_user_has_permission('laboratorio.write') then
    raise exception 'PERMISSION_DENIED: laboratorio.write';
  end if;
  if v_order_id is null or v_event_id is null then
    raise exception 'VALIDATION: production_order_id and production_process_event_id are required';
  end if;

  select po.organization_id, po.cod, e.event_type
    into v_organization_id, v_cod, v_event_type
  from public.production_orders po
  join public.production_process_events e on e.production_order_id = po.id
  where po.id = v_order_id and po.organization_id = (
    select p.organization_id from public.profiles p where p.id = v_user
  ) and e.id = v_event_id and e.stage_status in ('ACTIVA', 'COMPLETADA');
  if not found then raise exception 'VALIDATION: production stage not found'; end if;

  if v_sample_type = 'BIOMASS' then
    select o.code into v_supplier_code
    from public.organizations o where o.id = v_supplier_id;
    if v_supplier_id is null or v_supplier_code is null then
      raise exception 'VALIDATION: consumed supplier is required for biomass sample';
    end if;
    v_suffix := 'BIO';
  elsif v_sample_type = 'RESIDUE' then
    v_suffix := 'RES';
  elsif v_sample_type = 'EXTRACTION' then
    v_suffix := 'EXT';
  elsif v_sample_type = 'STAGE_OUTPUT' and v_event_type = 'DECARBOXILACION' then
    v_suffix := 'DEC';
  elsif v_sample_type = 'STAGE_OUTPUT' and v_event_type = 'EMPAQUE' then
    v_suffix := 'EMP';
  else
    raise exception 'VALIDATION: sample type is not supported for this stage';
  end if;

  v_test_code := 'COD' || lpad(v_cod::text, 2, '0') || v_suffix;
  v_sample_code := v_test_code || case
    when v_sample_type = 'BIOMASS' then '-' || regexp_replace(upper(v_supplier_code), '[^A-Z0-9]+', '_', 'g')
    else ''
  end;

  insert into public.laboratory_samples(
    organization_id, production_order_id, production_process_event_id,
    sample_code, sample_type, supplier_organization_id, agricultural_lot_id,
    sampled_by, evidence_reference, observations
  ) values (
    v_organization_id, v_order_id, v_event_id, v_sample_code, v_sample_type,
    v_supplier_id, v_lot_id, v_user,
    nullif(trim(p_payload->>'evidence_reference'), ''),
    nullif(trim(p_payload->>'observations'), '')
  ) on conflict do nothing returning id into v_sample_id;

  if v_sample_id is null then
    select s.id into v_sample_id
    from public.laboratory_samples s
    where s.production_order_id = v_order_id
      and s.production_process_event_id = v_event_id
      and s.sample_type = v_sample_type
      and s.supplier_organization_id is not distinct from v_supplier_id
      and s.agricultural_lot_id is not distinct from v_lot_id;
  end if;

  insert into public.laboratory_tests(
    organization_id, production_order_id, production_process_event_id,
    sample_id, test_code, analyst_id
  ) values (
    v_organization_id, v_order_id, v_event_id, v_sample_id, v_test_code, v_user
  ) on conflict (sample_id) do nothing returning id into v_test_id;

  if v_test_id is null then
    select t.id into v_test_id from public.laboratory_tests t where t.sample_id = v_sample_id;
  end if;

  return jsonb_build_object(
    'sample_id', v_sample_id,
    'sample_code', v_sample_code,
    'test_id', v_test_id,
    'test_code', v_test_code
  );
end;
$$;

create or replace function public.save_laboratory_result(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, private, pg_catalog
as $$
declare
  v_user uuid := auth.uid();
  v_organization_id uuid;
  v_test_id uuid := nullif(p_payload->>'test_id', '')::uuid;
  v_sample_id uuid := nullif(p_payload->>'sample_id', '')::uuid;
  v_attribute text := upper(nullif(trim(p_payload->>'attribute_code'), ''));
  v_value numeric := nullif(p_payload->>'result_value', '')::numeric;
  v_result_id uuid;
  v_sample_status text;
begin
  if v_user is null then raise exception 'AUTH_REQUIRED'; end if;
  if not private.current_user_has_permission('laboratorio.write') then
    raise exception 'PERMISSION_DENIED: laboratorio.write';
  end if;
  if v_test_id is null or v_sample_id is null or v_attribute is null or v_value is null then
    raise exception 'VALIDATION: test_id, sample_id, attribute_code and numeric result_value are required';
  end if;

  select t.organization_id, s.analytical_status
    into v_organization_id, v_sample_status
  from public.laboratory_tests t
  join public.laboratory_samples s on s.id = t.sample_id
  join public.production_orders po on po.id = t.production_order_id
  where t.id = v_test_id and t.sample_id = v_sample_id
    and po.organization_id = (
      select p.organization_id from public.profiles p where p.id = v_user
    );
  if not found then raise exception 'VALIDATION: laboratory test not found'; end if;
  if v_sample_status = 'VALIDADO' then
    raise exception 'VALIDATION: validated laboratory sample is operationally closed';
  end if;
  if v_value < 0 or v_value > 100 then
    raise exception 'VALIDATION: percentage result must be between 0 and 100';
  end if;

  insert into public.laboratory_results(
    organization_id, test_id, sample_id, attribute_code,
    result_value, unit, recorded_by, evidence_reference
  ) values (
    v_organization_id, v_test_id, v_sample_id, v_attribute,
    v_value, '%', v_user,
    nullif(trim(p_payload->>'evidence_reference'), '')
  ) on conflict (test_id, sample_id, attribute_code) do update set
    result_value = excluded.result_value,
    measured_at = now(),
    recorded_by = excluded.recorded_by,
    evidence_reference = excluded.evidence_reference,
    updated_at = now()
  returning id into v_result_id;

  update public.laboratory_samples
  set analytical_status = 'EN ANÁLISIS', updated_at = now()
  where id = v_sample_id;
  update public.laboratory_tests
  set analytical_status = 'EN ANÁLISIS', analyst_id = v_user, tested_at = now(), updated_at = now()
  where id = v_test_id;

  return jsonb_build_object('result_id', v_result_id, 'analytical_status', 'EN ANÁLISIS');
end;
$$;

create or replace function public.set_laboratory_sample_status(p_sample_id uuid, p_status text)
returns jsonb
language plpgsql
security definer
set search_path = public, private, pg_catalog
as $$
declare
  v_user uuid := auth.uid();
  v_sample public.laboratory_samples%rowtype;
  v_event_type text;
  v_expected_count integer;
  v_result_count integer;
begin
  if v_user is null then raise exception 'AUTH_REQUIRED'; end if;
  if not private.current_user_has_permission('laboratorio.write') then
    raise exception 'PERMISSION_DENIED: laboratorio.write';
  end if;
  if p_status not in ('MUESTRA TOMADA', 'EN ANÁLISIS', 'RESULTADO REGISTRADO', 'VALIDADO') then
    raise exception 'VALIDATION: invalid analytical status';
  end if;

  select s.* into v_sample
  from public.laboratory_samples s
  join public.production_orders po on po.id = s.production_order_id
  where s.id = p_sample_id and po.organization_id = (
    select p.organization_id from public.profiles p where p.id = v_user
  ) for update of s;
  if not found then raise exception 'VALIDATION: laboratory sample not found'; end if;
  if v_sample.analytical_status = 'VALIDADO' then
    raise exception 'VALIDATION: validated laboratory sample is operationally closed';
  end if;

  if p_status in ('RESULTADO REGISTRADO', 'VALIDADO') then
    select e.event_type into v_event_type
    from public.production_process_events e
    where e.id = v_sample.production_process_event_id;

    v_expected_count := case
      when v_sample.sample_type = 'BIOMASS' then 3
      when v_sample.sample_type = 'RESIDUE' then 3
      when v_sample.sample_type = 'EXTRACTION' then 2
      when v_event_type = 'DECARBOXILACION' then 2
      when v_event_type = 'EMPAQUE' then 1
      else 0
    end;

    select count(*) into v_result_count
    from public.laboratory_results r
    where r.sample_id = v_sample.id;
    if v_expected_count = 0 or v_result_count < v_expected_count then
      raise exception 'VALIDATION: required analytical results are incomplete';
    end if;
  end if;

  update public.laboratory_tests
  set analytical_status = p_status,
      analyst_id = v_user,
      tested_at = coalesce(tested_at, now()),
      updated_at = now()
  where sample_id = v_sample.id;
  update public.laboratory_samples
  set analytical_status = p_status, updated_at = now()
  where id = v_sample.id;

  return jsonb_build_object('sample_id', v_sample.id, 'analytical_status', p_status);
end;
$$;

create or replace function public.get_production_laboratory_attributes(p_production_order_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, private, pg_catalog
as $$
declare
  v_user uuid := auth.uid();
  v_organization_id uuid;
  v_result jsonb;
begin
  if v_user is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (
    private.current_user_has_permission('laboratorio.read') or
    private.current_user_has_permission('produccion.read')
  ) then
    raise exception 'PERMISSION_DENIED: laboratorio.read or produccion.read';
  end if;

  select p.organization_id into v_organization_id
  from public.profiles p where p.id = v_user;
  if v_organization_id is null or not exists (
    select 1 from public.production_orders po
    where po.id = p_production_order_id and po.organization_id = v_organization_id
  ) then
    raise exception 'VALIDATION: production order not found';
  end if;

  select jsonb_build_object(
    'extraction', case when exists (
      select 1 from public.production_process_events e
      where e.production_order_id = p_production_order_id
        and e.event_type = 'EXTRACCION' and e.stage_status in ('ACTIVA', 'COMPLETADA')
    ) then private.get_laboratory_lfw(p_production_order_id) else '{}'::jsonb end,
    'stage_results', coalesce((
      select jsonb_object_agg(e.event_type, attrs.attribute_values)
      from public.production_process_events e
      cross join lateral (
        select jsonb_object_agg(r.attribute_code, jsonb_build_object(
          'value', r.result_value,
          'unit', r.unit,
          'status', s.analytical_status,
          'measured_at', r.measured_at
        )) as attribute_values
        from public.laboratory_samples s
        join public.laboratory_tests t on t.sample_id = s.id
        join public.laboratory_results r on r.test_id = t.id and r.sample_id = s.id
        where s.production_order_id = p_production_order_id
          and s.production_process_event_id = e.id
          and s.sample_type in ('RESIDUE', 'EXTRACTION', 'STAGE_OUTPUT')
          and s.analytical_status in ('RESULTADO REGISTRADO', 'VALIDADO')
      ) attrs
      where e.production_order_id = p_production_order_id
        and e.event_type in ('EXTRACCION', 'DECARBOXILACION', 'EMPAQUE')
        and e.stage_status in ('ACTIVA', 'COMPLETADA')
        and attrs.attribute_values is not null
    ), '{}'::jsonb)
  ) into v_result;

  return v_result;
end;
$$;

revoke all on function private.get_laboratory_lfw(uuid) from public, anon, authenticated;
revoke all on function private.validate_laboratory_record_context() from public, anon, authenticated;
revoke all on function private.guard_laboratory_operational_closure() from public, anon, authenticated;
revoke all on function public.get_laboratory_orders() from public, anon;
revoke all on function public.get_laboratory_order_context(uuid) from public, anon;
revoke all on function public.create_laboratory_sample(jsonb) from public, anon;
revoke all on function public.save_laboratory_result(jsonb) from public, anon;
revoke all on function public.set_laboratory_sample_status(uuid, text) from public, anon;
revoke all on function public.get_production_laboratory_attributes(uuid) from public, anon;
grant execute on function public.get_laboratory_orders() to authenticated;
grant execute on function public.get_laboratory_order_context(uuid) to authenticated;
grant execute on function public.create_laboratory_sample(jsonb) to authenticated;
grant execute on function public.save_laboratory_result(jsonb) to authenticated;
grant execute on function public.set_laboratory_sample_status(uuid, text) to authenticated;
grant execute on function public.get_production_laboratory_attributes(uuid) to authenticated;

select 'MPCF-029 LABORATORY / QUALITY V1 PREPARED - NOT EXECUTED' as status;