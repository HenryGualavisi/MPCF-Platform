/* ============================================================
   TRAZIX HG — MPCF-020
   USER_CONTEXT_RPC_V1
   ============================================================
   Crear una RPC segura para devolver el contexto mínimo requerido
   por el frontend autenticado (usuario, nombre, organización y rol).

   Importante:
   - Esta función no devuelve permisos completos ni tablas sensibles.
   - Después de ejecutar la migración en Supabase, debe exponerse
     manualmente en Integrations → Data API → Exposed functions.
   - Mantener 1 de 5 functions exposed para esta RPC y no exponer
     la totalidad de seguridad operativa al navegador.
   ============================================================ */

create or replace function public.get_current_user_context()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_catalog
as $$
declare
  v_user_id uuid;
  v_profile record;
  v_organization record;
  v_roles jsonb;
begin
  v_user_id := auth.uid();

  if v_user_id is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  select p.id, p.full_name, p.email, p.organization_id
    into v_profile
  from public.profiles p
  where p.id = v_user_id;

  if v_profile.id is null then
    return jsonb_build_object(
      'user_id', v_user_id,
      'full_name', null,
      'organization_id', null,
      'organization_name', null,
      'organization_code', null,
      'roles', '[]'::jsonb
    );
  end if;

  select o.id, o.name, o.code
    into v_organization
  from public.organizations o
  where o.id = v_profile.organization_id;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', r.id,
        'name', r.name
      )
      order by r.name
    ),
    '[]'::jsonb
  )
    into v_roles
  from public.user_roles ur
  join public.roles r on r.id = ur.role_id
  where ur.user_id = v_profile.id;

  return jsonb_build_object(
    'user_id', v_profile.id,
    'full_name', v_profile.full_name,
    'organization_id', v_profile.organization_id,
    'organization_name', v_organization.name,
    'organization_code', v_organization.code,
    'roles', coalesce(v_roles, '[]'::jsonb)
  );
end;
$$;

revoke all on function public.get_current_user_context() from public;
revoke all on function public.get_current_user_context() from anon;
grant execute on function public.get_current_user_context() to authenticated;

insert into public.schema_migrations
  (migration_code, migration_name, executed_by, notes)
select
  'MPCF-020',
  'USER_CONTEXT_RPC_V1',
  auth.uid(),
  'RPC segura para contexto mínimo del usuario autenticado; frontend consume sin tocar perfiles ni roles desde el navegador.'
where not exists (
  select 1
  from public.schema_migrations
  where migration_code = 'MPCF-020'
);
