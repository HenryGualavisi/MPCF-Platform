-- ============================================================
-- MPCF-035 - PRODUCT / ISOL V1
-- TRAZIX HG / MPCF Platform
--
-- Estado: PREPARADO (SQL versionado). Ejecucion NO CONFIRMADA.
-- Requiere MPCF-033 (MOD-007 Finished Product Inventory).
--
-- Producto / ISOL usa finished_products y finished_product_movements
-- como unica fuente de existencias. Despacho y consolidacion se
-- ejecutan mediante RPCs SECURITY DEFINER y operaciones atomicas.
-- Las referencias COD de una consolidacion quedan registradas aqui;
-- no se crea una genealogia paralela.
-- El codigo operacional ISOL es ISOL DDDYY (dia juliano + año de creacion).
-- Se permite un ISOL por organizacion y dia; el UUID solo es identidad tecnica.
-- No crea ventas, permisos ni escrituras directas desde el frontend.
-- ============================================================

create table public.product_isol_operations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  operation_type text not null,
  request_id uuid not null,
  request_payload jsonb not null,
  finished_product_id uuid not null references public.finished_products(id),
  quantity_kg numeric not null,
  reference text not null,
  observations text,
  created_by uuid not null,
  created_at timestamptz not null default now(),
  constraint product_isol_operations_type_check
    check (operation_type in ('DESPACHO', 'CONSOLIDACION')),
  constraint product_isol_operations_quantity_check check (quantity_kg > 0),
  constraint product_isol_operations_reference_check check (length(trim(reference)) > 0),
  constraint product_isol_operations_request_uidx unique (organization_id, request_id),
  constraint product_isol_operations_id_org_uidx unique (id, organization_id)
);

create index product_isol_operations_product_idx
  on public.product_isol_operations(organization_id, finished_product_id, created_at desc);

create table public.product_isol_consolidation_inputs (
  id uuid primary key default gen_random_uuid(),
  operation_id uuid not null,
  organization_id uuid not null,
  finished_product_id uuid not null references public.finished_products(id),
  quantity_kg numeric not null,
  created_at timestamptz not null default now(),
  constraint product_isol_consolidation_inputs_quantity_check check (quantity_kg > 0),
  constraint product_isol_consolidation_inputs_operation_product_uidx
    unique (operation_id, finished_product_id),
  constraint product_isol_consolidation_inputs_operation_org_fk
    foreign key (operation_id, organization_id)
    references public.product_isol_operations(id, organization_id)
);

create index product_isol_consolidation_inputs_product_idx
  on public.product_isol_consolidation_inputs(organization_id, finished_product_id);

create unique index finished_products_isol_code_uidx
  on public.finished_products(organization_id, product_code)
  where product_type = 'ISOL';

create unique index finished_product_movements_product_isol_operation_uidx
  on public.finished_product_movements(finished_product_id, reference_type, reference_id)
  where reference_type in ('PRODUCT_ISOL_DESPACHO', 'PRODUCT_ISOL_CONSOLIDACION');

drop trigger if exists product_isol_operations_append_only on public.product_isol_operations;
create trigger product_isol_operations_append_only
before update or delete on public.product_isol_operations
for each row execute function private.guard_finished_product_ledger();

drop trigger if exists product_isol_consolidation_inputs_append_only on public.product_isol_consolidation_inputs;
create trigger product_isol_consolidation_inputs_append_only
before update or delete on public.product_isol_consolidation_inputs
for each row execute function private.guard_finished_product_ledger();

alter table public.product_isol_operations enable row level security;
alter table public.product_isol_consolidation_inputs enable row level security;

revoke all on public.product_isol_operations from public, anon, authenticated;
revoke all on public.product_isol_consolidation_inputs from public, anon, authenticated;

create or replace function public.dispatch_finished_product(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, private, pg_catalog
as $$
declare
  v_user uuid := auth.uid();
  v_organization_id uuid;
  v_request_id uuid;
  v_product_id uuid;
  v_quantity numeric;
  v_reference text;
  v_observations text;
  v_product_code text;
  v_balance numeric;
  v_operation public.product_isol_operations%rowtype;
begin
  if v_user is null then raise exception 'AUTH_REQUIRED'; end if;
  if not private.current_user_has_permission('produccion.write') then
    raise exception 'PERMISSION_DENIED: produccion.write';
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
  if coalesce(p_payload->>'finished_product_id', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    raise exception 'VALIDATION: finished_product_id must be a UUID';
  end if;
  if jsonb_typeof(p_payload->'quantity_kg') is distinct from 'number' then
    raise exception 'VALIDATION: quantity_kg must be numeric';
  end if;
  if jsonb_typeof(p_payload->'reference') is distinct from 'string' then
    raise exception 'VALIDATION: dispatch reference must be text';
  end if;
  if p_payload ? 'observations'
     and jsonb_typeof(p_payload->'observations') not in ('string', 'null') then
    raise exception 'VALIDATION: observations must be text or null';
  end if;

  v_request_id := (p_payload->>'request_id')::uuid;
  v_product_id := (p_payload->>'finished_product_id')::uuid;
  v_quantity := (p_payload->>'quantity_kg')::numeric;
  v_reference := nullif(trim(p_payload->>'reference'), '');
  v_observations := nullif(trim(p_payload->>'observations'), '');
  if v_quantity <= 0 then raise exception 'VALIDATION: quantity_kg must be > 0'; end if;
  if v_reference is null then raise exception 'VALIDATION: dispatch reference is required'; end if;

  perform pg_advisory_xact_lock(hashtextextended(v_organization_id::text || ':' || v_request_id::text, 0));
  select * into v_operation
  from public.product_isol_operations
  where organization_id = v_organization_id and request_id = v_request_id;
  if found then
    if v_operation.operation_type <> 'DESPACHO' or v_operation.request_payload <> p_payload then
      raise exception 'IDEMPOTENCY_CONFLICT: request_id was already used with different input';
    end if;
    select fp.product_code into v_product_code
    from public.finished_products fp
    where fp.id = v_operation.finished_product_id and fp.organization_id = v_organization_id;
    select coalesce(sum(case when m.movement_type = 'ENTRADA' then m.quantity_kg else -m.quantity_kg end), 0)
      into v_balance
    from public.finished_product_movements m
    where m.finished_product_id = v_operation.finished_product_id;
    return jsonb_build_object(
      'operation_id', v_operation.id, 'product_id', v_operation.finished_product_id,
      'product_code', v_product_code, 'quantity_kg', v_operation.quantity_kg,
      'balance_kg', v_balance, 'created_at', v_operation.created_at, 'replayed', true
    );
  end if;

  select fp.product_code into v_product_code
  from public.finished_products fp
  where fp.id = v_product_id and fp.organization_id = v_organization_id
  for update;
  if not found then raise exception 'VALIDATION: finished product not found'; end if;

  select coalesce(sum(case when m.movement_type = 'ENTRADA' then m.quantity_kg else -m.quantity_kg end), 0)
    into v_balance
  from public.finished_product_movements m
  where m.finished_product_id = v_product_id;
  if v_quantity > v_balance then raise exception 'VALIDATION: quantity exceeds finished product balance'; end if;

  insert into public.product_isol_operations(
    organization_id, operation_type, request_id, request_payload,
    finished_product_id, quantity_kg, reference, observations, created_by
  ) values (
    v_organization_id, 'DESPACHO', v_request_id, p_payload,
    v_product_id, v_quantity, v_reference, v_observations, v_user
  ) returning * into v_operation;

  insert into public.finished_product_movements(
    organization_id, finished_product_id, movement_type, quantity_kg, unit,
    reference_type, reference_id, created_by, observations
  ) values (
    v_organization_id, v_product_id, 'SALIDA', v_quantity, 'kg',
    'PRODUCT_ISOL_DESPACHO', v_operation.id, v_user, v_observations
  );

  return jsonb_build_object(
    'operation_id', v_operation.id, 'product_id', v_product_id,
    'product_code', v_product_code, 'quantity_kg', v_quantity,
    'balance_kg', v_balance - v_quantity, 'created_at', v_operation.created_at, 'replayed', false
  );
end;
$$;

create or replace function public.consolidate_finished_products(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, private, pg_catalog
as $$
declare
  v_user uuid := auth.uid();
  v_organization_id uuid;
  v_request_id uuid;
  v_reference text;
  v_observations text;
  v_input jsonb;
  v_source_id uuid;
  v_source_code text;
  v_source_balance numeric;
  v_source_quantity numeric;
  v_total numeric := 0;
  v_new_product_id uuid;
  v_new_product_code text;
  v_created_at timestamptz;
  v_operation public.product_isol_operations%rowtype;
begin
  if v_user is null then raise exception 'AUTH_REQUIRED'; end if;
  if not private.current_user_has_permission('produccion.write') then
    raise exception 'PERMISSION_DENIED: produccion.write';
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
  if jsonb_typeof(p_payload->'inputs') is distinct from 'array' then
    raise exception 'VALIDATION: consolidation inputs must be an array';
  end if;
  if jsonb_typeof(p_payload->'reference') is distinct from 'string' then
    raise exception 'VALIDATION: consolidation reference must be text';
  end if;
  if p_payload ? 'observations'
     and jsonb_typeof(p_payload->'observations') not in ('string', 'null') then
    raise exception 'VALIDATION: observations must be text or null';
  end if;
  if jsonb_array_length(p_payload->'inputs') = 0 then
    raise exception 'VALIDATION: consolidation requires at least one COD input';
  end if;
  if exists (
    select 1 from jsonb_array_elements(p_payload->'inputs') i
    where jsonb_typeof(i) <> 'object'
       or coalesce(i->>'finished_product_id', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
       or jsonb_typeof(i->'quantity_kg') is distinct from 'number'
  ) then
    raise exception 'VALIDATION: each input requires a product UUID and numeric quantity_kg';
  end if;
  if (select count(*) from jsonb_array_elements(p_payload->'inputs')) <>
     (select count(distinct (i->>'finished_product_id')::uuid) from jsonb_array_elements(p_payload->'inputs') i) then
    raise exception 'VALIDATION: a COD may appear only once';
  end if;
  if exists (
    select 1 from jsonb_array_elements(p_payload->'inputs') i
    where (i->>'quantity_kg')::numeric <= 0
  ) then
    raise exception 'VALIDATION: every COD quantity must be > 0';
  end if;
  v_request_id := (p_payload->>'request_id')::uuid;
  v_reference := nullif(trim(p_payload->>'reference'), '');
  v_observations := nullif(trim(p_payload->>'observations'), '');
  if v_reference is null then raise exception 'VALIDATION: consolidation reference is required'; end if;

  perform pg_advisory_xact_lock(hashtextextended(v_organization_id::text || ':' || v_request_id::text, 0));
  select * into v_operation
  from public.product_isol_operations
  where organization_id = v_organization_id and request_id = v_request_id;
  if found then
    if v_operation.operation_type <> 'CONSOLIDACION' or v_operation.request_payload <> p_payload then
      raise exception 'IDEMPOTENCY_CONFLICT: request_id was already used with different input';
    end if;
    select fp.product_code into v_new_product_code
    from public.finished_products fp
    where fp.id = v_operation.finished_product_id and fp.organization_id = v_organization_id;
    return jsonb_build_object(
      'operation_id', v_operation.id, 'product_id', v_operation.finished_product_id,
      'product_code', v_new_product_code, 'quantity_kg', v_operation.quantity_kg,
      'created_at', v_operation.created_at, 'replayed', true
    );
  end if;

  -- Lock all source rows in a stable order to serialize competing operations safely.
  for v_input in
    select value from jsonb_array_elements(p_payload->'inputs')
    order by (value->>'finished_product_id')::uuid
  loop
    v_source_id := (v_input->>'finished_product_id')::uuid;
    v_source_quantity := (v_input->>'quantity_kg')::numeric;
    select fp.product_code into v_source_code
    from public.finished_products fp
    where fp.id = v_source_id
      and fp.organization_id = v_organization_id
      and fp.product_type = 'COD'
    for update;
    if not found then raise exception 'VALIDATION: COD not found or unavailable'; end if;
    select coalesce(sum(case when m.movement_type = 'ENTRADA' then m.quantity_kg else -m.quantity_kg end), 0)
      into v_source_balance
    from public.finished_product_movements m
    where m.finished_product_id = v_source_id;
    if v_source_balance <= 0 then raise exception 'VALIDATION: COD is not available'; end if;
    if v_source_quantity > v_source_balance then
      raise exception 'VALIDATION: COD quantity exceeds finished product balance';
    end if;
    v_total := v_total + v_source_quantity;
  end loop;

  v_created_at := now();
  v_new_product_code := 'ISOL ' || to_char(v_created_at, 'DDDYY');
  perform pg_advisory_xact_lock(hashtextextended(
    v_organization_id::text || ':ISOL:' || v_created_at::date::text, 0
  ));
  if exists (
    select 1 from public.finished_products fp
    where fp.organization_id = v_organization_id
      and fp.product_type = 'ISOL'
      and fp.product_code = v_new_product_code
  ) then
    raise exception 'DUPLICATE: an ISOL has already been generated for this organization and date';
  end if;

  v_new_product_id := gen_random_uuid();
  insert into public.finished_products(
    id, organization_id, product_type, product_code, product_name, unit, entered_at
  ) values (
    v_new_product_id, v_organization_id, 'ISOL', v_new_product_code,
    v_new_product_code, 'kg', v_created_at
  );

  insert into public.product_isol_operations(
    organization_id, operation_type, request_id, request_payload,
    finished_product_id, quantity_kg, reference, observations, created_by
  ) values (
    v_organization_id, 'CONSOLIDACION', v_request_id, p_payload,
    v_new_product_id, v_total, v_reference, v_observations, v_user
  ) returning * into v_operation;

  for v_input in
    select value from jsonb_array_elements(p_payload->'inputs')
    order by (value->>'finished_product_id')::uuid
  loop
    v_source_id := (v_input->>'finished_product_id')::uuid;
    v_source_quantity := (v_input->>'quantity_kg')::numeric;

    insert into public.product_isol_consolidation_inputs(
      operation_id, organization_id, finished_product_id, quantity_kg
    ) values (
      v_operation.id, v_organization_id, v_source_id, v_source_quantity
    );

    insert into public.finished_product_movements(
      organization_id, finished_product_id, movement_type, quantity_kg, unit,
      reference_type, reference_id, created_by, observations
    ) values (
      v_organization_id, v_source_id, 'SALIDA', v_source_quantity, 'kg',
      'PRODUCT_ISOL_CONSOLIDACION', v_operation.id, v_user, v_observations
    );
  end loop;

  insert into public.finished_product_movements(
    organization_id, finished_product_id, movement_type, quantity_kg, unit,
    reference_type, reference_id, created_by, observations
  ) values (
    v_organization_id, v_new_product_id, 'ENTRADA', v_total, 'kg',
    'PRODUCT_ISOL_CONSOLIDACION', v_operation.id, v_user, v_observations
  );

  return jsonb_build_object(
    'operation_id', v_operation.id, 'product_id', v_new_product_id,
    'product_code', v_new_product_code, 'quantity_kg', v_total,
    'created_at', v_operation.created_at, 'replayed', false
  );
end;
$$;

create or replace function public.get_product_isol_consolidation(p_isol_product_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, private, pg_catalog
as $$
declare
  v_user uuid := auth.uid();
  v_organization_id uuid;
  v_result jsonb;
begin
  if v_user is null then raise exception 'AUTH_REQUIRED'; end if;
  if not private.current_user_has_permission('produccion.read') then
    raise exception 'PERMISSION_DENIED: produccion.read';
  end if;
  select p.organization_id into v_organization_id
  from public.profiles p where p.id = v_user;
  if v_organization_id is null then raise exception 'ORGANIZATION_REQUIRED'; end if;
  if not exists (
    select 1 from public.finished_products fp
    where fp.id = p_isol_product_id and fp.organization_id = v_organization_id
      and fp.product_type = 'ISOL'
  ) then
    raise exception 'VALIDATION: ISOL not found';
  end if;

  select jsonb_build_object(
    'operation_id', op.id,
    'reference', op.reference,
    'observations', op.observations,
    'created_at', op.created_at,
    'created_by', op.created_by,
    'quantity_kg', op.quantity_kg,
    'inputs', coalesce((
      select jsonb_agg(jsonb_build_object(
        'product_id', src.id,
        'product_code', src.product_code,
        'quantity_kg', ci.quantity_kg
      ) order by src.product_code, src.id)
      from public.product_isol_consolidation_inputs ci
      join public.finished_products src on src.id = ci.finished_product_id
      where ci.operation_id = op.id and ci.organization_id = v_organization_id
    ), '[]'::jsonb)
  ) into v_result
  from public.product_isol_operations op
  where op.finished_product_id = p_isol_product_id
    and op.organization_id = v_organization_id
    and op.operation_type = 'CONSOLIDACION';

  if v_result is null then raise exception 'VALIDATION: no consolidation record exists for this ISOL'; end if;
  return v_result;
end;
$$;

revoke all on function public.dispatch_finished_product(jsonb) from public, anon, authenticated;
revoke all on function public.consolidate_finished_products(jsonb) from public, anon, authenticated;
revoke all on function public.get_product_isol_consolidation(uuid) from public, anon, authenticated;
grant execute on function public.dispatch_finished_product(jsonb) to authenticated;
grant execute on function public.consolidate_finished_products(jsonb) to authenticated;
grant execute on function public.get_product_isol_consolidation(uuid) to authenticated;

insert into public.schema_migrations
  (migration_code, migration_name, executed_by, notes)
select
  'MPCF-035',
  'PRODUCT_ISOL_V1',
  auth.uid(),
  'Despacho y consolidacion atomica sobre MOD-007, con origen COD a ISOL e idempotencia.'
where not exists (
  select 1 from public.schema_migrations where migration_code = 'MPCF-035'
);

select 'MPCF-035 PRODUCT / ISOL V1 PREPARED - NOT EXECUTED' as status;
