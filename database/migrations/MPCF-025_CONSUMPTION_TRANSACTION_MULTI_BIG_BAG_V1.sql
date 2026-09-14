-- ============================================================
-- MPCF-025 - CONSUMPTION TRANSACTION MULTI BIG BAG V1
-- TRAZIX HG / MPCF Platform
--
-- Evoluciona la unica RPC publica de consumo de MPCF-022.
-- No crea una segunda ruta de consumo.
-- No modifica historicos ni crea Big Bags retroactivos.
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
  v_production_order_id uuid;
  v_requested_quantity numeric;
  v_observations text;
  v_evidence_reference text;
  v_consumptions jsonb;
  v_line jsonb;
  v_line_count integer;
  v_line_total numeric := 0;
  v_distinct_big_bag_count integer;
  v_big_bag_count integer;
  v_availability_id uuid;
  v_big_bag_id uuid;
  v_line_quantity numeric;
  v_reception_id uuid;
  v_reception_organization_id uuid;
  v_material_type text;
  v_available numeric;
  v_big_bag_reception_id uuid;
  v_big_bag_verified numeric;
  v_big_bag_consumed numeric;
  v_big_bag_balance numeric;
  v_group_quantity numeric;
  v_new_available numeric;
  v_new_status text;
  v_movement_id uuid;
  v_input_id uuid;
  v_agricultural_lot_id uuid;
  v_agricultural_lot_count integer;
  v_traceability_status text;
  v_result_items jsonb := '[]'::jsonb;
  v_result_item jsonb;
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

  v_production_order_id := nullif(p_payload->>'production_order_id','')::uuid;
  v_requested_quantity := nullif(p_payload->>'quantity_kg','')::numeric;
  v_observations := nullif(trim(p_payload->>'observations'),'');
  v_evidence_reference := nullif(trim(p_payload->>'evidence_reference'),'');

  if v_production_order_id is null then
    raise exception 'VALIDATION: production_order_id is required';
  end if;
  if v_requested_quantity is null or v_requested_quantity <= 0 then
    raise exception 'VALIDATION: quantity_kg must be > 0';
  end if;

  if not exists (
    select 1
    from public.production_orders po
    where po.id = v_production_order_id
      and po.organization_id = v_organization_id
  ) then
    raise exception 'VALIDATION: production_order not found for organization';
  end if;

  if jsonb_typeof(p_payload->'consumptions') = 'array' then
    v_consumptions := p_payload->'consumptions';
  elsif p_payload ? 'availability_id'
     and p_payload ? 'big_bag_id'
     and p_payload ? 'quantity_kg' then
    v_consumptions := jsonb_build_array(
      jsonb_build_object(
        'availability_id', p_payload->>'availability_id',
        'big_bag_id', p_payload->>'big_bag_id',
        'quantity_kg', p_payload->>'quantity_kg'
      )
    );
  else
    raise exception 'VALIDATION: consumptions array is required';
  end if;

  if jsonb_array_length(v_consumptions) = 0 then
    raise exception 'VALIDATION: consumptions array cannot be empty';
  end if;

  select count(*)
    into v_line_count
  from jsonb_array_elements(v_consumptions);

  for v_line in
    select value
    from jsonb_array_elements(v_consumptions)
  loop
    if nullif(v_line->>'availability_id','')::uuid is null then
      raise exception 'VALIDATION: every line requires availability_id';
    end if;
    if nullif(v_line->>'big_bag_id','')::uuid is null then
      raise exception 'VALIDATION: every line requires big_bag_id';
    end if;
    if nullif(v_line->>'quantity_kg','')::numeric is null
       or nullif(v_line->>'quantity_kg','')::numeric <= 0 then
      raise exception 'VALIDATION: every line requires quantity_kg > 0';
    end if;

    v_line_total := v_line_total + (v_line->>'quantity_kg')::numeric;
  end loop;

  select count(*), count(distinct ((value->>'big_bag_id')::uuid))
    into v_big_bag_count, v_distinct_big_bag_count
  from jsonb_array_elements(v_consumptions);

  if v_big_bag_count <> v_distinct_big_bag_count then
    raise exception 'VALIDATION: repeated big_bag_id is not allowed';
  end if;

  if abs(v_line_total - v_requested_quantity) > 0.001 then
    raise exception
      'VALIDATION: consumption lines total % does not equal requested quantity %',
      round(v_line_total,3),
      round(v_requested_quantity,3);
  end if;

  -- Lock all affected availability rows in deterministic UUID order.
  for v_availability_id in
    select distinct (value->>'availability_id')::uuid
    from jsonb_array_elements(v_consumptions)
    order by 1
  loop
    select ma.reception_id, ma.material_type, ma.quantity_available_kg
      into v_reception_id, v_material_type, v_available
    from public.material_availability ma
    where ma.id = v_availability_id
      and ma.organization_id = v_organization_id
    for update;

    if not found then
      raise exception 'VALIDATION: availability not found for organization: %', v_availability_id;
    end if;

    if not exists (
      select 1
      from public.biomass_receptions br
      where br.id = v_reception_id
        and br.organization_id = v_organization_id
    ) then
      raise exception 'VALIDATION: availability reception not found for organization: %', v_reception_id;
    end if;
  end loop;

  -- Lock all affected Big Bags in deterministic UUID order.
  for v_big_bag_id in
    select distinct (value->>'big_bag_id')::uuid
    from jsonb_array_elements(v_consumptions)
    order by 1
  loop
    select bb.reception_id, bb.verified_weight_kg
      into v_big_bag_reception_id, v_big_bag_verified
    from public.big_bags bb
    where bb.id = v_big_bag_id
    for update;

    if not found then
      raise exception 'VALIDATION: Big Bag not found: %', v_big_bag_id;
    end if;
    if v_big_bag_verified is null or v_big_bag_verified <= 0 then
      raise exception 'VALIDATION: Big Bag verified_weight_kg must be > 0: %', v_big_bag_id;
    end if;
  end loop;

  -- Validate every line against its locked availability and Big Bag.
  for v_line in
    select value
    from jsonb_array_elements(v_consumptions)
  loop
    v_availability_id := (v_line->>'availability_id')::uuid;
    v_big_bag_id := (v_line->>'big_bag_id')::uuid;
    v_line_quantity := (v_line->>'quantity_kg')::numeric;

    select ma.reception_id, ma.quantity_available_kg
      into v_reception_id, v_available
    from public.material_availability ma
    where ma.id = v_availability_id
      and ma.organization_id = v_organization_id;

    select bb.reception_id, bb.verified_weight_kg
      into v_big_bag_reception_id, v_big_bag_verified
    from public.big_bags bb
    where bb.id = v_big_bag_id;

    if v_big_bag_reception_id <> v_reception_id then
      raise exception 'VALIDATION: Big Bag does not belong to availability reception';
    end if;

    select coalesce(sum(mm.quantity_kg),0)
      into v_big_bag_consumed
    from public.material_movements mm
    where mm.organization_id = v_organization_id
      and mm.big_bag_id = v_big_bag_id
      and mm.movement_type = 'CONSUMO';

    v_big_bag_balance := v_big_bag_verified - v_big_bag_consumed;

    if v_line_quantity > v_big_bag_balance then
      raise exception
        'VALIDATION: quantity_kg exceeds Big Bag available weight: %',
        v_big_bag_id;
    end if;
  end loop;

  -- Validate grouped consumption against every aggregated availability.
  for v_availability_id in
    select distinct (value->>'availability_id')::uuid
    from jsonb_array_elements(v_consumptions)
    order by 1
  loop
    select ma.quantity_available_kg
      into v_available
    from public.material_availability ma
    where ma.id = v_availability_id
      and ma.organization_id = v_organization_id;

    select coalesce(sum((value->>'quantity_kg')::numeric),0)
      into v_group_quantity
    from jsonb_array_elements(v_consumptions)
    where (value->>'availability_id')::uuid = v_availability_id;

    if v_group_quantity > v_available then
      raise exception
        'VALIDATION: grouped consumption exceeds availability balance: %',
        v_availability_id;
    end if;
  end loop;

  -- Update every affected aggregated availability atomically.
  for v_availability_id in
    select distinct (value->>'availability_id')::uuid
    from jsonb_array_elements(v_consumptions)
    order by 1
  loop
    select ma.quantity_available_kg
      into v_available
    from public.material_availability ma
    where ma.id = v_availability_id
      and ma.organization_id = v_organization_id;

    select coalesce(sum((value->>'quantity_kg')::numeric),0)
      into v_group_quantity
    from jsonb_array_elements(v_consumptions)
    where (value->>'availability_id')::uuid = v_availability_id;

    v_new_available := v_available - v_group_quantity;
    v_new_status := case
      when v_new_available = 0 then 'AGOTADO'
      else 'DISPONIBLE'
    end;

    update public.material_availability
    set quantity_available_kg = v_new_available,
        status = v_new_status,
        updated_at = now()
    where id = v_availability_id
      and organization_id = v_organization_id;
  end loop;

  -- Insert one movement and one production input per physical Big Bag line.
  for v_line in
    select value
    from jsonb_array_elements(v_consumptions)
  loop
    v_availability_id := (v_line->>'availability_id')::uuid;
    v_big_bag_id := (v_line->>'big_bag_id')::uuid;
    v_line_quantity := (v_line->>'quantity_kg')::numeric;

    select ma.reception_id
      into v_reception_id
    from public.material_availability ma
    where ma.id = v_availability_id
      and ma.organization_id = v_organization_id;

    select count(*)
      into v_agricultural_lot_count
    from public.reception_agricultural_lots ral
    where ral.reception_id = v_reception_id
      and ral.interpretation_status = 'CONFIRMADO';

    if v_agricultural_lot_count = 1 then
      select ral.agricultural_lot_id
        into v_agricultural_lot_id
      from public.reception_agricultural_lots ral
      where ral.reception_id = v_reception_id
        and ral.interpretation_status = 'CONFIRMADO';
      v_traceability_status := 'CONFIRMADO';
    else
      v_agricultural_lot_id := null;
      v_traceability_status := 'PENDIENTE';
    end if;

    insert into public.material_movements(
      organization_id,availability_id,reception_id,big_bag_id,movement_type,
      quantity_kg,movement_datetime,reference_type,reference_id,observations
    ) values(
      v_organization_id,v_availability_id,v_reception_id,v_big_bag_id,'CONSUMO',
      v_line_quantity,now(),'PRODUCTION_ORDER',v_production_order_id,v_observations
    ) returning id into v_movement_id;

    insert into public.production_inputs(
      production_order_id,material_availability_id,material_movement_id,reception_id,
      big_bag_id,agricultural_lot_id,harvest_id,quantity_kg,input_datetime,
      traceability_status,evidence_reference,observations
    ) values(
      v_production_order_id,v_availability_id,v_movement_id,v_reception_id,
      v_big_bag_id,v_agricultural_lot_id,null,v_line_quantity,now(),
      v_traceability_status,v_evidence_reference,v_observations
    ) returning id into v_input_id;

    select ma.quantity_available_kg
      into v_new_available
    from public.material_availability ma
    where ma.id = v_availability_id;

    select bb.verified_weight_kg - coalesce(sum(mm.quantity_kg),0)
      into v_big_bag_balance
    from public.big_bags bb
    left join public.material_movements mm
      on mm.big_bag_id = bb.id
     and mm.organization_id = v_organization_id
     and mm.movement_type = 'CONSUMO'
    where bb.id = v_big_bag_id
    group by bb.verified_weight_kg;

    v_result_item := jsonb_build_object(
      'big_bag_id',v_big_bag_id,
      'quantity_kg',v_line_quantity,
      'quantity_available_kg',v_big_bag_balance,
      'availability_id',v_availability_id,
      'availability_quantity_available_kg',v_new_available,
      'reception_id',v_reception_id,
      'movement_id',v_movement_id,
      'production_input_id',v_input_id,
      'agricultural_lot_id',v_agricultural_lot_id,
      'harvest_id',null,
      'traceability_status',v_traceability_status
    );

    v_result_items := v_result_items || jsonb_build_array(v_result_item);
  end loop;

  return jsonb_build_object(
    'production_order_id',v_production_order_id,
    'quantity_kg',v_requested_quantity,
    'consumptions',v_result_items,
    'consumption_count',v_line_count,
    'traceability_source','material_movements'
  );
end;
$$;

revoke all on function public.consume_material_transaction(jsonb) from public;
grant execute on function public.consume_material_transaction(jsonb) to authenticated;

insert into public.schema_migrations
  (migration_code, migration_name, executed_by, notes)
select
  'MPCF-025',
  'CONSUMPTION_TRANSACTION_MULTI_BIG_BAG_V1',
  auth.uid(),
  'Evolucion de MPCF-022 para consumo atomico multi-Big-Bag y multiples disponibilidades.'
where not exists (
  select 1
  from public.schema_migrations
  where migration_code = 'MPCF-025'
);

select 'MPCF-025 PREPARED' as status;
