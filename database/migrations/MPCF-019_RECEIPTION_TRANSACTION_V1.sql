-- ============================================================
-- MPCF-019 — RECEIPTION TRANSACTION V1
-- TRAZIX HG / MPCF Platform
--
-- Objetivo:
-- 1) Registrar recepción + REF-EXT + Big Bags + relación agrícola
--    como una única operación transaccional.
-- 2) Evitar recepciones parcialmente creadas por fallos de red/UI.
-- 3) Validar permiso, proveedor, pesos y asociación agrícola.
--
-- No crea datos históricos. No crea usuarios.
-- No modifica disponibilidad/inventario todavía (MPCF-020).
-- ============================================================

create or replace function public.register_biomass_reception(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_user uuid := auth.uid();
  v_reception_id uuid;
  v_external_reference_id uuid;
  v_supplier_id uuid;
  v_supplier_name text;
  v_code text := nullif(trim(p_payload->>'reception_code'),'');
  v_dt timestamptz := nullif(p_payload->>'reception_datetime','')::timestamptz;
  v_decl numeric := nullif(p_payload->>'declared_weight_kg','')::numeric;
  v_ver numeric := nullif(p_payload->>'verified_weight_kg','')::numeric;
  v_status text := coalesce(nullif(p_payload->>'status',''),'RECIBIDA');
  v_type text := coalesce(nullif(p_payload->>'biomass_type',''),'FRESCA');
  v_ref text := nullif(trim(p_payload->>'external_reference'),'');
  v_lot uuid := nullif(p_payload->>'agricultural_lot_id','')::uuid;
  v_lotkg numeric := nullif(p_payload->>'agricultural_lot_quantity_kg','')::numeric;
  v_bag jsonb;
  v_total numeric := 0;
  v_bag_count integer := 0;
  v_code_key text;
begin
  if v_user is null then
    raise exception 'AUTH_REQUIRED';
  end if;
  if not private.current_user_has_permission('reception.write') then
    raise exception 'PERMISSION_DENIED: reception.write';
  end if;
  v_supplier_id := nullif(p_payload->>'supplier_organization_id','')::uuid;
  if v_code is null then raise exception 'VALIDATION: reception_code is required'; end if;
  if v_dt is null then raise exception 'VALIDATION: reception_datetime is required'; end if;
  if v_supplier_id is null then raise exception 'VALIDATION: supplier_organization_id is required'; end if;
  if v_ver is null or v_ver <= 0 then raise exception 'VALIDATION: verified_weight_kg must be > 0'; end if;
  if jsonb_typeof(coalesce(p_payload->'big_bags','null'::jsonb)) <> 'array' or jsonb_array_length(p_payload->'big_bags') = 0 then
    raise exception 'VALIDATION: at least one Big Bag is required';
  end if;

  select o.name into v_supplier_name
  from public.organizations o
  where o.id = v_supplier_id
    and o.organization_type = 'EXTERNO'
    and o.is_active = true;
  if v_supplier_name is null then
    raise exception 'VALIDATION: supplier must be an active EXTERNO organization';
  end if;

  if exists(select 1 from public.biomass_receptions where reception_code = v_code) then
    raise exception 'DUPLICATE: reception_code already exists: %', v_code;
  end if;

  if v_lot is not null then
    if v_lotkg is null or v_lotkg <= 0 or v_lotkg > v_ver then
      raise exception 'VALIDATION: agricultural lot quantity is invalid';
    end if;
    if not exists(select 1 from public.agricultural_lots where id=v_lot) then
      raise exception 'VALIDATION: agricultural lot not found';
    end if;
  elsif v_lotkg is not null then
    raise exception 'VALIDATION: agricultural_lot_quantity_kg requires agricultural_lot_id';
  end if;

  for v_bag in select value from jsonb_array_elements(p_payload->'big_bags') loop
    v_code_key := upper(trim(v_bag->>'big_bag_code'));
    if v_code_key = '' then raise exception 'VALIDATION: every Big Bag requires big_bag_code'; end if;
    if (select count(*) from jsonb_array_elements(p_payload->'big_bags') x where upper(trim(x->>'big_bag_code')) = v_code_key) > 1 then
      raise exception 'DUPLICATE: repeated Big Bag code: %', v_code_key;
    end if;
    if nullif(v_bag->>'verified_weight_kg','')::numeric is null or nullif(v_bag->>'verified_weight_kg','')::numeric <= 0 then
      raise exception 'VALIDATION: Big Bag % must have verified_weight_kg > 0', v_code_key;
    end if;
    v_total := v_total + nullif(v_bag->>'verified_weight_kg','')::numeric;
    v_bag_count := v_bag_count + 1;
  end loop;

  if abs(v_total - v_ver) > 0.001 then
    raise exception 'MASS_BALANCE: Big Bags total % kg does not equal reception verified weight % kg', round(v_total,3), round(v_ver,3);
  end if;

  if v_ref is not null then
    insert into public.external_references(reference_type,raw_value,source_system,interpretation_status,description)
    values('REF-EXT',v_ref,'RECEPCION','PENDIENTE','REF-EXT conservado desde recepción operativa')
    on conflict (reference_type,raw_value,source_system) do update
      set description=excluded.description;
    select id into v_external_reference_id
    from public.external_references
    where reference_type='REF-EXT' and raw_value=v_ref and source_system='RECEPCION';
  end if;

  insert into public.biomass_receptions(
    reception_code,reception_datetime,supplier_organization_id,supplier_name_declared,
    declared_weight_kg,verified_weight_kg,weight_unit,external_reference_id,status,
    evidence_reference,observations
  ) values(
    v_code,v_dt,v_supplier_id,v_supplier_name,v_decl,v_ver,'KG',v_external_reference_id,
    v_status,v_ref,nullif(p_payload->>'observations','')
  ) returning id into v_reception_id;

  for v_bag in select value from jsonb_array_elements(p_payload->'big_bags') loop
    insert into public.big_bags(
      reception_id,big_bag_code,external_reference,supplier_name_declared,
      declared_weight_kg,verified_weight_kg,biomass_type,evidence_reference,status
    ) values(
      v_reception_id,trim(v_bag->>'big_bag_code'),nullif(trim(v_bag->>'external_reference'),''),v_supplier_name,
      nullif(v_bag->>'declared_weight_kg','')::numeric,nullif(v_bag->>'verified_weight_kg','')::numeric,
      coalesce(nullif(v_bag->>'biomass_type',''),v_type),nullif(trim(v_bag->>'evidence_reference'),''),
      coalesce(nullif(v_bag->>'status',''),'RECIBIDO')
    );
  end loop;

  if v_lot is not null then
    insert into public.reception_agricultural_lots(
      reception_id,agricultural_lot_id,quantity_kg,evidence_description,interpretation_status
    ) values(
      v_reception_id,v_lot,v_lotkg,'Asociación documental registrada desde recepción operativa','CONFIRMADO'
    );
  end if;

  return jsonb_build_object(
    'reception_id',v_reception_id,
    'reception_code',v_code,
    'big_bags_count',v_bag_count,
    'verified_weight_kg',v_ver,
    'big_bags_verified_weight_kg',round(v_total,3),
    'external_reference_id',v_external_reference_id,
    'agricultural_lot_id',v_lot
  );
end;
$$;

revoke all on function public.register_biomass_reception(jsonb) from public;
grant execute on function public.register_biomass_reception(jsonb) to authenticated;

insert into public.schema_migrations
  (migration_code, migration_name, executed_by, notes)
select
  'MPCF-019',
  'RECEIPTION_TRANSACTION_V1',
  auth.uid(),
  'Registro transaccional de recepción + Big Bags + REF-EXT + lote agrícola.'
where not exists (
  select 1 from public.schema_migrations where migration_code='MPCF-019'
);

select 'MPCF-019 OK' as status;
