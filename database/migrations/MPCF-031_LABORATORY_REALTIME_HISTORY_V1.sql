-- ============================================================
-- MPCF-031 - LABORATORY REALTIME / HISTORY V1
-- TRAZIX HG / MPCF Platform
--
-- PREPARED - NOT EXECUTED.
-- Adds realtime delivery and read-only completion handling for
-- the Laboratory module. Does not change analytical rules,
-- existing RLS policies, LFW, composition_code or Production.
-- Requires MPCF-029 Laboratory tables to be installed.
-- Grants SELECT to authenticated solely for Postgres Changes; existing
-- organization and permission RLS policies remain the read boundary.
-- ============================================================

do $$
declare
  v_table text;
  v_tables text[] := array[
    'laboratory_samples',
    'laboratory_tests',
    'laboratory_results'
  ];
begin
  if not exists (
    select 1 from pg_publication where pubname = 'supabase_realtime'
  ) then
    raise exception 'No existe la publicación supabase_realtime';
  end if;

  foreach v_table in array v_tables loop
    if to_regclass('public.' || v_table) is null then
      raise exception 'MPCF-029 debe estar aplicada antes de MPCF-031: falta public.%', v_table;
    end if;

    if not exists (
      select 1
      from pg_publication_tables
      where pubname = 'supabase_realtime'
        and schemaname = 'public'
        and tablename = v_table
    ) then
      execute format(
        'alter publication supabase_realtime add table public.%I',
        v_table
      );
    end if;
  end loop;
end
$$;

create or replace function private.is_laboratory_order_completed(p_order_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, private, pg_catalog
as $$
  select exists (
    select 1
    from public.laboratory_samples s
    join public.production_process_events e
      on e.id = s.production_process_event_id
     and e.production_order_id = s.production_order_id
    where s.production_order_id = p_order_id
      and s.sample_type = 'STAGE_OUTPUT'
      and s.analytical_status = 'VALIDADO'
      and e.event_type = 'EMPAQUE'
  );
$$;

create or replace function private.prevent_laboratory_completed_order_mutations()
returns trigger
language plpgsql
security definer
set search_path = public, private, pg_catalog
as $$
declare
  v_old_order_id uuid;
  v_new_order_id uuid;
begin
  if tg_table_name = 'laboratory_samples' then
    if tg_op <> 'INSERT' then
      v_old_order_id := old.production_order_id;
    end if;
    if tg_op <> 'DELETE' then
      v_new_order_id := new.production_order_id;
    end if;
  else
    if tg_op <> 'INSERT' then
      select s.production_order_id into v_old_order_id
      from public.laboratory_samples s
      where s.id = old.sample_id;
    end if;
    if tg_op <> 'DELETE' then
      select s.production_order_id into v_new_order_id
      from public.laboratory_samples s
      where s.id = new.sample_id;
    end if;
  end if;

  if (v_old_order_id is not null and private.is_laboratory_order_completed(v_old_order_id))
     or (v_new_order_id is not null and private.is_laboratory_order_completed(v_new_order_id)) then
    raise exception 'VALIDATION: completed laboratory order is read-only';
  end if;

  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;

drop trigger if exists laboratory_samples_completed_order_read_only on public.laboratory_samples;
create trigger laboratory_samples_completed_order_read_only
before insert or update or delete on public.laboratory_samples
for each row execute function private.prevent_laboratory_completed_order_mutations();

drop trigger if exists laboratory_tests_completed_order_read_only on public.laboratory_tests;
create trigger laboratory_tests_completed_order_read_only
before insert or update or delete on public.laboratory_tests
for each row execute function private.prevent_laboratory_completed_order_mutations();

drop trigger if exists laboratory_results_completed_order_read_only on public.laboratory_results;
create trigger laboratory_results_completed_order_read_only
before insert or update or delete on public.laboratory_results
for each row execute function private.prevent_laboratory_completed_order_mutations();

create or replace function public.get_laboratory_orders()
returns jsonb
language plpgsql
security definer
set search_path = public, private, pg_catalog
as $$
declare
  v_user uuid := auth.uid();
  v_organization_id uuid;
  v_orders jsonb;
begin
  if v_user is null then raise exception 'AUTH_REQUIRED'; end if;
  if not private.current_user_has_permission('laboratorio.read') then
    raise exception 'PERMISSION_DENIED: laboratorio.read';
  end if;

  select p.organization_id into v_organization_id
  from public.profiles p where p.id = v_user;
  if v_organization_id is null then raise exception 'ORGANIZATION_REQUIRED'; end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', po.id,
    'cod', po.cod,
    'production_date', po.production_date,
    'shift', po.shift,
    'status', po.status,
    'laboratory_completed', completion.completed_at is not null,
    'laboratory_completed_at', completion.completed_at
  ) order by po.production_date desc, po.cod desc), '[]'::jsonb)
    into v_orders
  from public.production_orders po
  left join lateral (
    select s.updated_at as completed_at
    from public.laboratory_samples s
    join public.production_process_events e
      on e.id = s.production_process_event_id
     and e.production_order_id = s.production_order_id
    where s.production_order_id = po.id
      and s.sample_type = 'STAGE_OUTPUT'
      and s.analytical_status = 'VALIDADO'
      and e.event_type = 'EMPAQUE'
    order by s.updated_at desc
    limit 1
  ) completion on true
  where po.organization_id = v_organization_id
    and exists (
      select 1 from public.production_inputs pi
      where pi.production_order_id = po.id
    );

  return v_orders;
end;
$$;

revoke all on function private.is_laboratory_order_completed(uuid) from public, anon, authenticated;
revoke all on function private.prevent_laboratory_completed_order_mutations() from public, anon, authenticated;

grant select on public.laboratory_samples, public.laboratory_tests, public.laboratory_results
  to authenticated;

select 'MPCF-031 LABORATORY REALTIME / HISTORY V1 PREPARED - NOT EXECUTED' as status;
