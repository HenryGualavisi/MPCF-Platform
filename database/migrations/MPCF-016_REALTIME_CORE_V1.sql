/* ============================================================
   TRAZIX HG — MPCF-016
   REALTIME_CORE_V1
   ============================================================
   Ejecutar UNA SOLA VEZ en Supabase SQL Editor.

   Habilita cambios en tiempo real para las tablas que alimentan
   el circuito operativo MPCF.
   ============================================================ */

do $$
declare
    t text;
    tables text[] := array[
        'organizations',
        'agricultural_lots',
        'harvests',
        'external_references',
        'biomass_receptions',
        'big_bags',
        'reception_agricultural_lots',
        'material_availability',
        'material_movements',
        'production_orders',
        'production_inputs',
        'production_process_events',
        'production_outputs',
        'isolate_lots',
        'production_isolate_outputs'
    ];
begin
    if not exists (
        select 1
        from pg_publication
        where pubname = 'supabase_realtime'
    ) then
        raise exception 'No existe la publicación supabase_realtime';
    end if;

    foreach t in array tables loop
        if to_regclass('public.' || t) is not null
           and not exists (
                select 1
                from pg_publication_tables
                where pubname = 'supabase_realtime'
                  and schemaname = 'public'
                  and tablename = t
           )
        then
            execute format(
                'alter publication supabase_realtime add table public.%I',
                t
            );
        end if;
    end loop;
end $$;

select
    schemaname,
    tablename
from pg_publication_tables
where pubname = 'supabase_realtime'
  and schemaname = 'public'
order by tablename;
