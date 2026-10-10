-- ============================================================
-- MPCF-037 - COD CANONICAL 4-DIGIT V1
-- TRAZIX HG / MPCF Platform
--
-- Estado: PREPARADO (SQL versionado). Ejecucion NO CONFIRMADA.
--
-- Regla oficial: COD visible = 'COD' || lpad(production_orders.cod::text, 4, '0')
-- Rango COD0001..COD9999. production_orders.cod permanece integer.
-- Unicidad por organizacion, sin reinicio diario. No hay rollover a 10000.
-- Sufijos de muestra (sin cambios): BIO, RES, EXT, DEC, EMP.
--
-- Supera la regla de MPCF-034 (sin relleno de ceros, sin limite superior).
-- MPCF-029, 033, 034, 035 y 036 NO se modifican ni se re-ejecutan; esta
-- migracion es posterior y redefine solo tres funciones. Ejecutar 037 despues
-- de 029/033 (o de 034 si ya estuviera aplicada); 034 ya no es necesaria.
--
-- Delta sobre las definiciones vigentes (cuerpo de MPCF-034 = 029/033 salvo
-- la linea del codigo):
--   1. public.create_laboratory_sample(jsonb): v_test_code usa lpad(...,4,'0')
--      y se valida 1..9999 antes de generar codigos.
--   2. private.record_finished_product_entry_from_packing(): v_code usa
--      lpad(...,4,'0') y se valida 1..9999.
--   3. public.create_production_order(jsonb): cuerpo de MPCF-026 con tres deltas:
--      rango 1..9999; unicidad por (organizacion, cod) sin fecha, serializada con
--      pg_advisory_xact_lock por organizacion; si no se envia cod se asigna
--      max(cod)+1 y se rechaza al superar 9999 (sin reinicio). Agrega la clave
--      aditiva 'cod_code' (COD####) al resultado; 'cod' sigue siendo integer.
--      Un cod duplicado en otra fecha ahora se rechaza (DUPLICATE).
--   4. Restricciones OBLIGATORIAS sobre production_orders:
--      production_orders_cod_range_check (cod entre 1 y 9999) e indice unico
--      production_orders_organization_cod_uidx (organization_id, cod).
--      Un preflight al inicio ABORTA la migracion (RAISE EXCEPTION) si existen
--      cod fuera de rango o duplicados por organizacion; no se continua en
--      silencio ni se corrige ningun dato. Al final se verifica que ambas
--      restricciones existan y validen antes de registrar MPCF-037 en
--      schema_migrations. Ejecucion prevista: pegar el archivo completo en Supabase SQL Editor y
--      correrlo UNA sola vez como un unico script. Sin BEGIN/COMMIT explicitos:
--      el script se envia como una sola consulta multi-sentencia, que PostgreSQL
--      ejecuta de forma atomica (ante cualquier error no queda ningun cambio).
--
-- NO corrige datos historicos (productos ni muestras ya creados con codigos
-- truncados como COD15 permanecen); requiere auditoria y migracion aparte.
-- No modifica tablas de inventario, ISOL, ventas, triggers, RLS ni permisos.
-- ============================================================

-- PRECONDICIONES: 037 redefine funciones que dependen de MPCF-029 (laboratorio) y
-- MPCF-033 (producto terminado). PL/pgSQL no valida tablas al crear la funcion, asi que
-- sin este bloque 037 podria registrarse como completada con funciones inutilizables.
do $$
declare
  v_missing text;
begin
  select string_agg(t.rel, ', ') into v_missing
  from (values
    ('public.production_orders'), ('public.production_process_events'),
    ('public.laboratory_samples'), ('public.laboratory_tests'),
    ('public.finished_products'), ('public.finished_product_movements'),
    ('public.schema_migrations')
  ) as t(rel)
  where to_regclass(t.rel) is null;
  if v_missing is not null then
    raise exception 'MPCF-037 PRECONDICION: faltan tablas requeridas (%). Ejecutar antes MPCF-029 y MPCF-033. Migracion abortada sin cambios.', v_missing;
  end if;

  if not exists (
    select 1 from pg_trigger tg
    where tg.tgname = 'production_packing_finished_product_entry'
      and tg.tgrelid = 'public.production_process_events'::regclass
      and not tg.tgisinternal
  ) then
    raise exception 'MPCF-037 PRECONDICION: falta el trigger production_packing_finished_product_entry (MPCF-033). Migracion abortada sin cambios.';
  end if;

  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'private' and p.proname = 'current_user_has_permission'
  ) then
    raise exception 'MPCF-037 PRECONDICION: falta private.current_user_has_permission. Migracion abortada sin cambios.';
  end if;
end;
$$;

-- PREFLIGHT: aborta antes de cambiar nada si los datos violan la regla canonica.
-- No corrige ni borra datos: el bloqueo debe resolverse con una migracion aparte.
do $$
declare
  v_out_of_range bigint;
  v_duplicates bigint;
begin
  select count(*) into v_out_of_range
  from public.production_orders po
  where po.cod is null or po.cod not between 1 and 9999;
  if v_out_of_range > 0 then
    raise exception 'MPCF-037 BLOQUEO: % orden(es) de produccion con cod fuera de 1..9999. Migracion abortada sin cambios; resolver manualmente.', v_out_of_range;
  end if;

  select count(*) into v_duplicates
  from (
    select 1 from public.production_orders
    group by organization_id, cod
    having count(*) > 1
  ) d;
  if v_duplicates > 0 then
    raise exception 'MPCF-037 BLOQUEO: % par(es) (organization_id, cod) repetidos en production_orders. Migracion abortada sin cambios; resolver manualmente.', v_duplicates;
  end if;
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
  if v_cod is null or v_cod not between 1 and 9999 then
    raise exception 'VALIDATION: cod must be between 1 and 9999';
  end if;

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

  v_test_code := 'COD' || lpad(v_cod::text, 4, '0') || v_suffix;
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
  if v_cod is null or v_cod not between 1 and 9999 then
    raise exception 'VALIDATION: cod must be between 1 and 9999';
  end if;

  v_code := 'COD' || lpad(v_cod::text, 4, '0');

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

-- Generador de ordenes: COD unico por organizacion, 1..9999, seguro ante concurrencia.
create or replace function public.create_production_order(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, private, pg_catalog
as $$
declare
  v_user uuid := auth.uid();
  v_organization_id uuid;
  v_id uuid;
  v_date date := nullif(p_payload->>'production_date','')::date;
  v_cod integer := nullif(p_payload->>'cod','')::integer;
  v_shift text := nullif(upper(trim(p_payload->>'shift')),'');
  v_type text := nullif(trim(p_payload->>'production_type'),'');
  v_status text := coalesce(nullif(upper(trim(p_payload->>'status')),''),'PROGRAMADA');
  v_version text := coalesce(nullif(trim(p_payload->>'process_version'),''),'V1');
begin
  if v_user is null then raise exception 'AUTH_REQUIRED'; end if;
  if not private.current_user_has_permission('produccion.write') then
    raise exception 'PERMISSION_DENIED: produccion.write';
  end if;

  select p.organization_id into v_organization_id
  from public.profiles p where p.id = v_user;
  if v_organization_id is null then raise exception 'ORGANIZATION_REQUIRED'; end if;
  if v_date is null then raise exception 'VALIDATION: production_date is required'; end if;
  if v_cod is not null and v_cod not between 1 and 9999 then
    raise exception 'VALIDATION: cod must be between 1 and 9999';
  end if;
  if v_status <> 'PROGRAMADA' then raise exception 'VALIDATION: new production must be PROGRAMADA'; end if;
  if v_version <> 'V1' then raise exception 'VALIDATION: process_version must be V1'; end if;

  -- COD unico por organizacion (sin reinicio por fecha). El lock serializa
  -- creaciones simultaneas de la misma organizacion hasta el fin de la transaccion.
  perform pg_advisory_xact_lock(hashtextextended(v_organization_id::text || ':PRODUCTION_COD', 0));

  if v_cod is null then
    select coalesce(max(po.cod), 0) + 1 into v_cod
    from public.production_orders po
    where po.organization_id = v_organization_id
      and po.cod between 1 and 9999;
    if v_cod > 9999 then
      raise exception 'VALIDATION: COD range exhausted (max 9999)';
    end if;
  end if;

  if exists (
    select 1 from public.production_orders
    where organization_id = v_organization_id
      and cod = v_cod
  ) then
    raise exception 'DUPLICATE: production order already exists';
  end if;

  insert into public.production_orders(
    organization_id,cod,production_date,shift,production_type,status,
    process_version,source_reference,observations
  ) values (
    v_organization_id,v_cod,v_date,v_shift,v_type,v_status,v_version,
    nullif(trim(p_payload->>'source_reference'),''),
    nullif(trim(p_payload->>'observations'),'')
  ) returning id into v_id;

  return jsonb_build_object(
    'production_order_id',v_id,
    'cod',v_cod,
    'cod_code','COD' || lpad(v_cod::text, 4, '0'),
    'production_date',v_date,
    'status',v_status,
    'process_version',v_version
  );
end;
$$;

revoke all on function public.create_laboratory_sample(jsonb) from public, anon;
grant execute on function public.create_laboratory_sample(jsonb) to authenticated;
revoke all on function private.record_finished_product_entry_from_packing() from public, anon, authenticated;
revoke all on function public.create_production_order(jsonb) from public;
grant execute on function public.create_production_order(jsonb) to authenticated;

-- Restricciones obligatorias (no destructivo). Fallan de forma explicita.
alter table public.production_orders
  drop constraint if exists production_orders_cod_range_check;
alter table public.production_orders
  add constraint production_orders_cod_range_check check (cod between 1 and 9999);

create unique index if not exists production_orders_organization_cod_uidx
  on public.production_orders(organization_id, cod);

-- Verificacion final: si falta o es invalida alguna restriccion obligatoria, aborta
-- antes de registrar la migracion.
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.production_orders'::regclass
      and conname = 'production_orders_cod_range_check'
      and contype = 'c' and convalidated
  ) then
    raise exception 'MPCF-037 FALLO: production_orders_cod_range_check no esta aplicada y validada';
  end if;

  if not exists (
    select 1
    from pg_index i
    join pg_class c on c.oid = i.indexrelid
    where i.indrelid = 'public.production_orders'::regclass
      and c.relname = 'production_orders_organization_cod_uidx'
      and i.indisunique and i.indisvalid and i.indpred is null
      and (select array_agg(a.attname::text order by k.ord)
           from unnest(i.indkey::int2[]) with ordinality as k(attnum, ord)
           join pg_attribute a on a.attrelid = i.indrelid and a.attnum = k.attnum)
          = array['organization_id', 'cod']
  ) then
    raise exception 'MPCF-037 FALLO: production_orders_organization_cod_uidx (organization_id, cod) no esta aplicado como indice unico valido';
  end if;
end;
$$;

insert into public.schema_migrations
  (migration_code, migration_name, executed_by, notes)
select
  'MPCF-037',
  'COD_CANONICAL_4DIGIT_V1',
  auth.uid(),
  'COD = COD || lpad(cod,4,0), rango 1..9999 en create_laboratory_sample, entrada de inventario de producto terminado y create_production_order (unico por organizacion, serializado por advisory lock). Restricciones de rango y unicidad por organizacion obligatorias y verificadas. Sin correccion de datos historicos.'
where not exists (
  select 1
  from public.schema_migrations
  where migration_code = 'MPCF-037'
);

select 'MPCF-037 COD CANONICAL 4DIGIT V1 APPLIED - constraints verified' as status;