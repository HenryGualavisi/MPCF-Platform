-- ============================================================
-- MPCF-022 - CONSUMPTION TRANSACTION V1
-- TRAZIX HG / MPCF Platform
--
-- Objetivo:
-- 1) Registrar consumo parcial de disponibilidad en una transaccion.
-- 2) Relacionar consumo con production_order y Big Bag opcional.
-- 3) Mantener saldo y trazabilidad server-side.
--
-- Permiso requerido:
-- private.current_user_has_permission('bodega.write')
-- Debe existir en el catalogo de permisos antes de ejecutar esta migracion.
-- Esta migracion no crea permisos porque su estructura no esta versionada
-- en este repositorio.
--
-- No modifica MPCF-019, MPCF-020 ni MPCF-021.
-- ============================================================

create or replace function public.consume_material_transaction(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, private, pg_catalog
as $$
declare
  v_user uuid := auth.uid();
  v_organization_id uuid;
  v_availability_id uuid := nullif(p_payload->>'availability_id','')::uuid;
  v_production_order_id uuid := nullif(p_payload->>'production_order_id','')::uuid;
  v_big_bag_id uuid := nullif(p_payload->>'big_bag_id','')::uuid;
  v_quantity numeric := nullif(p_payload->>'quantity_kg','')::numeric;
  v_observations text := nullif(trim(p_payload->>'observations'),'');
  v_evidence_reference text := nullif(trim(p_payload->>'evidence_reference'),'');
  v_reception_id uuid;
  v_material_type text;
  v_received numeric;
  v_available numeric;
  v_status text;
  v_production_organization_id uuid;
  v_big_bag_reception_id uuid;
  v_big_bag_verified numeric;
  v_big_bag_consumed numeric := 0;
  v_agricultural_lot_id uuid;
  v_agricultural_lot_count integer := 0;
  v_movement_id uuid;
  v_input_id uuid;
  v_new_available numeric;
  v_new_status text;
begin
  if v_user is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  if not private.current_user_has_permission('bodega.write') then
    raise exception 'PERMISSION_DENIED: bodega.write';
  end if;

  select p.organization_id
    into v_organization_id
  from public.profiles p
  where p.id = v_user;

  if not found then
    raise exception 'PROFILE_NOT_FOUND';
  end if;
  if v_organization_id is null then
    raise exception 'ORGANIZATION_REQUIRED';
  end if;

  if v_availability_id is null then
    raise exception 'VALIDATION: availability_id is required';
  end if;
  if v_production_order_id is null then
    raise exception 'VALIDATION: production_order_id is required';
  end if;
  if v_quantity is null or v_quantity <= 0 then
    raise exception 'VALIDATION: quantity_kg must be > 0';
  end if;

  select ma.reception_id, ma.material_type, ma.quantity_received_kg,
         ma.quantity_available_kg, ma.status
    into v_reception_id, v_material_type, v_received, v_available, v_status
  from public.material_availability ma
  where ma.id = v_availability_id
    and ma.organization_id = v_organization_id
  for update;

  if not found then
    raise exception 'VALIDATION: availability not found for organization';
  end if;
  if v_quantity > v_available then
    raise exception 'VALIDATION: quantity_kg exceeds quantity_available_kg';
  end if;

  select po.organization_id
    into v_production_organization_id
  from public.production_orders po
  where po.id = v_production_order_id;

  if not found then
    raise exception 'VALIDATION: production_order not found';
  end if;
  if v_production_organization_id <> v_organization_id then
    raise exception 'VALIDATION: production_order does not belong to organization';
  end if;

  if v_big_bag_id is not null then
    select bb.reception_id, bb.verified_weight_kg
      into v_big_bag_reception_id, v_big_bag_verified
    from public.big_bags bb
    where bb.id = v_big_bag_id
    for update;

    if not found then
      raise exception 'VALIDATION: Big Bag not found';
    end if;
    if v_big_bag_verified is null or v_big_bag_verified <= 0 then
      raise exception 'VALIDATION: Big Bag verified_weight_kg must be > 0';
    end if;
    if v_big_bag_reception_id <> v_reception_id then
      raise exception 'VALIDATION: Big Bag does not belong to availability reception';
    end if;

    select coalesce(sum(mm.quantity_kg),0)
      into v_big_bag_consumed
    from public.material_movements mm
    where mm.organization_id = v_organization_id
      and mm.big_bag_id = v_big_bag_id
      and mm.movement_type = 'CONSUMO';

    if v_quantity > (v_big_bag_verified - v_big_bag_consumed) then
      raise exception 'VALIDATION: quantity_kg exceeds Big Bag available weight';
    end if;
  end if;

  select count(*)
    into v_agricultural_lot_count
  from public.reception_agricultural_lots ral
  where ral.reception_id = v_reception_id;

  if v_agricultural_lot_count = 1 then
    select ral.agricultural_lot_id
      into v_agricultural_lot_id
    from public.reception_agricultural_lots ral
    where ral.reception_id = v_reception_id;
  end if;

  v_new_available := v_available - v_quantity;
  v_new_status := case when v_new_available = 0 then 'AGOTADO' else 'DISPONIBLE' end;

  insert into public.material_movements(
    organization_id,availability_id,reception_id,big_bag_id,movement_type,
    quantity_kg,movement_datetime,reference_type,reference_id,observations
  ) values(
    v_organization_id,v_availability_id,v_reception_id,v_big_bag_id,'CONSUMO',
    v_quantity,now(),'PRODUCTION_ORDER',v_production_order_id,v_observations
  ) returning id into v_movement_id;

  insert into public.production_inputs(
    production_order_id,material_availability_id,material_movement_id,reception_id,
    big_bag_id,agricultural_lot_id,harvest_id,quantity_kg,input_datetime,
    traceability_status,evidence_reference,observations
  ) values(
    v_production_order_id,v_availability_id,v_movement_id,v_reception_id,
    v_big_bag_id,
    case when v_agricultural_lot_count = 1 then v_agricultural_lot_id else null end,
    null,
    v_quantity,now(),'CONFIRMADO',v_evidence_reference,v_observations
  ) returning id into v_input_id;

  update public.material_availability
  set quantity_available_kg = v_new_available,
      status = v_new_status,
      updated_at = now()
  where id = v_availability_id
    and organization_id = v_organization_id;

  return jsonb_build_object(
    'production_input_id',v_input_id,
    'material_movement_id',v_movement_id,
    'material_availability_id',v_availability_id,
    'reception_id',v_reception_id,
    'big_bag_id',v_big_bag_id,
    'production_order_id',v_production_order_id,
    'quantity_kg',v_quantity,
    'quantity_available_kg',v_new_available,
    'status',v_new_status,
    'agricultural_lot_id',case when v_agricultural_lot_count = 1 then v_agricultural_lot_id else null end,
    'harvest_id',null,
    'traceability_status','CONFIRMADO'
  );
end;
$$;

revoke all on function public.consume_material_transaction(jsonb) from public;
grant execute on function public.consume_material_transaction(jsonb) to authenticated;

insert into public.schema_migrations
  (migration_code, migration_name, executed_by, notes)
select
  'MPCF-022',
  'CONSUMPTION_TRANSACTION_V1',
  auth.uid(),
  'Consumo transaccional server-side con disponibilidad, movimientos, production_inputs y Big Bag opcional.'
where not exists (
  select 1 from public.schema_migrations where migration_code='MPCF-022'
);

select 'MPCF-022 PREPARED' as status;
