-- ============================================================
-- MPCF-036 - MOD-011 SALES V1
-- TRAZIX HG / MPCF Platform
--
-- Estado: PREPARADO (SQL versionado). Ejecucion NO CONFIRMADA.
-- Requiere MPCF-035 para vincular un despacho operativo existente.
--
-- Ventas registra la necesidad del cliente y la preparación explícita
-- indicada por Operaciones. No reserva ni modifica existencias; solo
-- referencia una salida ya creada por Producto / ISOL. El EXCESO queda
-- como dato trazable del pedido y permanece en el saldo MOD-007 existente.
-- ============================================================

create table public.sales_customers (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  legal_name text not null,
  identification text,
  contact text,
  status text not null default 'ACTIVO',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint sales_customers_name_check check (length(trim(legal_name)) > 0),
  constraint sales_customers_status_check check (status in ('ACTIVO', 'INACTIVO'))
);

create unique index sales_customers_identification_uidx
  on public.sales_customers(organization_id, identification)
  where identification is not null;
create index sales_customers_org_status_name_idx
  on public.sales_customers(organization_id, status, legal_name);

create table public.sales_orders (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  order_number bigint generated always as identity,
  request_id uuid not null,
  customer_id uuid not null references public.sales_customers(id),
  requested_product text not null,
  quantity numeric not null,
  unit text not null,
  requirements text,
  observations text,
  status text not null default 'PEDIDO REGISTRADO',
  registered_by uuid not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  preparation_started_by uuid,
  preparation_started_at timestamptz,
  prepared_product_id uuid references public.finished_products(id),
  prepared_quantity numeric,
  excess_quantity numeric,
  ready_by uuid,
  ready_at timestamptz,
  dispatched_by uuid,
  dispatched_at timestamptz,
  closed_by uuid,
  closed_at timestamptz,
  dispatch_operation_id uuid references public.product_isol_operations(id),
  finished_product_id uuid references public.finished_products(id),
  inventory_movement_id uuid references public.finished_product_movements(id),
  constraint sales_orders_org_number_uidx unique (organization_id, order_number),
  constraint sales_orders_org_request_uidx unique (organization_id, request_id),
  constraint sales_orders_dispatch_operation_uidx unique (dispatch_operation_id),
  constraint sales_orders_quantity_check check (quantity > 0),
  constraint sales_orders_prepared_quantity_check check (prepared_quantity is null or prepared_quantity > 0),
  constraint sales_orders_excess_quantity_check check (excess_quantity is null or excess_quantity >= 0),
  constraint sales_orders_unit_check check (unit in ('g', 'kg')),
  constraint sales_orders_product_check check (length(trim(requested_product)) > 0),
  constraint sales_orders_status_check check (
    status in ('PEDIDO REGISTRADO', 'EN PREPARACIÓN', 'LISTO PARA DESPACHO', 'DESPACHADO', 'CERRADO')
  ),
  constraint sales_orders_dispatch_fields_check check (
    (status not in ('DESPACHADO', 'CERRADO')) or
    (dispatch_operation_id is not null and finished_product_id is not null
      and finished_product_id = prepared_product_id
      and inventory_movement_id is not null and dispatched_by is not null and dispatched_at is not null)
  ),
  constraint sales_orders_close_fields_check check (
    (status <> 'CERRADO') or (closed_by is not null and closed_at is not null)
  ),
  constraint sales_orders_preparation_fields_check check (
    (status = 'PEDIDO REGISTRADO' and preparation_started_by is null and preparation_started_at is null) or
    (status <> 'PEDIDO REGISTRADO' and preparation_started_by is not null and preparation_started_at is not null)
  ),
  constraint sales_orders_ready_fields_check check (
    (status not in ('LISTO PARA DESPACHO', 'DESPACHADO', 'CERRADO')) or
    (prepared_product_id is not null and prepared_quantity is not null and prepared_quantity >= quantity
      and excess_quantity is not null
      and excess_quantity = prepared_quantity - quantity
      and ready_by is not null and ready_at is not null)
  )
);

create index sales_orders_org_status_created_idx
  on public.sales_orders(organization_id, status, created_at desc);
create index sales_orders_org_customer_created_idx
  on public.sales_orders(organization_id, customer_id, created_at desc);

insert into public.permissions (code, resource, action, description)
values
  ('ventas.read', 'ventas', 'read', 'Permite consultar clientes y pedidos de venta.'),
  ('ventas.write', 'ventas', 'write', 'Permite registrar clientes y pedidos y actualizar su estado comercial.')
on conflict (code) do nothing;

create or replace function private.set_sales_order_updated_at()
returns trigger
language plpgsql
security definer
set search_path = public, private, pg_catalog
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists sales_orders_updated_at on public.sales_orders;
create trigger sales_orders_updated_at
before update on public.sales_orders
for each row execute function private.set_sales_order_updated_at();
revoke all on function private.set_sales_order_updated_at() from public, anon, authenticated;

alter table public.sales_customers enable row level security;
alter table public.sales_orders enable row level security;
revoke all on public.sales_customers from public, anon, authenticated;
revoke all on public.sales_orders from public, anon, authenticated;

create or replace function public.create_sales_customer(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, private, pg_catalog
as $$
declare
  v_user uuid := auth.uid();
  v_organization_id uuid;
  v_name text;
  v_identification text;
  v_contact text;
  v_customer public.sales_customers%rowtype;
begin
  if v_user is null then raise exception 'AUTH_REQUIRED'; end if;
  if not private.current_user_has_permission('ventas.write') then
    raise exception 'PERMISSION_DENIED: ventas.write';
  end if;
  select p.organization_id into v_organization_id
  from public.profiles p where p.id = v_user;
  if v_organization_id is null then raise exception 'ORGANIZATION_REQUIRED'; end if;
  if p_payload is null or jsonb_typeof(p_payload) <> 'object' then
    raise exception 'VALIDATION: payload must be an object';
  end if;
  if jsonb_typeof(p_payload->'legal_name') is distinct from 'string' then
    raise exception 'VALIDATION: customer name is required';
  end if;
  if (p_payload ? 'identification' and jsonb_typeof(p_payload->'identification') not in ('string', 'null'))
     or (p_payload ? 'contact' and jsonb_typeof(p_payload->'contact') not in ('string', 'null')) then
    raise exception 'VALIDATION: identification and contact must be text or null';
  end if;

  v_name := nullif(trim(p_payload->>'legal_name'), '');
  v_identification := nullif(trim(p_payload->>'identification'), '');
  v_contact := nullif(trim(p_payload->>'contact'), '');
  if v_name is null then raise exception 'VALIDATION: customer name is required'; end if;

  insert into public.sales_customers(
    organization_id, legal_name, identification, contact
  ) values (
    v_organization_id, v_name, v_identification, v_contact
  ) returning * into v_customer;

  return jsonb_build_object(
    'id', v_customer.id, 'legal_name', v_customer.legal_name,
    'identification', v_customer.identification, 'contact', v_customer.contact,
    'status', v_customer.status, 'created_at', v_customer.created_at
  );
end;
$$;

create or replace function public.get_sales_customers()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, private, pg_catalog
as $$
declare
  v_user uuid := auth.uid();
  v_organization_id uuid;
  v_customers jsonb;
begin
  if v_user is null then raise exception 'AUTH_REQUIRED'; end if;
  if not private.current_user_has_permission('ventas.read') then
    raise exception 'PERMISSION_DENIED: ventas.read';
  end if;
  select p.organization_id into v_organization_id
  from public.profiles p where p.id = v_user;
  if v_organization_id is null then raise exception 'ORGANIZATION_REQUIRED'; end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', c.id, 'legal_name', c.legal_name,
    'identification', c.identification, 'contact', c.contact,
    'status', c.status, 'created_at', c.created_at
  ) order by c.legal_name, c.id), '[]'::jsonb)
  into v_customers
  from public.sales_customers c
  where c.organization_id = v_organization_id;
  return v_customers;
end;
$$;

create or replace function public.create_sales_order(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, private, pg_catalog
as $$
declare
  v_user uuid := auth.uid();
  v_organization_id uuid;
  v_request_id uuid;
  v_customer_id uuid;
  v_product text;
  v_quantity numeric;
  v_unit text;
  v_requirements text;
  v_observations text;
  v_order public.sales_orders%rowtype;
begin
  if v_user is null then raise exception 'AUTH_REQUIRED'; end if;
  if not private.current_user_has_permission('ventas.write') then
    raise exception 'PERMISSION_DENIED: ventas.write';
  end if;
  select p.organization_id into v_organization_id
  from public.profiles p where p.id = v_user;
  if v_organization_id is null then raise exception 'ORGANIZATION_REQUIRED'; end if;
  if p_payload is null or jsonb_typeof(p_payload) <> 'object' then
    raise exception 'VALIDATION: payload must be an object';
  end if;
  if coalesce(p_payload->>'request_id', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    raise exception 'VALIDATION: request_id must be a UUID';
  end if;
  if coalesce(p_payload->>'customer_id', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    raise exception 'VALIDATION: customer_id is required';
  end if;
  if jsonb_typeof(p_payload->'requested_product') is distinct from 'string' then
    raise exception 'VALIDATION: requested product is required';
  end if;
  if jsonb_typeof(p_payload->'quantity') is distinct from 'number' then
    raise exception 'VALIDATION: quantity must be numeric';
  end if;
  if jsonb_typeof(p_payload->'unit') is distinct from 'string' then
    raise exception 'VALIDATION: unit is required';
  end if;
  if (p_payload ? 'requirements' and jsonb_typeof(p_payload->'requirements') not in ('string', 'null'))
     or (p_payload ? 'observations' and jsonb_typeof(p_payload->'observations') not in ('string', 'null')) then
    raise exception 'VALIDATION: requirements and observations must be text or null';
  end if;

  v_request_id := (p_payload->>'request_id')::uuid;
  v_customer_id := (p_payload->>'customer_id')::uuid;
  v_product := nullif(trim(p_payload->>'requested_product'), '');
  v_quantity := (p_payload->>'quantity')::numeric;
  v_unit := lower(trim(p_payload->>'unit'));
  v_requirements := nullif(trim(p_payload->>'requirements'), '');
  v_observations := nullif(trim(p_payload->>'observations'), '');
  if v_product is null then raise exception 'VALIDATION: requested product is required'; end if;
  if v_quantity <= 0 then raise exception 'VALIDATION: quantity must be > 0'; end if;
  if v_unit not in ('g', 'kg') then raise exception 'VALIDATION: unit must be g or kg'; end if;
  if not exists (
    select 1 from public.sales_customers c
    where c.id = v_customer_id and c.organization_id = v_organization_id and c.status = 'ACTIVO'
  ) then
    raise exception 'VALIDATION: active customer not found';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(v_organization_id::text || ':' || v_request_id::text, 0));
  select * into v_order
  from public.sales_orders o
  where o.organization_id = v_organization_id and o.request_id = v_request_id;
  if found then
    if v_order.customer_id <> v_customer_id
       or v_order.requested_product <> v_product
       or v_order.quantity <> v_quantity
       or v_order.unit <> v_unit
       or v_order.requirements is distinct from v_requirements
       or v_order.observations is distinct from v_observations then
      raise exception 'IDEMPOTENCY_CONFLICT: request_id was already used with different input';
    end if;
    return jsonb_build_object(
      'id', v_order.id, 'order_number', v_order.order_number,
      'status', v_order.status, 'created_at', v_order.created_at, 'replayed', true
    );
  end if;

  insert into public.sales_orders(
    organization_id, request_id, customer_id, requested_product, quantity, unit,
    requirements, observations, registered_by
  ) values (
    v_organization_id, v_request_id, v_customer_id, v_product, v_quantity, v_unit,
    v_requirements, v_observations, v_user
  ) returning * into v_order;

  return jsonb_build_object(
    'id', v_order.id, 'order_number', v_order.order_number,
    'status', v_order.status, 'created_at', v_order.created_at, 'replayed', false
  );
end;
$$;

create or replace function public.get_sales_orders(
  p_status text default null,
  p_customer_id uuid default null,
  p_from_date date default null,
  p_to_date date default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, private, pg_catalog
as $$
declare
  v_user uuid := auth.uid();
  v_organization_id uuid;
  v_orders jsonb;
  v_status text := nullif(trim(p_status), '');
begin
  if v_user is null then raise exception 'AUTH_REQUIRED'; end if;
  if not private.current_user_has_permission('ventas.read') then
    raise exception 'PERMISSION_DENIED: ventas.read';
  end if;
  select p.organization_id into v_organization_id
  from public.profiles p where p.id = v_user;
  if v_organization_id is null then raise exception 'ORGANIZATION_REQUIRED'; end if;
  if v_status is not null and v_status not in (
    'PEDIDO REGISTRADO', 'EN PREPARACIÓN', 'LISTO PARA DESPACHO', 'DESPACHADO', 'CERRADO'
  ) then raise exception 'VALIDATION: invalid status filter'; end if;
  if p_from_date is not null and p_to_date is not null and p_from_date > p_to_date then
    raise exception 'VALIDATION: from date cannot be after to date';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', o.id,
    'order_number', o.order_number,
    'customer_id', c.id,
    'customer_name', c.legal_name,
    'requested_product', o.requested_product,
    'quantity', o.quantity,
    'unit', o.unit,
    'requirements', o.requirements,
    'observations', o.observations,
    'status', o.status,
    'registered_by', o.registered_by,
    'created_at', o.created_at,
    'updated_at', o.updated_at,
    'preparation_started_by', o.preparation_started_by,
    'preparation_started_at', o.preparation_started_at,
    'prepared_product_id', o.prepared_product_id,
    'prepared_product_code', prepared_fp.product_code,
    'prepared_product_type', prepared_fp.product_type,
    'prepared_quantity', o.prepared_quantity,
    'excess_quantity', o.excess_quantity,
    'ready_by', o.ready_by,
    'ready_at', o.ready_at,
    'dispatched_by', o.dispatched_by,
    'dispatched_at', o.dispatched_at,
    'closed_by', o.closed_by,
    'closed_at', o.closed_at,
    'dispatch_operation_id', o.dispatch_operation_id,
    'dispatch_reference', op.reference,
    'finished_product_id', fp.id,
    'finished_product_code', fp.product_code,
    'inventory_movement_id', m.id
  ) order by o.created_at desc, o.order_number desc), '[]'::jsonb)
  into v_orders
  from public.sales_orders o
  join public.sales_customers c on c.id = o.customer_id
  left join public.finished_products prepared_fp on prepared_fp.id = o.prepared_product_id
  left join public.product_isol_operations op on op.id = o.dispatch_operation_id
  left join public.finished_products fp on fp.id = o.finished_product_id
  left join public.finished_product_movements m on m.id = o.inventory_movement_id
  where o.organization_id = v_organization_id
    and (v_status is null or o.status = v_status)
    and (p_customer_id is null or o.customer_id = p_customer_id)
    and (p_from_date is null or o.created_at::date >= p_from_date)
    and (p_to_date is null or o.created_at::date <= p_to_date);
  return v_orders;
end;
$$;

create or replace function public.transition_sales_order(p_sales_order_id uuid, p_next_status text)
returns jsonb
language plpgsql
security definer
set search_path = public, private, pg_catalog
as $$
declare
  v_user uuid := auth.uid();
  v_organization_id uuid;
  v_order public.sales_orders%rowtype;
  v_next_status text := nullif(trim(p_next_status), '');
begin
  if v_user is null then raise exception 'AUTH_REQUIRED'; end if;
  if not private.current_user_has_permission('ventas.write') then
    raise exception 'PERMISSION_DENIED: ventas.write';
  end if;
  select p.organization_id into v_organization_id
  from public.profiles p where p.id = v_user;
  if v_organization_id is null then raise exception 'ORGANIZATION_REQUIRED'; end if;
  if v_next_status not in ('EN PREPARACIÓN', 'LISTO PARA DESPACHO', 'CERRADO') then
    raise exception 'VALIDATION: requested transition is not allowed';
  end if;

  select * into v_order
  from public.sales_orders o
  where o.id = p_sales_order_id and o.organization_id = v_organization_id
  for update;
  if not found then raise exception 'VALIDATION: sales order not found'; end if;
  if v_order.status = 'CERRADO' then raise exception 'VALIDATION: closed sales order is immutable'; end if;

  if v_order.status = 'PEDIDO REGISTRADO' and v_next_status = 'EN PREPARACIÓN' then
    update public.sales_orders set
      status = v_next_status, preparation_started_by = v_user, preparation_started_at = now()
    where id = v_order.id returning * into v_order;
  elsif v_order.status = 'DESPACHADO' and v_next_status = 'CERRADO' then
    update public.sales_orders set status = v_next_status, closed_by = v_user, closed_at = now()
    where id = v_order.id returning * into v_order;
  else
    raise exception 'VALIDATION: invalid sales order state transition';
  end if;

  return jsonb_build_object(
    'id', v_order.id, 'order_number', v_order.order_number,
    'status', v_order.status,
    'preparation_started_by', v_order.preparation_started_by,
    'preparation_started_at', v_order.preparation_started_at,
    'closed_by', v_order.closed_by, 'closed_at', v_order.closed_at,
    'updated_at', v_order.updated_at
  );
end;
$$;

create or replace function public.get_sales_preparation_options(p_sales_order_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, private, pg_catalog
as $$
declare
  v_user uuid := auth.uid();
  v_organization_id uuid;
  v_order public.sales_orders%rowtype;
  v_options jsonb;
begin
  if v_user is null then raise exception 'AUTH_REQUIRED'; end if;
  if not private.current_user_has_permission('ventas.read') then
    raise exception 'PERMISSION_DENIED: ventas.read';
  end if;
  select p.organization_id into v_organization_id
  from public.profiles p where p.id = v_user;
  if v_organization_id is null then raise exception 'ORGANIZATION_REQUIRED'; end if;
  select * into v_order from public.sales_orders o
  where o.id = p_sales_order_id and o.organization_id = v_organization_id;
  if not found then raise exception 'VALIDATION: sales order not found'; end if;
  if v_order.status <> 'EN PREPARACIÓN' then
    raise exception 'VALIDATION: sales order must be in preparation';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'product_id', fp.id,
    'product_code', fp.product_code,
    'product_type', fp.product_type
  ) order by fp.entered_at desc, fp.product_code), '[]'::jsonb)
  into v_options
  from public.finished_products fp
  where fp.organization_id = v_organization_id
    and fp.product_type in ('COD', 'ISOL')
    and exists (
      select 1
      from public.finished_product_movements m
      where m.finished_product_id = fp.id
      group by m.finished_product_id
      having coalesce(sum(case when m.movement_type = 'ENTRADA'
        then m.quantity_kg else -m.quantity_kg end), 0) > 0
    );
  return v_options;
end;
$$;

create or replace function public.complete_sales_preparation(
  p_sales_order_id uuid,
  p_prepared_product_id uuid,
  p_prepared_quantity numeric
)
returns jsonb
language plpgsql
security definer
set search_path = public, private, pg_catalog
as $$
declare
  v_user uuid := auth.uid();
  v_organization_id uuid;
  v_order public.sales_orders%rowtype;
  v_product public.finished_products%rowtype;
  v_excess_quantity numeric;
  v_prepared_quantity_kg numeric;
  v_available_quantity_kg numeric;
begin
  if v_user is null then raise exception 'AUTH_REQUIRED'; end if;
  if not private.current_user_has_permission('ventas.write') then
    raise exception 'PERMISSION_DENIED: ventas.write';
  end if;
  select p.organization_id into v_organization_id
  from public.profiles p where p.id = v_user;
  if v_organization_id is null then raise exception 'ORGANIZATION_REQUIRED'; end if;

  select * into v_order
  from public.sales_orders o
  where o.id = p_sales_order_id and o.organization_id = v_organization_id
  for update;
  if not found then raise exception 'VALIDATION: sales order not found'; end if;
  if v_order.status = 'LISTO PARA DESPACHO'
     and v_order.prepared_product_id = p_prepared_product_id
     and v_order.prepared_quantity = p_prepared_quantity then
    return jsonb_build_object(
      'id', v_order.id, 'order_number', v_order.order_number,
      'status', v_order.status, 'prepared_product_id', v_order.prepared_product_id,
      'prepared_quantity', v_order.prepared_quantity,
      'excess_quantity', v_order.excess_quantity,
      'ready_by', v_order.ready_by, 'ready_at', v_order.ready_at, 'replayed', true
    );
  end if;
  if v_order.status <> 'EN PREPARACIÓN' then
    raise exception 'VALIDATION: sales order must be in preparation';
  end if;
  if p_prepared_product_id is null then
    raise exception 'VALIDATION: prepared product is required';
  end if;
  if p_prepared_quantity is null or p_prepared_quantity <= 0 then
    raise exception 'VALIDATION: prepared quantity must be > 0';
  end if;
  if p_prepared_quantity < v_order.quantity then
    raise exception 'VALIDATION: prepared quantity cannot be less than the sales order quantity';
  end if;

  select * into v_product
  from public.finished_products fp
  where fp.id = p_prepared_product_id
    and fp.organization_id = v_organization_id
    and fp.product_type in ('COD', 'ISOL')
    and exists (
      select 1
      from public.finished_product_movements m
      where m.finished_product_id = fp.id
      group by m.finished_product_id
      having coalesce(sum(case when m.movement_type = 'ENTRADA'
        then m.quantity_kg else -m.quantity_kg end), 0) > 0
    );
  if not found then raise exception 'VALIDATION: prepared product not found'; end if;

  v_prepared_quantity_kg := case
    when v_order.unit = 'g' then p_prepared_quantity / 1000
    else p_prepared_quantity
  end;
  select coalesce(sum(case when m.movement_type = 'ENTRADA'
    then m.quantity_kg else -m.quantity_kg end), 0)
  into v_available_quantity_kg
  from public.finished_product_movements m
  where m.finished_product_id = v_product.id;
  if v_prepared_quantity_kg > v_available_quantity_kg then
    raise exception 'VALIDATION: prepared quantity exceeds available product inventory';
  end if;

  v_excess_quantity := p_prepared_quantity - v_order.quantity;
  update public.sales_orders set
    status = 'LISTO PARA DESPACHO',
    prepared_product_id = v_product.id,
    prepared_quantity = p_prepared_quantity,
    excess_quantity = v_excess_quantity,
    ready_by = v_user,
    ready_at = now()
  where id = v_order.id returning * into v_order;

  return jsonb_build_object(
    'id', v_order.id, 'order_number', v_order.order_number,
    'status', v_order.status, 'prepared_product_id', v_order.prepared_product_id,
    'prepared_product_code', v_product.product_code,
    'prepared_quantity', v_order.prepared_quantity,
    'excess_quantity', v_order.excess_quantity,
    'ready_by', v_order.ready_by, 'ready_at', v_order.ready_at, 'replayed', false
  );
end;
$$;

create or replace function public.get_sales_dispatch_options(p_sales_order_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, private, pg_catalog
as $$
declare
  v_user uuid := auth.uid();
  v_organization_id uuid;
  v_order public.sales_orders%rowtype;
  v_options jsonb;
  v_required_kg numeric;
begin
  if v_user is null then raise exception 'AUTH_REQUIRED'; end if;
  if not private.current_user_has_permission('ventas.read') then
    raise exception 'PERMISSION_DENIED: ventas.read';
  end if;
  select p.organization_id into v_organization_id
  from public.profiles p where p.id = v_user;
  if v_organization_id is null then raise exception 'ORGANIZATION_REQUIRED'; end if;
  select * into v_order from public.sales_orders o
  where o.id = p_sales_order_id and o.organization_id = v_organization_id;
  if not found then raise exception 'VALIDATION: sales order not found'; end if;
  if v_order.status <> 'LISTO PARA DESPACHO' then
    raise exception 'VALIDATION: sales order must be ready for dispatch';
  end if;
  v_required_kg := case when v_order.unit = 'g' then v_order.quantity / 1000 else v_order.quantity end;

  select coalesce(jsonb_agg(jsonb_build_object(
    'operation_id', op.id,
    'product_id', fp.id,
    'product_code', fp.product_code,
    'product_type', fp.product_type,
    'quantity_kg', m.quantity_kg,
    'reference', op.reference,
    'created_at', op.created_at,
    'inventory_movement_id', m.id
  ) order by op.created_at desc), '[]'::jsonb)
  into v_options
  from public.product_isol_operations op
  join public.finished_product_movements m
    on m.reference_type = 'PRODUCT_ISOL_DESPACHO'
   and m.reference_id = op.id
   and m.finished_product_id = op.finished_product_id
   and m.movement_type = 'SALIDA'
  join public.finished_products fp
    on fp.id = op.finished_product_id and fp.organization_id = v_organization_id
  where op.organization_id = v_organization_id
    and op.operation_type = 'DESPACHO'
    and op.finished_product_id = v_order.prepared_product_id
    and op.quantity_kg = v_required_kg
    and not exists (
      select 1 from public.sales_orders linked
      where linked.dispatch_operation_id = op.id
    );
  return v_options;
end;
$$;

create or replace function public.register_sales_dispatch(
  p_sales_order_id uuid,
  p_product_isol_operation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public, private, pg_catalog
as $$
declare
  v_user uuid := auth.uid();
  v_organization_id uuid;
  v_order public.sales_orders%rowtype;
  v_operation public.product_isol_operations%rowtype;
  v_product public.finished_products%rowtype;
  v_movement public.finished_product_movements%rowtype;
  v_required_kg numeric;
begin
  if v_user is null then raise exception 'AUTH_REQUIRED'; end if;
  if not private.current_user_has_permission('ventas.write') then
    raise exception 'PERMISSION_DENIED: ventas.write';
  end if;
  select p.organization_id into v_organization_id
  from public.profiles p where p.id = v_user;
  if v_organization_id is null then raise exception 'ORGANIZATION_REQUIRED'; end if;

  select * into v_order
  from public.sales_orders o
  where o.id = p_sales_order_id and o.organization_id = v_organization_id
  for update;
  if not found then raise exception 'VALIDATION: sales order not found'; end if;
  if v_order.status <> 'LISTO PARA DESPACHO' then
    raise exception 'VALIDATION: sales order must be ready for dispatch';
  end if;
  select * into v_operation
  from public.product_isol_operations op
  where op.id = p_product_isol_operation_id
    and op.organization_id = v_organization_id
    and op.operation_type = 'DESPACHO';
  if not found then raise exception 'VALIDATION: matching Product / ISOL dispatch not found'; end if;
  if v_operation.finished_product_id <> v_order.prepared_product_id then
    raise exception 'VALIDATION: dispatched product must match the prepared product';
  end if;

  select * into v_product
  from public.finished_products fp
  where fp.id = v_operation.finished_product_id and fp.organization_id = v_organization_id;
  if not found then raise exception 'VALIDATION: dispatched product not found'; end if;

  select * into v_movement
  from public.finished_product_movements m
  where m.organization_id = v_organization_id
    and m.finished_product_id = v_product.id
    and m.reference_type = 'PRODUCT_ISOL_DESPACHO'
    and m.reference_id = v_operation.id
    and m.movement_type = 'SALIDA';
  if not found then raise exception 'VALIDATION: inventory dispatch movement not found'; end if;

  v_required_kg := case when v_order.unit = 'g' then v_order.quantity / 1000 else v_order.quantity end;
  if v_operation.quantity_kg <> v_required_kg or v_movement.quantity_kg <> v_required_kg then
    raise exception 'VALIDATION: dispatch must fulfill the complete sales order quantity';
  end if;
  if exists (
    select 1 from public.sales_orders linked
    where linked.dispatch_operation_id = v_operation.id and linked.id <> v_order.id
  ) then
    raise exception 'VALIDATION: dispatch is already linked to another sales order';
  end if;

  update public.sales_orders set
    status = 'DESPACHADO',
    dispatch_operation_id = v_operation.id,
    finished_product_id = v_product.id,
    inventory_movement_id = v_movement.id,
    dispatched_by = v_user,
    dispatched_at = now()
  where id = v_order.id returning * into v_order;

  return jsonb_build_object(
    'id', v_order.id, 'order_number', v_order.order_number,
    'status', v_order.status, 'dispatch_operation_id', v_operation.id,
    'finished_product_id', v_product.id, 'product_code', v_product.product_code,
    'inventory_movement_id', v_movement.id, 'quantity_kg', v_movement.quantity_kg,
    'dispatched_by', v_order.dispatched_by, 'dispatched_at', v_order.dispatched_at
  );
end;
$$;

revoke all on function public.create_sales_customer(jsonb) from public, anon, authenticated;
revoke all on function public.get_sales_customers() from public, anon, authenticated;
revoke all on function public.create_sales_order(jsonb) from public, anon, authenticated;
revoke all on function public.get_sales_orders(text, uuid, date, date) from public, anon, authenticated;
revoke all on function public.transition_sales_order(uuid, text) from public, anon, authenticated;
revoke all on function public.get_sales_preparation_options(uuid) from public, anon, authenticated;
revoke all on function public.complete_sales_preparation(uuid, uuid, numeric) from public, anon, authenticated;
revoke all on function public.get_sales_dispatch_options(uuid) from public, anon, authenticated;
revoke all on function public.register_sales_dispatch(uuid, uuid) from public, anon, authenticated;
grant execute on function public.create_sales_customer(jsonb) to authenticated;
grant execute on function public.get_sales_customers() to authenticated;
grant execute on function public.create_sales_order(jsonb) to authenticated;
grant execute on function public.get_sales_orders(text, uuid, date, date) to authenticated;
grant execute on function public.transition_sales_order(uuid, text) to authenticated;
grant execute on function public.get_sales_preparation_options(uuid) to authenticated;
grant execute on function public.complete_sales_preparation(uuid, uuid, numeric) to authenticated;
grant execute on function public.get_sales_dispatch_options(uuid) to authenticated;
grant execute on function public.register_sales_dispatch(uuid, uuid) to authenticated;

insert into public.schema_migrations
  (migration_code, migration_name, executed_by, notes)
select
  'MPCF-036',
  'SALES_V1',
  auth.uid(),
  'MOD-011 Ventas V1: clientes, pedidos comerciales, estados e integracion con despacho Producto / ISOL.'
where not exists (
  select 1 from public.schema_migrations where migration_code = 'MPCF-036'
);

select 'MPCF-036 SALES V1 PREPARED - NOT EXECUTED' as status;
