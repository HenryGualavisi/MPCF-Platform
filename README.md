# MPCF Platform by TRAZIX HG

## Estado real del proyecto (13-09-2026)

MPCF Platform es la plataforma de trazabilidad y operaciones de TRAZIX HG.

No se trata de un producto final cerrado ni de una demo estática: el proyecto está en construcción operativa con backend real en Supabase, autenticación real, RLS activo, Data API controlada y dashboard conectado a datos reales.

## Identidad
- Proyecto: TRAZIX HG
- Producto: MPCF Platform
- Descriptor: Traceability & Operations
- Repositorio: HenryGualavisi/MPCF-Platform
- Backend: Supabase — proyecto MPCF Platform
- Deploy: GitHub Pages

## Flujo de desarrollo oficial
VS Code + Agent
↓
revisión
↓
Keep
↓
GitHub Desktop
↓
Commit
↓
Push
↓
GitHub
↓
GitHub Pages
↓
prueba real

Los ZIP quedan como respaldo/exportación histórica. No son el flujo principal de desarrollo.

## Estado operativo confirmado
- Supabase Auth real operativo.
- Login real probado.
- Logout probado.
- Usuario administrativo real identificado: TRAZIX HG / SUPERADMIN.
- Contexto del usuario recuperado a través de la RPC pública `public.get_current_user_context()`.
- Dashboard consultando datos reales desde Supabase.
- Trazabilidad real demostrada con el caso P19 / L2 / MERLOT / PILVICSA / ISOL 04126.
- Data API habilitada con control manual; `Automatically expose new tables` desactivado.
- Data API real: `public` expuesto; `private` no expuesto; `16 de 24` tablas expuestas; `1 de 6` funciones expuestas; función expuesta: `public.get_current_user_context`.
- Dashboard validado con datos reales: `1` lote agrícola, `2` recepciones, `2` producciones y `1` producto/ISOL.

## Caso real confirmado
P19
→ L2
→ MERLOT
→ PILVICSA
→ cosecha 11-02-2026
→ 626 kg biomasa fresca
→ recepción REC-20260211-001
→ COD054
→ 626 kg consumidos
→ proceso
→ 7.670 kg aislado
→ pureza 99.9%
→ ISOL 04126

La relación COD054 → ISOL04126 se documenta como relación técnica demostrada; no se presenta como reconstrucción completa de toda la genealogía histórica de ISOL04126. El caso cuenta con 31 registros históricos asociados, 30 COD únicos, 18 vínculos agrícolas directos resolubles y 13 pendientes.

## Provider Master
El catálogo de proveedores externos confirmado es:
- ECUACANNABIS
- NEW LIFE
- PILVICSA
- CANNANGOLD
- HEOMGROUP

La clasificación interna `GRUPO/EXTERNO` no se expone al proveedor; los proveedores se gestionan como entidades externas y estables.

## Seguridad
La seguridad crítica se aplica en backend y PostgreSQL/RLS. El frontend no expone service role ni secretos. La configuración pública del cliente se mantiene en `config.js`, mientras que el contexto de usuario no depende de consultas directas a perfiles, roles o organizaciones desde el navegador.

## MPCF-020
`MPCF-020 USER_CONTEXT_RPC_V1` está documentado como ejecutada y validada.

RPC:
- `public.get_current_user_context()`

Función:
- devuelve `user_id`, `full_name`, `organization_id`, `organization_name`, `organization_code` y `roles`
- usa `SECURITY DEFINER`
- emplea `auth.uid()`
- revoke para `anon`
- `EXECUTE` para `authenticated`
- sin `user_id` externo recibido
- sin exponer tablas sensibles directamente al frontend

Resultado funcional confirmado:
- el frontend publicado muestra correctamente `TRAZIX HG` y `SUPERADMIN`.

## Arquitectura aplicada
Browser
↓
Supabase Auth
↓
RPC de contexto / Data API
↓
PostgreSQL + RLS
↓
Realtime

## Estado de documentación
La documentación del repositorio se ha reconciliado con el estado real del proyecto y no se presenta como demo final ni como sistema totalmente cerrado. El sistema está operativo en construcción con validación real y trazabilidad documental demostrada.
