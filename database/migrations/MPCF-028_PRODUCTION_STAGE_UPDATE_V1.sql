-- ============================================================
-- MPCF-028 - PRODUCTION STAGE UPDATE V1
-- TRAZIX HG / MPCF Platform
--
-- PROPUESTA NO EJECUTADA. Debe aplicarse manualmente en Supabase
-- antes de que la persistencia durante ACTIVA funcione en produccion.
--
-- Objetivo: permitir que las variables operativas de una etapa de
-- Produccion V1 se corrijan/completen MIENTRAS la etapa esta ACTIVA,
-- sin esperar a finish_production_stage().
--
-- Crea UNICAMENTE una RPC nueva: public.update_production_stage(jsonb).
-- No crea tablas, columnas, constraints ni policies nuevas.
-- No modifica start_production_stage(), finish_production_stage(),
-- register_packing(), close_production_order(), production_orders,
-- production_process_events, RLS existente ni MPCF-025.
--
-- Reglas de la funcion:
--   - Requiere autenticacion y permiso 'produccion.write' (igual que
--     start_production_stage / finish_production_stage).
--   - Solo actualiza el registro EXISTENTE de production_process_events
--     identificado por (production_order_id, sequence_no) dentro de la
--     organizacion del usuario.
--   - Exige stage_status = 'ACTIVA'. Si la etapa esta PENDIENTE,
--     COMPLETADA o no existe, lanza excepcion y no modifica nada.
--   - Bloquea explicitamente event_type = 'EMPAQUE' (EMPAQUE es
--     excepcion: se registra unicamente via register_packing()).
--   - El event_type y sequence_no de la fila NO se modifican; se leen
--     desde la fila existente (no se confia en el event_type enviado
--     por el cliente) para decidir que columnas operativas aplican,
--     replicando el mismo mapeo campo-por-etapa de start_production_stage.
--   - Usa coalesce(nuevo_valor, valor_actual): solo sobrescribe una
--     columna si el cliente envia un valor no vacio. No permite vaciar
--     (limpiar a NULL) un campo ya guardado; unicamente corregir o
--     completar valores. started_at, ended_at y stage_status jamas se
--     tocan aqui.
--   - No afecta eventos historicos: una etapa ya COMPLETADA no puede
--     actualizarse mediante esta funcion.
-- ============================================================

create or replace function public.update_production_stage(p_payload jsonb)
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
  v_event_type text;
  v_status text;
begin
  if v_user is null then raise exception 'AUTH_REQUIRED'; end if;
  if not private.current_user_has_permission('produccion.write') then
    raise exception 'PERMISSION_DENIED: produccion.write';
  end if;
  select p.organization_id into v_organization_id from public.profiles p where p.id = v_user;
  if v_organization_id is null then raise exception 'ORGANIZATION_REQUIRED'; end if;
  if v_order_id is null then raise exception 'VALIDATION: production_order_id is required'; end if;
  if v_sequence is null then raise exception 'VALIDATION: sequence_no is required'; end if;

  select e.event_type, e.stage_status into v_event_type, v_status
  from public.production_process_events e
  join public.production_orders po on po.id = e.production_order_id
  where e.production_order_id = v_order_id and e.sequence_no = v_sequence
    and po.organization_id = v_organization_id
  for update;
  if not found then raise exception 'VALIDATION: production stage not found'; end if;
  if v_event_type = 'EMPAQUE' then raise exception 'VALIDATION: EMPAQUE cannot be updated via update_production_stage'; end if;
  if v_status <> 'ACTIVA' then raise exception 'VALIDATION: stage is not active'; end if;

  update public.production_process_events set
    responsible = coalesce(nullif(trim(p_payload->>'responsible'),''), responsible),
    observations = coalesce(nullif(trim(p_payload->>'observations'),''), observations),
    evidence_reference = coalesce(nullif(trim(p_payload->>'evidence_reference'),''), evidence_reference),
    naoh_percent = coalesce(case when v_event_type='EXTRACCION' then nullif(p_payload->>'naoh_percent','')::numeric end, naoh_percent),
    frequency = coalesce(case when v_event_type='EXTRACCION' then nullif(trim(p_payload->>'frequency'),'') end, frequency),
    caudal_l = coalesce(case when v_event_type='EXTRACCION' then nullif(p_payload->>'caudal_l','')::integer end, caudal_l),
    recirculacion = coalesce(case when v_event_type='EXTRACCION' then nullif(upper(trim(p_payload->>'recirculacion')),'') end, recirculacion),
    filter_configuration = coalesce(case when v_event_type='FILTRACION' then nullif(trim(p_payload->>'filter_configuration'),'') end, filter_configuration),
    reactor = coalesce(case when v_event_type='DECARBOXILACION' then nullif(trim(p_payload->>'reactor'),'') end, reactor),
    temperature_initial_c = coalesce(case when v_event_type in ('DECARBOXILACION','ENFRIAMIENTO','CRISTALIZACION') then nullif(p_payload->>'temperature_initial_c','')::numeric end, temperature_initial_c),
    temperature_final_c = coalesce(case when v_event_type in ('DECARBOXILACION','ENFRIAMIENTO','CRISTALIZACION') then nullif(p_payload->>'temperature_final_c','')::numeric end, temperature_final_c),
    reactor_volume_l = coalesce(case when v_event_type in ('DECARBOXILACION','CRISTALIZACION','SEDIMENTACION') then nullif(p_payload->>'reactor_volume_l','')::numeric end, reactor_volume_l),
    cbd_percent = coalesce(case when v_event_type='DECARBOXILACION' then nullif(p_payload->>'cbd_percent','')::numeric end, cbd_percent),
    cbda_percent = coalesce(case when v_event_type='DECARBOXILACION' then nullif(p_payload->>'cbda_percent','')::numeric end, cbda_percent),
    wet_weight_kg = coalesce(case when v_event_type in ('COSECHA','LAVADO') then nullif(p_payload->>'wet_weight_kg','')::numeric end, wet_weight_kg),
    filter_media = coalesce(case when v_event_type='COSECHA' then nullif(trim(p_payload->>'filter_media'),'') end, filter_media),
    alkaline_wash_count = coalesce(case when v_event_type='LAVADO' then nullif(p_payload->>'alkaline_wash_count','')::integer end, alkaline_wash_count),
    alkaline_wash_l = coalesce(case when v_event_type='LAVADO' then nullif(p_payload->>'alkaline_wash_l','')::numeric end, alkaline_wash_l),
    acid_wash_count = coalesce(case when v_event_type='LAVADO' then nullif(p_payload->>'acid_wash_count','')::integer end, acid_wash_count),
    acid_wash_l = coalesce(case when v_event_type='LAVADO' then nullif(p_payload->>'acid_wash_l','')::numeric end, acid_wash_l),
    neutral_wash_count = coalesce(case when v_event_type='LAVADO' then nullif(p_payload->>'neutral_wash_count','')::integer end, neutral_wash_count),
    neutral_wash_l = coalesce(case when v_event_type='LAVADO' then nullif(p_payload->>'neutral_wash_l','')::numeric end, neutral_wash_l),
    pre_drying = coalesce(case when v_event_type='SECADO' then nullif(p_payload->>'pre_drying','')::boolean end, pre_drying),
    vacuum = coalesce(case when v_event_type='SECADO' then nullif(p_payload->>'vacuum','')::boolean end, vacuum),
    drying_weight_kg = coalesce(case when v_event_type='SECADO' then nullif(p_payload->>'drying_weight_kg','')::numeric end, drying_weight_kg),
    drying_color = coalesce(case when v_event_type='SECADO' then nullif(trim(p_payload->>'drying_color'),'') end, drying_color),
    drying_temperature_c = coalesce(case when v_event_type='SECADO' then nullif(p_payload->>'drying_temperature_c','')::numeric end, drying_temperature_c),
    updated_at = now()
  where production_order_id = v_order_id and sequence_no = v_sequence;

  return jsonb_build_object(
    'production_order_id', v_order_id,
    'sequence_no', v_sequence,
    'event_type', v_event_type,
    'stage_status', 'ACTIVA',
    'updated_at', now()
  );
end;
$$;

revoke all on function public.update_production_stage(jsonb) from public;
grant execute on function public.update_production_stage(jsonb) to authenticated;

select 'MPCF-028 PROPOSED - NOT EXECUTED' as status;
