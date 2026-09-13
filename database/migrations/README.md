# Migraciones MPCF

Este directorio está preparado para recibir las migraciones SQL oficiales versionadas del proyecto.

## Estado actual del repositorio

Actualmente, en esta carpeta solo existe este archivo de documentación:

- README.md

No existen archivos SQL físicos de migraciones reales dentro de `database/migrations/` en el repositorio actual.

## Migraciones disponibles físicamente

No hay migraciones SQL reales disponibles en esta carpeta en el estado actual del repositorio.

## Migraciones documentadas pero pendientes de incorporar

La documentación del proyecto identifica migraciones MPCF desde MPCF-001 hasta MPCF-018, y además indica que MPCF-019 está preparado pero pendiente de ejecución/confirmación.

Eso significa que estas migraciones están documentadas como parte del plan arquitectónico del proyecto, pero no cuentan con archivos SQL reales presentes en el repositorio actual.

## Reglas de trabajo

- no deben inventarse migraciones faltantes
- no deben reconstruirse SQL a partir de suposiciones
- no deben crearse archivos vacíos para simular migraciones existentes
- no debe marcarse una migración como ejecutada solo porque aparece en documentación
- la fuente oficial de cada migración debe ser su SQL real y versionado, cuando exista físicamente en el repositorio

## Fuente oficial

Las migraciones deben ser la fuente oficial para evolucionar el esquema de PostgreSQL/Supabase. Cualquier cambio estructural del backend debe hacerse mediante una migración real y versionada, no mediante edición manual directa.

## Regla importante

La ausencia de un archivo SQL real en el repositorio significa que esa migración no está incorporada como implementación efectiva. El repositorio debe reflejar únicamente lo que existe físicamente, y cualquier migración pendiente debe incorporarse formalmente cuando se disponga de su SQL real y versionado.
