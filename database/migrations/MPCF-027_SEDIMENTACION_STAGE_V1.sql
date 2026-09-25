-- ============================================================
-- MPCF-027 - SEDIMENTACION STAGE V1
-- TRAZIX HG / MPCF Platform
--
-- PROPUESTA NO EJECUTADA.
--
-- Redefine unicamente public.start_production_stage(jsonb) para permitir
-- que reactor_volume_l ("Vol Sedimentadores") se persista tambien cuando
-- event_type = 'SEDIMENTACION'. No crea tablas, columnas, RPC nuevas,
-- constraints ni policies. No modifica finish_production_stage(),
-- production_process_events, MPCF-025, Bodega, Recepcion, Disponibilidad,
-- movimientos ni balances.
--
-- Unico cambio respecto a la version vigente en MPCF-026:
--   case when v_event_type in ('DECARBOXILACION','CRISTALIZACION') then ...
-- pasa a:
--   case when v_event_type in ('DECARBOXILACION','CRISTALIZACION','SEDIMENTACION') then ...
-- ============================================================

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
    case when v_event_type in ('DECARBOXILACION','CRISTALIZACION','SEDIMENTACION') then nullif(p_payload->>'reactor_volume_l','')::numeric end,
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

select 'MPCF-027 PROPOSED - NOT EXECUTED' as status;
