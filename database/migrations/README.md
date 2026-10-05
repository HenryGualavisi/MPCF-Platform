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
- MPCF-029_LABORATORY_QUALITY_V1.sql
- MPCF-030_LABORATORY_COMPOSITION_CODE_FIX_V1.sql
- MPCF-031_LABORATORY_REALTIME_HISTORY_V1.sql
- MPCF-033_FINISHED_PRODUCT_INVENTORY_V1.sql
- MPCF-034_COD_IDENTIFIER_FULL_NUMBER_FIX_V1.sql
- MPCF-035_PRODUCT_ISOL_V1.sql
- MPCF-036_SALES_V1.sql

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
- MPCF-029 — SQL presente; ejecución y validación funcional pendientes de confirmar
- MPCF-030 — SQL presente; ejecución y validación funcional pendientes de confirmar
- MPCF-031 — SQL CP15 preparado; ejecución y validación funcional pendientes de confirmar
- MPCF-033 — SQL MOD-007 preparado; ejecución y validación funcional pendientes de confirmar
- MPCF-034 — SQL preparado; ejecución y validación funcional pendientes de confirmar
- MPCF-035 — SQL Producto / ISOL V1 preparado; ejecución y validación funcional pendientes de confirmar
- MPCF-036 — SQL MOD-011 Ventas V1 preparado; ejecución y validación funcional pendientes de confirmar

## Reglas de trabajo
- no inventar SQL faltante
- no reconstruir migraciones sin evidencia
- no marcar una migración como ejecutada si solo existe el archivo y no hay confirmación
- no modificar SQL existentes
- mantener la trazabilidad de cada cambio estructural mediante documentación y versionado claro

## Nota final
Este directorio refleja el estado real del repositorio: hay SQL físicos recuperados y además migraciones ejecutadas en Supabase que no están físicamente incorporadas al código del repositorio.

## MPCF-029 — LABORATORY / QUALITY V1

Estado local: SQL presente y PREPARADO; ejecución y validación funcional en PostgreSQL NO CONFIRMADAS.

El archivo `MPCF-029_LABORATORY_QUALITY_V1.sql` agrega muestras, ensayos y resultados analíticos con RLS. La población de biomasa se verifica y pondera desde `production_inputs`, Big Bags y recepciones. Reutiliza `laboratorio.read`, `laboratorio.write` y `produccion.read`; no crea roles ni permissions y no modifica tablas, RPCs o etapas de Producción.

El cierre operativo de muestras validadas forma parte de este SQL preparado: los registros y resultados siguen disponibles para consulta, mientras que las RPCs y triggers impiden reabrir la muestra o modificar sus resultados. La interfaz oculta captura y validación para muestras `VALIDADO`, conservando la detección de muestras por producción, proveedor y lote para permitir únicamente combinaciones aún no cubiertas.

La interfaz consume seis RPCs públicas de Laboratorio/atributos oficiales. Como la exposición automática de la Data API está desactivada, esas funciones deben habilitarse explícitamente en la configuración de Supabase después de revisar y ejecutar la migración. Las tablas nuevas no se exponen directamente al navegador.

Las pruebas de persistencia, RLS en Supabase y no regresión con datos reales siguen pendientes; el análisis estático local no sustituye esas validaciones.

## MPCF-031 — CP15 Laboratory Realtime / History V1

Estado local: PREPARADO; NO EJECUTADO ni VALIDADO en PostgreSQL. Requiere MPCF-029 aplicada.

La migración incorpora las tablas CP14 de Laboratorio a la publicación `supabase_realtime`, clasifica el cierre del COD exclusivamente por la muestra `STAGE_OUTPUT` validada en el evento `EMPAQUE`, extiende la RPC `get_laboratory_orders()` con los datos de cierre y bloquea escrituras de muestras/resultados para COD completados. Concede únicamente `SELECT` a `authenticated` sobre las tres tablas analíticas porque Supabase Postgres Changes lo exige; las políticas RLS de organización y permisos existentes continúan limitando las filas visibles y no se crean políticas nuevas. Esto habilita lecturas directas bajo RLS por los usuarios autorizados del Data API. No cambia fórmula LFW, `composition_code` ni Producción. La interfaz usa los eventos Realtime existentes de consumo/producción y los eventos de las tablas de Laboratorio para actualizar el módulo sin recargas completas; el histórico presenta hasta 7 COD en modo solo lectura.

La aplicación ordenada para validación real es MPCF-029, MPCF-030 (si su ejecución es requisito funcional de CP14), y MPCF-031. No se debe declarar ninguna ejecución sin confirmación en Supabase. La validación funcional CP15 requiere datos reales y permanece pendiente.

## MPCF-033 — MOD-007 FINISHED PRODUCT INVENTORY V1

Estado local: PREPARADO; NO EJECUTADO ni VALIDADO en PostgreSQL. Requiere MPCF-026 y MPCF-029.

Crea `finished_products` y `finished_product_movements` (ENTRADA/SALIDA, solo inserción, sin saldo almacenado) y un trigger que registra la ENTRADA al completarse EMPAQUE con `packing_quantity_kg`, idempotente por evento. Lectura mediante `get_finished_product_inventory()` y `get_finished_product_movements(uuid)` con `produccion.read`. No modifica Producción ni Laboratorio, no carga EMPAQUEs históricos y no genera SALIDAS ni ISOL todavía. Puntos pendientes: permiso propio de Inventario, integración oficial de % CBD con Laboratorio, carga histórica y estructura ISOL.

## MPCF-035 — PRODUCT / ISOL V1

Estado local: PREPARADO; ejecución y validación funcional en PostgreSQL NO CONFIRMADAS. Requiere MPCF-033.

Agrega `product_isol_operations` y `product_isol_consolidation_inputs`, sin reemplazar las tablas ni el ledger de MOD-007. `dispatch_finished_product(jsonb)` registra salidas de despacho; `consolidate_finished_products(jsonb)` valida y bloquea cada COD, registra sus salidas, crea un ISOL y registra su entrada dentro de una sola llamada transaccional. El código operacional se genera como `ISOL DDDYY` (día juliano y dos últimos dígitos del año de creación; p. ej. `ISOL 04126`); el UUID permanece solo como identidad técnica interna. Se permite un ISOL por organización y fecha, con rechazo explícito de otra consolidación ese mismo día. `get_product_isol_consolidation(uuid)` consulta las cantidades COD → ISOL. Se reutilizan `produccion.read` y `produccion.write`, se revoca acceso directo a las tablas y cada operación queda ligada a usuario, fecha, referencia y clave UUID idempotente. No se añaden atributos calculados al ISOL ni se modifican Producción, Laboratorio, Ventas o Genealogía. Los RPC requieren exposición manual y controlada en la Data API después de la revisión y ejecución.

## MPCF-036 — MOD-011 SALES V1

Estado local: PREPARADO; ejecución y validación funcional en PostgreSQL NO CONFIRMADAS. Requiere MPCF-035 para vincular las operaciones y movimientos reales de despacho.

No se encontró un catálogo reutilizable de clientes ni pedidos de venta; crea únicamente `sales_customers` y `sales_orders`. Incluye RPC para registrar/consultar clientes y pedidos, aplicar transiciones de estado, consultar salidas completas disponibles y vincular una operación de despacho existente a un pedido. Reutiliza los permisos autorizados `ventas.read` y `ventas.write` sin asignarlos ni crear usuarios o roles. La venta no selecciona COD/ISOL ni escribe en `finished_products` o `finished_product_movements`; la vinculación conserva el ID de operación de Producto / ISOL, producto atendido e ID del movimiento de Inventario. Solo se admite g/kg y el despacho asociado debe igualar la cantidad total solicitada. Los RPC deben exponerse manualmente en la Data API luego de revisar y ejecutar la migración.
