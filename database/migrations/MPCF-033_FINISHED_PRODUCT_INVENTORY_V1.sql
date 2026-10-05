-- ============================================================
-- MPCF-033 - FINISHED PRODUCT INVENTORY V1
-- TRAZIX HG / MPCF Platform
-- MOD-007 INVENTARIO > PRODUCTO TERMINADO
--
-- Estado: PREPARADO (SQL versionado). Ejecucion NO CONFIRMADA.
--
-- Alcance: solo Inventario de Producto Terminado (COD / ISOL).
-- - La unica entrada implementada nace del evento real de EMPAQUE:
--   production_process_events (event_type = 'EMPAQUE',
--   stage_status = 'COMPLETADA'), cantidad = packing_quantity_kg.
-- - El saldo NO se almacena: se deriva de los movimientos.
-- - Los movimientos son de solo insercion; no existe RPC ni grant
--   de escritura para el frontend (sin movimientos manuales).
-- - SALIDA existe como tipo y esta protegida contra saldo negativo,
--   pero ningun flujo la genera todavia (Producto/ISOL y Despacho
--   no estan implementados). ISOL queda como tipo permitido sin
--   ninguna relacion inventada.
-- - % CBD y color no se duplican: se leen al consultar desde
--   Laboratorio (CBD_PACKING, fuente oficial cuando existe),
--   packing_cbd_percent (EMPAQUE) y drying_color (SECADO).
-- - Lectura protegida con el permiso existente produccion.read
--   (no se crea ningun permiso nuevo; punto pendiente de decision).
-- No modifica Produccion, Laboratorio, Consumo, MPCF-029..032.
-- Los COD con EMPAQUE anterior a esta migracion NO se cargan
-- (carga historica: decision pendiente).
-- ============================================================

create table if not exists public.finished_products (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  product_type text not null,
  product_code text not null,
  product_name text not null,
  unit text not null default 'kg',
  production_order_id uuid references public.production_orders(id),
  source_event_id uuid references public.production_process_events(id),
  entered_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  constraint finished_products_type_check check (product_type in ('COD', 'ISOL')),
  constraint finished_products_unit_check check (unit = 'kg')
);

create unique index if not exists finished_products_source_event_uidx
  on public.finished_products(source_event_id)
  where source_event_id is not null;
create index if not exists finished_products_org_idx
  on public.finished_products(organization_id, product_type, entered_at desc);

create table if not exists public.finished_product_movements (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  finished_product_id uuid not null references public.finished_products(id),
  movement_type text not null,
  quantity_kg numeric not null,
  unit text not null default 'kg',
  movement_datetime timestamptz not null default now(),
  reference_type text not null,
  reference_id uuid not null,
  created_by uuid,
  observations text,
  constraint finished_product_movements_type_check check (movement_type in ('ENTRADA', 'SALIDA')),
  constraint finished_product_movements_quantity_check check (quantity_kg > 0),
  constraint finished_product_movements_unit_check check (unit = 'kg')
);

-- Una ENTRADA por producto y evento origen: evita duplicar existencias.
create unique index if not exists finished_product_movements_entry_uidx
  on public.finished_product_movements(finished_product_id, reference_type, reference_id)
  where movement_type = 'ENTRADA';
create index if not exists finished_product_movements_product_idx
  on public.finished_product_movements(finished_product_id, movement_datetime);

create or replace function private.guard_finished_product_ledger()
returns trigger
language plpgsql
security definer
set search_path = public, private, pg_catalog
as $$
declare
  v_balance numeric;
begin
  if tg_op in ('UPDATE', 'DELETE') then
    raise exception 'VALIDATION: finished product inventory records are append-only';
  end if;

  if tg_table_name = 'finished_product_movements' then
    perform 1 from public.finished_products fp
    where fp.id = new.finished_product_id
      and fp.organization_id = new.organization_id
    for update;
    if not found then
      raise exception 'VALIDATION: finished product not found for organization';
    end if;

    if new.movement_type = 'SALIDA' then
      select coalesce(sum(case when m.movement_type = 'ENTRADA' then m.quantity_kg else -m.quantity_kg end), 0)
        into v_balance
      from public.finished_product_movements m
      where m.finished_product_id = new.finished_product_id;
      if new.quantity_kg > v_balance then
        raise exception 'VALIDATION: SALIDA exceeds finished product balance';
      end if;
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists finished_products_append_only on public.finished_products;
create trigger finished_products_append_only
before update or delete on public.finished_products
for each row execute function private.guard_finished_product_ledger();

drop trigger if exists finished_product_movements_ledger on public.finished_product_movements;
create trigger finished_product_movements_ledger
before insert or update or delete on public.finished_product_movements
for each row execute function private.guard_finished_product_ledger();

-- Entrada automatica originada en el evento real de EMPAQUE.
-- Idempotente: reprocesar el mismo evento no duplica existencia ni movimiento.
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

  v_code := 'COD' || lpad(v_cod::text, 2, '0');

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

drop trigger if exists production_packing_finished_product_entry on public.production_process_events;
create trigger production_packing_finished_product_entry
after insert or update of stage_status, packing_quantity_kg on public.production_process_events
for each row execute function private.record_finished_product_entry_from_packing();

alter table public.finished_products enable row level security;
alter table public.finished_product_movements enable row level security;

drop policy if exists finished_products_read on public.finished_products;
create policy finished_products_read on public.finished_products
for select to authenticated
using (
  organization_id = (select p.organization_id from public.profiles p where p.id = auth.uid())
  and private.current_user_has_permission('produccion.read')
);

drop policy if exists finished_product_movements_read on public.finished_product_movements;
create policy finished_product_movements_read on public.finished_product_movements
for select to authenticated
using (
  organization_id = (select p.organization_id from public.profiles p where p.id = auth.uid())
  and private.current_user_has_permission('produccion.read')
);

revoke all on public.finished_products from public, anon, authenticated;
revoke all on public.finished_product_movements from public, anon, authenticated;

create or replace function public.get_finished_product_inventory()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, private, pg_catalog
as $$
declare
  v_user uuid := auth.uid();
  v_organization_id uuid;
  v_items jsonb;
begin
  if v_user is null then raise exception 'AUTH_REQUIRED'; end if;
  if not private.current_user_has_permission('produccion.read') then
    raise exception 'PERMISSION_DENIED: produccion.read';
  end if;
  select p.organization_id into v_organization_id from public.profiles p where p.id = v_user;
  if v_organization_id is null then raise exception 'ORGANIZATION_REQUIRED'; end if;

  select coalesce(jsonb_agg(item order by (item->>'entered_at') desc), '[]'::jsonb)
    into v_items
  from (
    select jsonb_build_object(
      'id', fp.id,
      'product_type', fp.product_type,
      'product_code', fp.product_code,
      'product_name', fp.product_name,
      'unit', fp.unit,
      'entered_at', fp.entered_at,
      'production_order_id', fp.production_order_id,
      'source_event_id', fp.source_event_id,
      'production_date', po.production_date,
      'initial_quantity_kg', (
        select m.quantity_kg from public.finished_product_movements m
        where m.finished_product_id = fp.id and m.movement_type = 'ENTRADA'
        order by m.movement_datetime, m.id limit 1
      ),
      'entries_kg', t.entries_kg,
      'exits_kg', t.exits_kg,
      'balance_kg', t.entries_kg - t.exits_kg,
      'status', case when t.entries_kg - t.exits_kg > 0 then 'DISPONIBLE' else 'AGOTADO' end,
      'cbd_percent', coalesce(lab.result_value, ev.packing_cbd_percent),
      'cbd_source', case
        when lab.result_value is not null then 'LABORATORIO'
        when ev.packing_cbd_percent is not null then 'EMPAQUE'
        else null end,
      'color', col.drying_color,
      'origin', case when fp.source_event_id is not null then 'EMPAQUE / ' || fp.product_code else null end
    ) as item
    from public.finished_products fp
    left join public.production_orders po on po.id = fp.production_order_id
    left join public.production_process_events ev on ev.id = fp.source_event_id
    left join lateral (
      select r.result_value
      from public.laboratory_samples s
      join public.laboratory_results r on r.sample_id = s.id
      where s.production_process_event_id = fp.source_event_id
        and s.sample_type = 'STAGE_OUTPUT'
        and s.analytical_status in ('RESULTADO REGISTRADO', 'VALIDADO')
        and r.attribute_code = 'CBD_PACKING'
      order by r.updated_at desc nulls last
      limit 1
    ) lab on true
    left join lateral (
      select e.drying_color
      from public.production_process_events e
      where e.production_order_id = fp.production_order_id and e.event_type = 'SECADO'
    ) col on true
    cross join lateral (
      select
        coalesce(sum(m.quantity_kg) filter (where m.movement_type = 'ENTRADA'), 0) as entries_kg,
        coalesce(sum(m.quantity_kg) filter (where m.movement_type = 'SALIDA'), 0) as exits_kg
      from public.finished_product_movements m
      where m.finished_product_id = fp.id
    ) t
    where fp.organization_id = v_organization_id
  ) q;

  return v_items;
end;
$$;

create or replace function public.get_finished_product_movements(p_product_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, private, pg_catalog
as $$
declare
  v_user uuid := auth.uid();
  v_organization_id uuid;
begin
  if v_user is null then raise exception 'AUTH_REQUIRED'; end if;
  if not private.current_user_has_permission('produccion.read') then
    raise exception 'PERMISSION_DENIED: produccion.read';
  end if;
  select p.organization_id into v_organization_id from public.profiles p where p.id = v_user;
  if v_organization_id is null then raise exception 'ORGANIZATION_REQUIRED'; end if;

  if not exists (
    select 1 from public.finished_products fp
    where fp.id = p_product_id and fp.organization_id = v_organization_id
  ) then
    raise exception 'VALIDATION: finished product not found';
  end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', m.id,
      'movement_type', m.movement_type,
      'quantity_kg', m.quantity_kg,
      'unit', m.unit,
      'movement_datetime', m.movement_datetime,
      'reference_type', m.reference_type,
      'reference_id', m.reference_id,
      'created_by', m.created_by,
      'observations', m.observations
    ) order by m.movement_datetime desc, m.id)
    from public.finished_product_movements m
    where m.finished_product_id = p_product_id
      and m.organization_id = v_organization_id
  ), '[]'::jsonb);
end;
$$;

revoke all on function private.guard_finished_product_ledger() from public, anon, authenticated;
revoke all on function private.record_finished_product_entry_from_packing() from public, anon, authenticated;
revoke all on function public.get_finished_product_inventory() from public, anon;
revoke all on function public.get_finished_product_movements(uuid) from public, anon;
grant execute on function public.get_finished_product_inventory() to authenticated;
grant execute on function public.get_finished_product_movements(uuid) to authenticated;

insert into public.schema_migrations
  (migration_code, migration_name, executed_by, notes)
select
  'MPCF-033',
  'FINISHED_PRODUCT_INVENTORY_V1',
  auth.uid(),
  'MOD-007 Inventario de Producto Terminado: existencias, movimientos ENTRADA/SALIDA y entrada automatica por EMPAQUE.'
where not exists (
  select 1
  from public.schema_migrations
  where migration_code = 'MPCF-033'
);

select 'MPCF-033 FINISHED PRODUCT INVENTORY V1 PREPARED - NOT EXECUTED' as status;
