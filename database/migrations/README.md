# Migraciones MPCF

## Estado real del repositorio

El repositorio contiene actualmente los SQL físicamente recuperados y versionados que se han incorporado a GitHub. Las migraciones históricas ejecutadas en Supabase cuyo SQL no fue incorporado al repositorio se mantienen documentadas como ejecutadas, pero no se reconstruyen sin evidencia.

## SQL físicos actualmente versionados en GitHub

Los archivos SQL presentes en esta carpeta son:
- MPCF-016_REALTIME_CORE_V1.sql
- MPCF-018_PROVIDER_MASTER_V1.sql
- MPCF-019_RECEIPTION_TRANSACTION_V1.sql
- MPCF-020_USER_CONTEXT_RPC_V1.sql
- MPCF-021_RECEIPTION_TRANSACTION_ORGANIZATION_CONTEXT_V1.sql
- MPCF-022_CONSUMPTION_TRANSACTION_V1.sql
- MPCF-024_RECEPTION_AVAILABILITY_BRIDGE_V1.sql
- MPCF-025_CONSUMPTION_TRANSACTION_MULTI_BIG_BAG_V1.sql
- MPCF-026_PRODUCTION_V1.sql
- MPCF-027_SEDIMENTACION_STAGE_V1.sql
- MPCF-028_PRODUCTION_STAGE_UPDATE_V1.sql

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
- MPCF-029 — archivo local preparado; sin commit; ejecución y validación funcional pendientes

## Reglas de trabajo
- no inventar SQL faltante
- no reconstruir migraciones sin evidencia
- no marcar una migración como ejecutada si solo existe el archivo y no hay confirmación
- no modificar SQL existentes
- mantener la trazabilidad de cada cambio estructural mediante documentación y versionado claro

## Nota final
Este directorio refleja el estado real del repositorio: hay SQL físicos recuperados y además migraciones ejecutadas en Supabase que no están físicamente incorporadas al código del repositorio.

## MPCF-029 — LABORATORY / QUALITY V1

Estado local: PREPARADO en un archivo sin commit; NO EJECUTADO ni VALIDADO en PostgreSQL.

El archivo `MPCF-029_LABORATORY_QUALITY_V1.sql` agrega muestras, ensayos y resultados analíticos con RLS. La población de biomasa se verifica y pondera desde `production_inputs`, Big Bags y recepciones. Reutiliza `laboratorio.read`, `laboratorio.write` y `produccion.read`; no crea roles ni permissions y no modifica tablas, RPCs o etapas de Producción.

El cierre operativo de muestras validadas forma parte de este SQL preparado: los registros y resultados siguen disponibles para consulta, mientras que las RPCs y triggers impiden reabrir la muestra o modificar sus resultados. La interfaz oculta captura y validación para muestras `VALIDADO`, conservando la detección de muestras por producción, proveedor y lote para permitir únicamente combinaciones aún no cubiertas.

La interfaz consume seis RPCs públicas de Laboratorio/atributos oficiales. Como la exposición automática de la Data API está desactivada, esas funciones deben habilitarse explícitamente en la configuración de Supabase después de revisar y ejecutar la migración. Las tablas nuevas no se exponen directamente al navegador.

Las pruebas de persistencia, RLS en Supabase y no regresión con datos reales siguen pendientes; el análisis estático local no sustituye esas validaciones.
