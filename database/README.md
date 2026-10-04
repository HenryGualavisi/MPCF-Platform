# Base de datos MPCF

## Estado real del esquema y evolución

Este repositorio conserva documentación y evidencia operativa del modelo de datos de MPCF Platform, pero no todo el historial de SQL fue versionado físicamente en GitHub. Algunas migraciones fueron ejecutadas directamente en Supabase y solo se documentan como ejecutadas, mientras que otras sí cuentan con archivo SQL físico presente en este repositorio.

## Fuentes autorizadas
- GitHub: versión física y trazable del código y SQL versionado disponible en repositorio.
- Supabase/PostgreSQL: base operativa real del sistema.
- Migraciones MPCF: mecanismo oficial de evolución y auditoría de esquema.

## Matriz real de migraciones

### Ejecutadas en Supabase
- MPCF-001 — ejecutada online
- MPCF-002 — ejecutada online
- MPCF-003 — ejecutada online
- MPCF-004 — ejecutada online
- MPCF-005 — ejecutada online
- MPCF-006 — ejecutada online
- MPCF-007 — ejecutada online
- MPCF-008 — ejecutada online
- MPCF-009 — ejecutada online
- MPCF-010 — ejecutada online
- MPCF-011 — ejecutada online
- MPCF-012 — ejecutada online
- MPCF-013 — ejecutada online
- MPCF-014 — ejecutada online
- MPCF-015 — ejecutada online
- MPCF-016 — ejecutada online + SQL físico en repo
- MPCF-017 — ejecutada online
- MPCF-018 — ejecutada online + SQL físico en repo
- MPCF-020 — ejecutada online + SQL físico en repo + validación funcional

### Preparada / pendiente de confirmación
- MPCF-019 — SQL físico en repo; ejecución NO CONFIRMADA en este corte
- MPCF-029 — SQL presente para Laboratorio; ejecución NO CONFIRMADA
- MPCF-030 — SQL presente para composition_code; ejecución NO CONFIRMADA en este corte
- MPCF-031 — SQL CP15 de realtime/histórico preparada; ejecución NO CONFIRMADA

### SQL físicos actualmente presentes en GitHub
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
- MPCF-029_LABORATORY_QUALITY_V1.sql
- MPCF-030_LABORATORY_COMPOSITION_CODE_FIX_V1.sql
- MPCF-031_LABORATORY_REALTIME_HISTORY_V1.sql

## Regla crítica de documentación
No se debe confundir:
- “ejecutada en Supabase”
- “SQL físicamente versionado en GitHub”

La ausencia de archivo físico no significa que la migración no exista; significa que no hay evidencia versionada en el repositorio. Del mismo modo, la existencia de archivo físico no implica ejecución confirmada.

## Principios aplicados
- RLS activo y crítico para seguridad.
- Data API controlada manualmente.
- `Automatically expose new tables` desactivado.
- `public.get_current_user_context()` como función expuesta autorizada.
- no se exponen perfiles ni roles del navegador para construir contexto de usuario.
- recepción, disponibilidad y consumo se mantienen como eventos distintos.
- Big Bag conserva identidad física y relación operativa con recepción.

## Nota de integridad documental
Se documentan las ejecuciones confirmadas, pero no se reconstruyen SQL históricos sin evidencia. El repositorio refleja lo que existe físicamente y lo que se ha validado como ejecutado en Supabase.

## CP14 — Laboratorio / Calidad

`MPCF-029_LABORATORY_QUALITY_V1.sql` está PREPARADO y su ejecución en Supabase no está confirmada. Agrega tablas de muestras, ensayos y resultados, valida el vínculo al subproceso existente y calcula LFW desde kg consumidos en `production_inputs`. Una muestra `VALIDADO` permanece consultable como histórico, pero sus resultados y estado quedan cerrados a cambios operativos. Reutiliza permisos existentes y no altera MPCF-025 ni el Stage Engine.

La interfaz requiere exponer manualmente las seis RPCs públicas indicadas en `migrations/README.md`; no requiere exponer las tablas de Laboratorio directamente.

`MPCF-031_LABORATORY_REALTIME_HISTORY_V1.sql` prepara CP15: publica eventos Realtime de las tablas del Laboratorio, separa COD activos y COD completados por EMPAQUE validado y limita el histórico visible a los 7 completados más recientes. El histórico es solo lectura; no se eliminan filas. Para Realtime, concede solo `SELECT` a `authenticated` en las tres tablas analíticas, con las políticas RLS existentes sin modificar; las lecturas del Data API quedan sujetas a esas políticas. La migración depende de MPCF-029 y no se ha confirmado ejecutada ni validada en Supabase. MPCF-030 se mantiene sin modificaciones.
