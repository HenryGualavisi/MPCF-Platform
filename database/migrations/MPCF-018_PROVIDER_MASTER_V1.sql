-- ============================================================
-- MPCF-018 — PROVIDER MASTER V1
-- TRAZIX HG / MPCF Platform
--
-- Objetivo:
-- 1) Crear las organizaciones externas que ya existen en la
--    trazabilidad histórica conocida.
-- 2) Evitar que el operador escriba libremente el proveedor.
-- 3) Mantener una identidad estable para cada proveedor.
--
-- NO crea usuarios ni asigna roles de proveedor.
-- NO modifica datos históricos de recepciones existentes.
-- ============================================================

insert into public.organizations (name, code, organization_type, is_active)
values
  ('ECUACANNABIS', 'ECUACANNABIS', 'EXTERNO', true),
  ('NEW LIFE', 'NEW-LIFE', 'EXTERNO', true),
  ('PILVICSA', 'PILVICSA', 'EXTERNO', true),
  ('CANNANGOLD', 'CANNANGOLD', 'EXTERNO', true),
  ('HEOMGROUP', 'HEOMGROUP', 'EXTERNO', true)
on conflict (code) do update
set
  name = excluded.name,
  organization_type = excluded.organization_type,
  is_active = true,
  updated_at = now();

insert into public.schema_migrations
  (migration_code, migration_name, executed_by, notes)
select
  'MPCF-018',
  'PROVIDER_MASTER_V1',
  auth.uid(),
  'Catálogo inicial de proveedores externos para recepción operativa. Sin usuarios ni roles de proveedor.'
where not exists (
  select 1 from public.schema_migrations where migration_code = 'MPCF-018'
);

select name, code, organization_type, is_active
from public.organizations
where code in ('ECUACANNABIS','NEW-LIFE','PILVICSA','CANNANGOLD','HEOMGROUP')
order by name;
