-- ============================================================
-- MPCF-026 - PRODUCTION V1
-- TRAZIX HG / MPCF Platform
--
-- PROPUESTA NO EJECUTADA.
--
-- Define el contrato fisico compatible con MPCF-025 y el proceso
-- productivo V1. No modifica consume_material_transaction(),
-- material_availability, material_movements, Big Bags ni balances.
--
-- GAPS DE EJECUCION QUE REQUIEREN MATCH FINAL:
-- 1) Confirmar que private.current_user_has_permission('produccion.write')
--    exista en el catalogo vigente de permisos.
-- 2) Confirmar las policies/RLS actuales y la presencia de profiles.
-- 3) Confirmar que no exista ya una version fisica incompatible de estas tablas.
-- 4) No existe en este repositorio un contrato audit_log reutilizable; no se crea.
--
-- MPCF-025 crea material_movements y production_inputs. Esta migracion
-- solamente define las tablas que necesita y no inserta esos registros.
-- ============================================================

create table if not exists public.production_orders (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  cod integer not null,
  production_date date not null,
  shift text,
  production_type text,
  status text not null default 'PROGRAMADA',
  process_version text not null default 'V1',
  source_reference text,
  observations text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  closed_at timestamptz,
  closed_by uuid,
  constraint production_orders_cod_positive check (cod > 0),
  constraint production_orders_status_check check (
    status in ('PROGRAMADA','ABIERTA','EN_PROCESO','FINALIZADA','CERRADA','CANCELADA')
  ),
  constraint production_orders_process_version_check check (process_version = 'V1')
);

create unique index if not exists production_orders_organization_date_cod_uidx
  on public.production_orders(organization_id, production_date, cod);

create table if not exists public.production_inputs (
  id uuid primary key default gen_random_uuid(),
  production_order_id uuid not null,
  material_availability_id uuid not null,
  material_movement_id uuid not null,
  reception_id uuid not null,
  big_bag_id uuid not null,
  agricultural_lot_id uuid,
  harvest_id uuid,
  quantity_kg numeric not null,
  input_datetime timestamptz not null default now(),
  traceability_status text not null,
  evidence_reference text,
  observations text,
  constraint production_inputs_quantity_positive check (quantity_kg > 0),
  constraint production_inputs_traceability_status_check check (
    traceability_status in ('CONFIRMADO','INFERIDO','PENDIENTE','NO EXISTE')
  )
);

create index if not exists production_inputs_order_idx
  on public.production_inputs(production_order_id);
create index if not exists production_inputs_movement_idx
  on public.production_inputs(material_movement_id);
create index if not exists production_inputs_big_bag_idx
  on public.production_inputs(big_bag_id);

create table if not exists public.production_process_events (
  id uuid primary key default gen_random_uuid(),
  production_order_id uuid not null,
  sequence_no integer not null,
  event_type text not null,
  stage_status text not null default 'PENDIENTE',
  started_at timestamptz,
  ended_at timestamptz,
  responsible text,
  observations text,
  evidence_reference text,
  naoh_percent numeric,
  frequency text,
  caudal_l integer,
  recirculacion text,
  filter_configuration text,
  reactor text,
  temperature_initial_c numeric,
  temperature_final_c numeric,
  reactor_volume_l numeric,
  cbd_percent numeric,
  cbda_percent numeric,
  total_cbd_percent numeric generated always as (
    case
      when cbd_percent is null and cbda_percent is null then null
      else coalesce(cbd_percent, 0) + coalesce(cbda_percent, 0) * 0.877
    end
  ) stored,
  wet_weight_kg numeric,
  filter_media text,
  alkaline_wash_count integer,
  alkaline_wash_l numeric,
  acid_wash_count integer,
  acid_wash_l numeric,
  neutral_wash_count integer,
  neutral_wash_l numeric,
  pre_drying boolean,
  vacuum boolean,
  drying_weight_kg numeric,
  drying_color text,
  drying_temperature_c numeric,
  packing_date date,
  packing_quantity_kg numeric,
  packing_cbd_percent numeric,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint production_events_sequence_check check (sequence_no between 1 and 10),
  constraint production_events_type_check check (
    event_type in (
      'EXTRACCION','SEDIMENTACION','FILTRACION','DECARBOXILACION',
      'ENFRIAMIENTO','CRISTALIZACION','COSECHA','LAVADO','SECADO','EMPAQUE'
    )
  ),
  constraint production_events_sequence_type_check check (
    (sequence_no = 1 and event_type = 'EXTRACCION') or
    (sequence_no = 2 and event_type = 'SEDIMENTACION') or
    (sequence_no = 3 and event_type = 'FILTRACION') or
    (sequence_no = 4 and event_type = 'DECARBOXILACION') or
    (sequence_no = 5 and event_type = 'ENFRIAMIENTO') or
    (sequence_no = 6 and event_type = 'CRISTALIZACION') or
    (sequence_no = 7 and event_type = 'COSECHA') or
    (sequence_no = 8 and event_type = 'LAVADO') or
    (sequence_no = 9 and event_type = 'SECADO') or
    (sequence_no = 10 and event_type = 'EMPAQUE')
  ),
  constraint production_events_status_check check (
    stage_status in ('N/A','NO_REGISTRADO','PENDIENTE','ACTIVA','COMPLETADA')
  ),
  constraint production_events_time_check check (
    ended_at is null or started_at is null or ended_at >= started_at
  ),
  constraint production_events_packing_time_check check (
    event_type <> 'EMPAQUE' or (started_at is null and ended_at is null)
  ),
  constraint production_events_packing_data_check check (
    event_type <> 'EMPAQUE' or packing_quantity_kg is not null and packing_quantity_kg > 0
  ),
  constraint production_events_decarb_data_check check (
    event_type <> 'DECARBOXILACION' or
    (cbd_percent is null or cbd_percent >= 0) and
    (cbda_percent is null or cbda_percent >= 0)
  )
);

create unique index if not exists production_events_order_sequence_uidx
  on public.production_process_events(production_order_id, sequence_no);
create index if not exists production_events_order_status_idx
  on public.production_process_events(production_order_id, stage_status);

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
  if v_cod is null or v_cod <= 0 then raise exception 'VALIDATION: cod must be > 0'; end if;
  if v_status <> 'PROGRAMADA' then raise exception 'VALIDATION: new production must be PROGRAMADA'; end if;
  if v_version <> 'V1' then raise exception 'VALIDATION: process_version must be V1'; end if;

  if exists (
    select 1 from public.production_orders
    where organization_id = v_organization_id
      and production_date = v_date
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
    'production_date',v_date,
    'status',v_status,
    'process_version',v_version
  );
end;
$$;

create or replace function public.open_production_order(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, private, pg_catalog
as $$
declare
  v_user uuid := auth.uid();
  v_organization_id uuid;
  v_order_id uuid := nullif(p_payload->>'production_order_id','')::uuid;
  v_previous_status text;
begin
  if v_user is null then raise exception 'AUTH_REQUIRED'; end if;
  if not private.current_user_has_permission('produccion.write') then
    raise exception 'PERMISSION_DENIED: produccion.write';
  end if;

  select p.organization_id into v_organization_id
  from public.profiles p where p.id = v_user;
  if v_organization_id is null then raise exception 'ORGANIZATION_REQUIRED'; end if;
  if v_order_id is null then raise exception 'VALIDATION: production_order_id is required'; end if;

  select status into v_previous_status
  from public.production_orders
  where id = v_order_id and organization_id = v_organization_id
  for update;
  if not found then raise exception 'VALIDATION: production order not found'; end if;
  if v_previous_status <> 'PROGRAMADA' then
    raise exception 'VALIDATION: production order must be PROGRAMADA';
  end if;

  update public.production_orders
  set status = 'ABIERTA', updated_at = now()
  where id = v_order_id and organization_id = v_organization_id;

  return jsonb_build_object(
    'production_order_id', v_order_id,
    'previous_status', v_previous_status,
    'status', 'ABIERTA'
  );
end;
$$;

create or replace function public.start_production_stage(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, private, pg_catalog
as $$
declare
  v_user uuid := auth.uid();
  v_organization_id uuid;
  v_order_id uuid := nullif(p_payload->>'production_order_id','')::uuid;
  v_event_type text := upper(nullif(trim(p_payload->>'event_type'),''));
  v_sequence integer;
  v_status text;
  v_started timestamptz := coalesce(nullif(p_payload->>'started_at','')::timestamptz, now());
  v_event_id uuid;
  v_previous_completed boolean;
begin
  if v_user is null then raise exception 'AUTH_REQUIRED'; end if;
  if not private.current_user_has_permission('produccion.write') then
    raise exception 'PERMISSION_DENIED: produccion.write';
  end if;
  select p.organization_id into v_organization_id from public.profiles p where p.id = v_user;
  if v_organization_id is null then raise exception 'ORGANIZATION_REQUIRED'; end if;
  if v_order_id is null then raise exception 'VALIDATION: production_order_id is required'; end if;

  select sequence_no into v_sequence from (values
    ('EXTRACCION',1),('SEDIMENTACION',2),('FILTRACION',3),('DECARBOXILACION',4),
    ('ENFRIAMIENTO',5),('CRISTALIZACION',6),('COSECHA',7),('LAVADO',8),
    ('SECADO',9),('EMPAQUE',10)
  ) stages(event_type,sequence_no) where event_type = v_event_type;
  if v_sequence is null then raise exception 'VALIDATION: invalid event_type'; end if;

  select status into v_status from public.production_orders
  where id = v_order_id and organization_id = v_organization_id for update;
  if not found then raise exception 'VALIDATION: production order not found'; end if;
  if v_status not in ('ABIERTA','EN_PROCESO') then raise exception 'VALIDATION: production is not open'; end if;
  if exists(select 1 from public.production_process_events where production_order_id=v_order_id and sequence_no=v_sequence) then
    raise exception 'DUPLICATE: production stage already exists';
  end if;

  if v_sequence > 1 then
    select exists(
      select 1 from public.production_process_events
      where production_order_id = v_order_id
        and sequence_no = v_sequence - 1
        and stage_status in ('ACTIVA','COMPLETADA')
    ) into v_previous_completed;
    if not v_previous_completed then raise exception 'VALIDATION: previous stage is required'; end if;
  end if;

  if v_event_type = 'DECARBOXILACION' then
    if not exists(select 1 from public.production_process_events where production_order_id=v_order_id and sequence_no=3) then
      raise exception 'VALIDATION: FILTRACION must be started before DESCARBOXILACION';
    end if;
  end if;

  if v_event_type = 'EMPAQUE' then
    raise exception 'VALIDATION: use register_packing for EMPAQUE';
  end if;

  insert into public.production_process_events(
    production_order_id,sequence_no,event_type,stage_status,started_at,
    responsible,observations,evidence_reference,naoh_percent,frequency,caudal_l,
    recirculacion,filter_configuration,reactor,temperature_initial_c,
    temperature_final_c,reactor_volume_l,cbd_percent,cbda_percent,wet_weight_kg,
    filter_media,alkaline_wash_count,alkaline_wash_l,acid_wash_count,acid_wash_l,
    neutral_wash_count,neutral_wash_l,pre_drying,vacuum,drying_weight_kg,
    drying_color,drying_temperature_c
  ) values (
    v_order_id,v_sequence,v_event_type,'ACTIVA',v_started,
    nullif(trim(p_payload->>'responsible'),''),
    nullif(trim(p_payload->>'observations'),''),
    nullif(trim(p_payload->>'evidence_reference'),''),
    case when v_event_type='EXTRACCION' then nullif(p_payload->>'naoh_percent','')::numeric end,
    case when v_event_type='EXTRACCION' then nullif(trim(p_payload->>'frequency'),'') end,
    case when v_event_type='EXTRACCION' then nullif(p_payload->>'caudal_l','')::integer end,
    case when v_event_type='EXTRACCION' then nullif(upper(trim(p_payload->>'recirculacion')),'') end,
    case when v_event_type='FILTRACION' then nullif(trim(p_payload->>'filter_configuration'),'') end,
    case when v_event_type='DECARBOXILACION' then nullif(trim(p_payload->>'reactor'),'') end,
    case when v_event_type in ('DECARBOXILACION','ENFRIAMIENTO','CRISTALIZACION') then nullif(p_payload->>'temperature_initial_c','')::numeric end,
    case when v_event_type in ('DECARBOXILACION','ENFRIAMIENTO','CRISTALIZACION') then nullif(p_payload->>'temperature_final_c','')::numeric end,
    case when v_event_type in ('DECARBOXILACION','CRISTALIZACION') then nullif(p_payload->>'reactor_volume_l','')::numeric end,
    case when v_event_type='DECARBOXILACION' then nullif(p_payload->>'cbd_percent','')::numeric end,
    case when v_event_type='DECARBOXILACION' then nullif(p_payload->>'cbda_percent','')::numeric end,
    case when v_event_type in ('COSECHA','LAVADO') then nullif(p_payload->>'wet_weight_kg','')::numeric end,
    case when v_event_type='COSECHA' then nullif(trim(p_payload->>'filter_media'),'') end,
    case when v_event_type='LAVADO' then nullif(p_payload->>'alkaline_wash_count','')::integer end,
    case when v_event_type='LAVADO' then nullif(p_payload->>'alkaline_wash_l','')::numeric end,
    case when v_event_type='LAVADO' then nullif(p_payload->>'acid_wash_count','')::integer end,
    case when v_event_type='LAVADO' then nullif(p_payload->>'acid_wash_l','')::numeric end,
    case when v_event_type='LAVADO' then nullif(p_payload->>'neutral_wash_count','')::integer end,
    case when v_event_type='LAVADO' then nullif(p_payload->>'neutral_wash_l','')::numeric end,
    case when v_event_type='SECADO' then nullif(p_payload->>'pre_drying','')::boolean end,
    case when v_event_type='SECADO' then nullif(p_payload->>'vacuum','')::boolean end,
    case when v_event_type='SECADO' then nullif(p_payload->>'drying_weight_kg','')::numeric end,
    case when v_event_type='SECADO' then nullif(trim(p_payload->>'drying_color'),'') end,
    case when v_event_type='SECADO' then nullif(p_payload->>'drying_temperature_c','')::numeric end
  ) returning id into v_event_id;

  update public.production_orders set status='EN_PROCESO', updated_at=now() where id=v_order_id;
  return jsonb_build_object('event_id',v_event_id,'production_order_id',v_order_id,'sequence_no',v_sequence,'stage_status','ACTIVA');
end;
$$;

create or replace function public.finish_production_stage(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, private, pg_catalog
as $$
declare
  v_user uuid := auth.uid();
  v_organization_id uuid;
  v_order_id uuid := nullif(p_payload->>'production_order_id','')::uuid;
  v_sequence integer := nullif(p_payload->>'sequence_no','')::integer;
  v_ended timestamptz := coalesce(nullif(p_payload->>'ended_at','')::timestamptz, now());
  v_started timestamptz;
  v_status text;
begin
  if v_user is null then raise exception 'AUTH_REQUIRED'; end if;
  if not private.current_user_has_permission('produccion.write') then
    raise exception 'PERMISSION_DENIED: produccion.write';
  end if;
  select p.organization_id into v_organization_id from public.profiles p where p.id=v_user;
  if v_organization_id is null then raise exception 'ORGANIZATION_REQUIRED'; end if;

  select e.started_at, e.stage_status into v_started, v_status
  from public.production_process_events e
  join public.production_orders po on po.id=e.production_order_id
  where e.production_order_id=v_order_id and e.sequence_no=v_sequence
    and po.organization_id=v_organization_id
  for update;
  if not found then raise exception 'VALIDATION: production stage not found'; end if;
  if v_status <> 'ACTIVA' then raise exception 'VALIDATION: stage is not active'; end if;
  if v_started is not null and v_ended < v_started then raise exception 'VALIDATION: ended_at cannot precede started_at'; end if;

  update public.production_process_events set
    stage_status='COMPLETADA', ended_at=v_ended,
    responsible=coalesce(nullif(trim(p_payload->>'responsible'),''),responsible),
    observations=coalesce(nullif(trim(p_payload->>'observations'),''),observations),
    evidence_reference=coalesce(nullif(trim(p_payload->>'evidence_reference'),''),evidence_reference),
    updated_at=now()
  where production_order_id=v_order_id and sequence_no=v_sequence;

  return jsonb_build_object('production_order_id',v_order_id,'sequence_no',v_sequence,'stage_status','COMPLETADA','ended_at',v_ended);
end;
$$;

create or replace function public.register_packing(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, private, pg_catalog
as $$
declare
  v_user uuid := auth.uid();
  v_organization_id uuid;
  v_order_id uuid := nullif(p_payload->>'production_order_id','')::uuid;
  v_event_id uuid;
  v_status text;
begin
  if v_user is null then raise exception 'AUTH_REQUIRED'; end if;
  if not private.current_user_has_permission('produccion.write') then
    raise exception 'PERMISSION_DENIED: produccion.write';
  end if;
  select p.organization_id into v_organization_id from public.profiles p where p.id=v_user;
  if v_organization_id is null then raise exception 'ORGANIZATION_REQUIRED'; end if;
  if nullif(p_payload->>'packing_date','')::date is null then raise exception 'VALIDATION: packing_date is required'; end if;
  if nullif(p_payload->>'packing_quantity_kg','')::numeric is null or nullif(p_payload->>'packing_quantity_kg','')::numeric <= 0 then raise exception 'VALIDATION: packing_quantity_kg must be > 0'; end if;

  select status into v_status from public.production_orders where id=v_order_id and organization_id=v_organization_id for update;
  if not found then raise exception 'VALIDATION: production order not found'; end if;
  if v_status <> 'EN_PROCESO' then raise exception 'VALIDATION: production must be EN_PROCESO'; end if;
  if exists(select 1 from public.production_process_events where production_order_id=v_order_id and sequence_no=10) then raise exception 'DUPLICATE: EMPAQUE already exists'; end if;
  if not exists(select 1 from public.production_process_events where production_order_id=v_order_id and sequence_no=9 and stage_status='COMPLETADA') then raise exception 'VALIDATION: SECADO must be completed before EMPAQUE'; end if;

  insert into public.production_process_events(
    production_order_id,sequence_no,event_type,stage_status,packing_date,
    packing_quantity_kg,packing_cbd_percent,responsible,observations,evidence_reference
  ) values (
    v_order_id,10,'EMPAQUE','COMPLETADA',nullif(p_payload->>'packing_date','')::date,
    nullif(p_payload->>'packing_quantity_kg','')::numeric,
    nullif(p_payload->>'packing_cbd_percent','')::numeric,
    nullif(trim(p_payload->>'responsible'),''),
    nullif(trim(p_payload->>'observations'),''),
    nullif(trim(p_payload->>'evidence_reference'),'')
  ) returning id into v_event_id;

  update public.production_orders set status='FINALIZADA', updated_at=now() where id=v_order_id;
  return jsonb_build_object('event_id',v_event_id,'production_order_id',v_order_id,'status','FINALIZADA','packed_at',now());
end;
$$;

create or replace function public.close_production_order(p_payload jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, private, pg_catalog
as $$
declare
  v_user uuid := auth.uid();
  v_organization_id uuid;
  v_order_id uuid := nullif(p_payload->>'production_order_id','')::uuid;
  v_previous text;
begin
  if v_user is null then raise exception 'AUTH_REQUIRED'; end if;
  if not private.current_user_has_permission('produccion.write') then
    raise exception 'PERMISSION_DENIED: produccion.write';
  end if;
  select p.organization_id into v_organization_id from public.profiles p where p.id=v_user;
  if v_organization_id is null then raise exception 'ORGANIZATION_REQUIRED'; end if;
  select status into v_previous from public.production_orders where id=v_order_id and organization_id=v_organization_id for update;
  if not found then raise exception 'VALIDATION: production order not found'; end if;
  if v_previous <> 'FINALIZADA' then raise exception 'VALIDATION: production must be FINALIZADA'; end if;
  if not exists(select 1 from public.production_process_events where production_order_id=v_order_id and sequence_no=10 and stage_status='COMPLETADA') then raise exception 'VALIDATION: EMPAQUE is required'; end if;

  update public.production_orders set status='CERRADA', closed_at=now(), closed_by=v_user, updated_at=now() where id=v_order_id;
  return jsonb_build_object('production_order_id',v_order_id,'previous_status',v_previous,'status','CERRADA','closed_at',now(),'closed_by',v_user);
end;
$$;

revoke all on function public.create_production_order(jsonb) from public;
revoke all on function public.open_production_order(jsonb) from public;
revoke all on function public.start_production_stage(jsonb) from public;
revoke all on function public.finish_production_stage(jsonb) from public;
revoke all on function public.register_packing(jsonb) from public;
revoke all on function public.close_production_order(jsonb) from public;
grant execute on function public.create_production_order(jsonb) to authenticated;
grant execute on function public.open_production_order(jsonb) to authenticated;
grant execute on function public.start_production_stage(jsonb) to authenticated;
grant execute on function public.finish_production_stage(jsonb) to authenticated;
grant execute on function public.register_packing(jsonb) to authenticated;
grant execute on function public.close_production_order(jsonb) to authenticated;

alter table public.production_orders enable row level security;
alter table public.production_inputs enable row level security;
alter table public.production_process_events enable row level security;

drop policy if exists production_orders_org_select on public.production_orders;
create policy production_orders_org_select on public.production_orders
  for select to authenticated
  using (organization_id = (select p.organization_id from public.profiles p where p.id = auth.uid()));

drop policy if exists production_orders_org_insert on public.production_orders;
drop policy if exists production_orders_org_update on public.production_orders;

drop policy if exists production_inputs_org_select on public.production_inputs;
create policy production_inputs_org_select on public.production_inputs
  for select to authenticated
  using (exists (
    select 1 from public.production_orders po
    where po.id = production_order_id
      and po.organization_id = (select p.organization_id from public.profiles p where p.id = auth.uid())
  ));

drop policy if exists production_process_events_org_select on public.production_process_events;
create policy production_process_events_org_select on public.production_process_events
  for select to authenticated
  using (exists (
    select 1 from public.production_orders po
    where po.id = production_order_id
      and po.organization_id = (select p.organization_id from public.profiles p where p.id = auth.uid())
  ));

drop policy if exists production_process_events_org_insert on public.production_process_events;
drop policy if exists production_process_events_org_update on public.production_process_events;

-- Indices are part of the proposed migration; no ledger row is inserted here.
-- When approved and executed, register:
-- insert into public.schema_migrations(migration_code,migration_name,executed_by,notes)
-- values ('MPCF-026','PRODUCTION_V1',auth.uid(),'Production V1 compatible with MPCF-025');

-- ============================================================
-- MATRIZ DE PRUEBAS PROPUESTA (NO EJECUTADA)
-- P001 Crear orden: UUID y PROGRAMADA.
-- P002 COD duplicado: rechazo por organizacion/fecha/COD.
-- P003 Tenant incorrecto: rechazo en RPC/RLS.
-- P004 Consumo MPCF-025: crea movement/input una vez.
-- P005 Multi-Big-Bag: un movement/input por linea.
-- P006 Consumo parcial: saldos preservados por MPCF-025.
-- P007 Consultar production_inputs por production_order_id.
-- P008 Genealogia: estados CONFIRMADO/PENDIENTE no se elevan.
-- P009 Estado invalido: rechazo de transicion.
-- P010 Etapa valida: evento ACTIVA.
-- P011 Etapa inexistente: rechazo.
-- P012 Etapa duplicada: rechazo.
-- P013 FILTRACION + DESCARBOXILACION solapada: aceptada con ambas iniciadas.
-- P014 Salto: rechazo si no existe etapa previa.
-- P015 Finalizacion invalida: rechazo si no esta ACTIVA.
-- P016 Total CBD: cbd_percent + cbda_percent * 0.877.
-- P017 Total CBD manual: columna generada, no acepta asignacion.
-- P018 Empaque: timestamp backend y estado FINALIZADA.
-- P019 Cierre sin Empaque: rechazo.
-- P020 Cierre valido: FINALIZADA a CERRADA.
-- P021 RLS: no acceso entre organizaciones.
-- P022 Historico sin evento artificial: no se crean filas con cero.

select 'MPCF-026 PROPOSED - NOT EXECUTED' as status;
