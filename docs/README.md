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
