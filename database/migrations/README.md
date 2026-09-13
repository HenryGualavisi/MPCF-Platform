# Migraciones MPCF

## Estado real del repositorio

El repositorio contiene actualmente los SQL físicamente recuperados y versionados que se han incorporado a GitHub. Las migraciones históricas ejecutadas en Supabase cuyo SQL no fue incorporado al repositorio se mantienen documentadas como ejecutadas, pero no se reconstruyen sin evidencia.

## SQL físicos actualmente versionados en GitHub

Los archivos SQL presentes en esta carpeta son:
- MPCF-016_REALTIME_CORE_V1.sql
- MPCF-018_PROVIDER_MASTER_V1.sql
- MPCF-019_RECEIPTION_TRANSACTION_V1.sql
- MPCF-020_USER_CONTEXT_RPC_V1.sql

## Distinción de estados

### Ejecutada en Supabase
Se considera ejecutada en Supabase cuando la migración fue aplicada en el proyecto real del backend, aunque su SQL no esté físicamente incluido en el repositorio.

### Versionado en GitHub
Se considera versionado en GitHub cuando el archivo SQL físico está presente en `database/migrations/` y forma parte del repositorio.

### Regla formal
No se debe afirmar que una migración fue ejecutada solo porque existe un archivo en GitHub. Tampoco se debe afirmar que una migración está disponible en SQL si el archivo no existe físicamente.

## Matriz documental relevante

- MPCF-001 — ejecutada en Supabase
- MPCF-002 — ejecutada en Supabase
- MPCF-003 — ejecutada en Supabase
- MPCF-004 — ejecutada en Supabase
- MPCF-005 — ejecutada en Supabase
- MPCF-006 — ejecutada en Supabase
- MPCF-007 — ejecutada en Supabase
- MPCF-008 — ejecutada en Supabase
- MPCF-009 — ejecutada en Supabase
- MPCF-010 — ejecutada en Supabase
- MPCF-011 — ejecutada en Supabase
- MPCF-012 — ejecutada en Supabase
- MPCF-013 — ejecutada en Supabase
- MPCF-014 — ejecutada en Supabase
- MPCF-015 — ejecutada en Supabase
- MPCF-016 — ejecutada en Supabase + SQL físico en GitHub
- MPCF-017 — ejecutada en Supabase
- MPCF-018 — ejecutada en Supabase + SQL físico en GitHub
- MPCF-019 — SQL físico en GitHub; ejecución no confirmada en este corte
- MPCF-020 — ejecutada en Supabase + SQL físico en GitHub + validación funcional

## Reglas de trabajo
- no inventar SQL faltante
- no reconstruir migraciones sin evidencia
- no marcar una migración como ejecutada si solo existe el archivo y no hay confirmación
- no modificar SQL existentes
- mantener la trazabilidad de cada cambio estructural mediante documentación y versionado claro

## Nota final
Este directorio refleja el estado real del repositorio: hay SQL físicos recuperados y además migraciones ejecutadas en Supabase que no están físicamente incorporadas al código del repositorio.
