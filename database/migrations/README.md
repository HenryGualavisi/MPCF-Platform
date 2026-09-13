# Migraciones MPCF

Este directorio contendrá las migraciones SQL oficiales versionadas del proyecto.

## Propósito

- mantener el esquema de PostgreSQL/Supabase bajo control versionado
- registrar cambios de forma trazable y reproducible
- establecer la fuente oficial de evolución del esquema
- asegurar que los cambios estructurales se realicen mediante migraciones versionadas

## Convención

Las migraciones deben seguir el patrón oficial de numeración MPCF, por ejemplo:

- MPCF-001
- MPCF-002
- MPCF-003
- MPCF-020

## Regla importante

Las migraciones deben ser la fuente oficial para evolucionar el esquema. No se inventan migraciones ni SQL que aún no existan en el repositorio.
