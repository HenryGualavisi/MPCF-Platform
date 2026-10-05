# Documentación MPCF

## Arquitectura real aplicada

El flujo operativo actual del proyecto se puede resumir así:

Browser
↓
Supabase Auth
↓
context RPC / Data API
↓
PostgreSQL + RLS
↓
Realtime

## Separación de capas

### UI
- interfaz web operativa para usuarios
- identidad TRAZIX HG
- presentación del flujo industrial y trazabilidad

### Aplicación
- cliente web publicado en GitHub Pages
- integración con Supabase Auth y llamadas a la API de datos
- consumo de contexto del usuario via RPC

### Datos
- PostgreSQL como motor principal
- datos operativos reales y registros de trazabilidad
- tablas operativas expuestas de forma controlada por Data API

### Seguridad
- Supabase Auth real
- PostgreSQL RLS activo
- backend y base de datos como capa de protección crítica
- no se usa ocultamiento de botones como seguridad
- no se exponen secretos ni service role en frontend

### Trazabilidad
- relaciones y eventos diferenciados
- Codificación de procesos y material con evidencia documental
- trazabilidad por recepción, disponibilidad, consumo, producción e ISOL
- no se inventan genealogías sin evidencia

### Evidencia
- documentos, imágenes, comprobantes y referencias documentales asociados al material y al proceso
- preservación de REF-EXT / código externo
- trazabilidad de Big Bags, recepciones y proveedores

### Auditoría
- migraciones versionadas
- decisiones operativas documentadas
- trazabilidad histórica y reconciliación documental
- estado de relaciones confirmadas, inferidas y pendientes

## Estado documental actual

El proyecto está operativo en construcción con:
- Supabase real
- Auth real
- RLS
- Data API manualmente controlada
- Realtime
- dashboard conectado a datos reales
- trazabilidad demostrada con casos reales del dominio
- RPC de contexto del usuario validada

### Data API real
- HABILITADO
- Schemas: 2 de 3 expuestos
- `public`: expuesto
- `private`: no expuesto
- `Automatically expose new tables`: DESACTIVADO
- Tablas expuestas: `16 de 24`
- Funciones expuestas: `1 de 6`
- Función expuesta: `public.get_current_user_context`

### Dashboard validado
Prueba confirmada:
- Lotes agrícolas: 1
- Recepciones: 2
- Producciones: 2
- Productos / ISOL: 1

### Autenticación confirmada
- Login real probado
- Logout probado
- Usuario administrativo real: TRAZIX HG / SUPERADMIN
- Contexto recuperado por RPC y no por consultas directas a `profiles`, `user_roles`, `organizations` ni `roles` desde el frontend

### Caso real documentado
P19 → L2 → MERLOT → PILVICSA → cosecha 11-02-2026 → 626 kg biomasa fresca → recepción REC-20260211-001 → COD054 → 626 kg consumidos → 7.670 kg aislado → pureza 99.9% → ISOL 04126.

No se presenta como producto empresarial cerrado ni como demo final sin validación real.

## MPCF-035 — Producto / ISOL V1

Estado del repositorio: PREPARADO; ejecución en Supabase y validación funcional real NO CONFIRMADAS. Requiere MPCF-033 (MOD-007). La interfaz de Productos / ISOL consulta existencias mediante `get_finished_product_inventory()` y no mantiene un saldo independiente ni utiliza los registros de demostración.

Alcance funcional:
- `dispatch_finished_product(jsonb)` registra un despacho como movimiento `SALIDA` en `finished_product_movements`.
- `consolidate_finished_products(jsonb)` descuenta los COD seleccionados, registra sus cantidades de origen y crea un ISOL con movimiento `ENTRADA`, como una sola transacción.
- `get_product_isol_consolidation(uuid)` expone el vínculo operativo ISOL → COD y las cantidades utilizadas.
- Los RPC reutilizan `produccion.read` / `produccion.write`; las tablas nuevas no conceden acceso de escritura al navegador.
- Idempotencia por clave UUID de solicitud, bloqueo concurrente de existencias, validación de cantidades y registro de usuario/fecha/referencia.
- El código operacional de un nuevo ISOL sigue `ISOL DDDYY` (día juliano de creación y dos últimos dígitos del año); por ejemplo, `ISOL 04126`. El UUID se conserva únicamente como identidad técnica interna.
- Se permite un ISOL por organización y fecha de creación; una segunda consolidación diaria se rechaza explícitamente para evitar códigos duplicados.

`product_isol_operations` y `product_isol_consolidation_inputs` registran las operaciones y su relación COD → ISOL. Los saldos siguen derivados exclusivamente de los movimientos MOD-007. No se crea módulo de Ventas, recomendación ni genealogía paralela. Después de revisar y ejecutar la migración, los tres RPC nuevos deberán exponerse manualmente en la Data API, de acuerdo con la configuración existente.

## MPCF-036 — MOD-011 Ventas V1

Estado del repositorio: PREPARADO; ejecución y validación en Supabase NO CONFIRMADAS. Requiere las estructuras de despacho de MPCF-035. No se encontró un catálogo de clientes ni una estructura de pedidos reutilizable; MPCF-036 agrega únicamente `sales_customers` y `sales_orders`.

Ventas registra cliente, producto solicitado, cantidad en g/kg, requisitos, observaciones y estado comercial. Cada pedido es independiente y parte como `PEDIDO REGISTRADO`; las transiciones son `EN PREPARACIÓN` → `LISTO PARA DESPACHO` → `DESPACHADO` → `CERRADO`. Operaciones registra explícitamente el producto y la cantidad preparada; el backend asigna responsables autenticados y timestamps. La preparación debe cubrir la cantidad solicitada; el EXCESO se calcula y conserva en el pedido.

La operación de inventario permanece en Producto / ISOL. Ventas asocia un despacho existente del mismo producto preparado que completa la cantidad total del pedido y conserva referencias al producto, operación y movimiento de Inventario. No reserva, recomienda, crea COD/ISOL ni escribe en las tablas MOD-007. Si la preparación excede el pedido, el saldo remanente ya acreditado en MOD-007 es el EXCESO; no se crea una entrada duplicada. No se permiten despachos parciales ni edición posterior al cierre. RPC protegidas con `ventas.read` y `ventas.write`; dichos permisos quedan requeridos y no se asignan automáticamente. Las funciones deberán exponerse manualmente en la Data API tras la revisión y ejecución de la migración.
