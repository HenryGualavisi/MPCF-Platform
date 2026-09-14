-- ============================================================
-- MPCF-024 - RECEPTION AVAILABILITY BRIDGE V1
-- TRAZIX HG / MPCF Platform
--
-- Objetivo:
-- 1) Crear una disponibilidad agregada por recepcion despues de una
--    recepcion transaccional valida.
-- 2) Mantener el detalle fisico en big_bags y material_movements.
-- 3) No crear una disponibilidad por Big Bag.
-- 4) No modificar historicos ni crear una ruta adicional de consumo.
--
-- El trigger es diferido para que la RPC de recepcion pueda insertar
-- primero biomass_receptions y despues big_bags dentro de la misma
-- transaccion.
-- ============================================================

create or replace function public.create_reception_material_availability()
returns trigger
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_material_type text;
  v_material_type_count integer;
begin
  if exists (
    select 1
    from public.material_availability ma
    where ma.reception_id = new.id
  ) then
    return new;
  end if;

  select count(distinct bb.biomass_type), min(bb.biomass_type)
    into v_material_type_count, v_material_type
  from public.big_bags bb
  where bb.reception_id = new.id;

  if v_material_type_count = 0 or v_material_type is null then
    raise exception 'VALIDATION: reception requires Big Bags with biomass_type to create availability';
  end if;
  if v_material_type_count > 1 then
    raise exception 'VALIDATION: reception Big Bags must share one biomass_type for aggregated availability';
  end if;
  if new.verified_weight_kg is null or new.verified_weight_kg <= 0 then
    raise exception 'VALIDATION: reception verified_weight_kg must be > 0 to create availability';
  end if;

  insert into public.material_availability(
    organization_id,
    reception_id,
    material_type,
    quantity_received_kg,
    quantity_available_kg,
    status,
    availability_datetime,
    observations,
    created_at,
    updated_at
  ) values (
    new.organization_id,
    new.id,
    v_material_type,
    new.verified_weight_kg,
    new.verified_weight_kg,
    'DISPONIBLE',
    new.reception_datetime,
    new.observations,
    now(),
    now()
  );

  return new;
end;
$$;

revoke all on function public.create_reception_material_availability() from public;
grant execute on function public.create_reception_material_availability() to authenticated;

do $$
begin
  if not exists (
    select 1
    from pg_trigger
    where tgname = 'trg_reception_material_availability'
      and tgrelid = 'public.biomass_receptions'::regclass
  ) then
    create constraint trigger trg_reception_material_availability
      after insert on public.biomass_receptions
      deferrable initially deferred
      for each row
      execute function public.create_reception_material_availability();
  end if;
end;
$$;

insert into public.schema_migrations
  (migration_code, migration_name, executed_by, notes)
select
  'MPCF-024',
  'RECEPTION_AVAILABILITY_BRIDGE_V1',
  auth.uid(),
  'Crea disponibilidad agregada por recepcion al completar Big Bags; no modifica historicos ni crea ruta adicional de consumo.'
where not exists (
  select 1
  from public.schema_migrations
  where migration_code = 'MPCF-024'
);

select 'MPCF-024 PREPARED' as status;
