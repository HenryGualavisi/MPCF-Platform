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

### SQL físicos actualmente presentes en GitHub
- MPCF-016_REALTIME_CORE_V1.sql
- MPCF-018_PROVIDER_MASTER_V1.sql
- MPCF-019_RECEIPTION_TRANSACTION_V1.sql
- MPCF-020_USER_CONTEXT_RPC_V1.sql

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
