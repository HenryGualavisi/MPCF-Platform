-- ============================================================
-- MPCF-034 - COD IDENTIFIER FULL NUMBER FIX V1
-- TRAZIX HG / MPCF Platform
--
-- Estado: PREPARADO (SQL versionado). Ejecucion NO CONFIRMADA.
--
-- Regla oficial: COD = 'COD' || numero completo de production_orders.cod.
-- Sin lpad/padStart ni relleno de ceros: COD5 -> COD5, COD153 -> COD153,
-- COD10000 -> COD10000.
--
-- Delta sobre MPCF-029 y MPCF-033 (no se modifican ni se re-ejecutan):
--   1. public.create_laboratory_sample(jsonb): unico cambio, la
--      construccion de v_test_code (antes lpad(v_cod::text, 2, '0'),
--      que truncaba COD de 3+ digitos: COD153 -> COD15).
--   2. private.record_finished_product_entry_from_packing(): unico
--      cambio, la construccion de v_code (mismo defecto).
-- El resto de cada funcion es identico a su version vigente.
-- No modifica tablas, triggers, permisos, RLS ni Produccion.
-- No corrige datos historicos (p. ej. el COD153 ya existente).
-- ============================================================

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

  v_test_code := 'COD' || v_cod::text || v_suffix;
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

create or replace function private.record_finished_product_entry_from_packing()
returns trigger
language plpgsql
security definer
set search_path = public, private, pg_catalog
as $$
declare
  v_organization_id uuid;
  v_cod integer;
  v_code text;
  v_product_id uuid;
begin
  if new.event_type <> 'EMPAQUE'
     or new.stage_status <> 'COMPLETADA'
     or new.packing_quantity_kg is null
     or new.packing_quantity_kg <= 0 then
    return new;
  end if;

  select po.organization_id, po.cod
    into v_organization_id, v_cod
  from public.production_orders po
  where po.id = new.production_order_id;
  if not found then return new; end if;

  v_code := 'COD' || v_cod::text;

  insert into public.finished_products(
    organization_id, product_type, product_code, product_name, unit,
    production_order_id, source_event_id, entered_at
  ) values (
    v_organization_id, 'COD', v_code, v_code, 'kg',
    new.production_order_id, new.id, now()
  ) on conflict (source_event_id) where source_event_id is not null do nothing
  returning id into v_product_id;

  if v_product_id is null then
    select fp.id into v_product_id
    from public.finished_products fp
    where fp.source_event_id = new.id;
  end if;

  insert into public.finished_product_movements(
    organization_id, finished_product_id, movement_type, quantity_kg, unit,
    reference_type, reference_id, created_by, observations
  ) values (
    v_organization_id, v_product_id, 'ENTRADA', new.packing_quantity_kg, 'kg',
    'EMPAQUE', new.id, auth.uid(), 'Entrada automatica por EMPAQUE COMPLETADO'
  ) on conflict (finished_product_id, reference_type, reference_id)
    where movement_type = 'ENTRADA' do nothing;

  return new;
end;
$$;

revoke all on function public.create_laboratory_sample(jsonb) from public, anon;
grant execute on function public.create_laboratory_sample(jsonb) to authenticated;
revoke all on function private.record_finished_product_entry_from_packing() from public, anon, authenticated;

insert into public.schema_migrations
  (migration_code, migration_name, executed_by, notes)
select
  'MPCF-034',
  'COD_IDENTIFIER_FULL_NUMBER_FIX_V1',
  auth.uid(),
  'Codigo COD = COD || numero completo en create_laboratory_sample y entrada de inventario de producto terminado. Sin correccion de datos historicos.'
where not exists (
  select 1
  from public.schema_migrations
  where migration_code = 'MPCF-034'
);

select 'MPCF-034 COD IDENTIFIER FULL NUMBER FIX V1 PREPARED - NOT EXECUTED' as status;
