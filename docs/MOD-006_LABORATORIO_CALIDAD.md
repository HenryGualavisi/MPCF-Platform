# MOD-006 — LABORATORIO / CALIDAD

Fuente maestra funcional del módulo. Describe el estado funcional VIGENTE (según repositorio) de Laboratorio. No define una nueva versión del módulo.

> Convención de estados (AGENTS.md §11.8): DISEÑADO / PREPARADO / VERSIONADO / EJECUTADO / VALIDADO.
> Todo lo descrito aquí como SQL está **VERSIONADO en GitHub (sin commit al momento de esta consolidación)**. **No existe evidencia de ejecución en Supabase** para MPCF-029, MPCF-030 ni MPCF-031: ejecución **NO CONFIRMADA**. Validación funcional real en Supabase: **PENDIENTE**.

## Índice

1. Identidad del módulo
2. Objetivo
3. Alcance
4. Relación con Producción
5. Flujo completo de Laboratorio
6. Apertura y temporalidad de análisis
7. Muestras
8. Ensayos
9. Resultados
10. Atributos analíticos
11. Estados
12. Reglas de validación
13. LFW
14. composition_code
15. Reglas de múltiples proveedores
16. Reglas de kg consumidos
17. Cierre operativo
18. Reglas de histórico
19. Realtime
20. Permisos
21. RLS
22. Trazabilidad
23. Reglas que NO deben modificarse
24. Relación con CP14
25. Relación con CP15
26. Migraciones técnicas asociadas
27. Pruebas validadas
28. Estado actual
29. Pendientes
30. Decisiones funcionales vigentes
31. Anexo — Conflictos / pendientes de validación

---

## 1. Identidad del módulo

- Código: **MOD-006**
- Nombre: Laboratorio / Calidad
- Plataforma: MPCF Platform by TRAZIX HG
- Es UN solo módulo funcional. MPCF-029, MPCF-030 y MPCF-031 son evoluciones técnicas acumulativas del mismo módulo.

## 2. Objetivo

Registrar muestras, ensayos y resultados analíticos asociados a una producción (COD) y a sus etapas, conservando trazabilidad y evidencia, y exponer los atributos analíticos a Producción en solo lectura.

## 3. Alcance

Incluye: muestras BIOMASS, RESIDUE, EXTRACTION, STAGE_OUTPUT (DECARBOXILACION / EMPAQUE); ensayos; resultados; estados; LFW; composition_code; cierre operativo; histórico; Realtime de lectura; permisos y RLS.

No incluye (no definido en las fuentes): método analítico (explícitamente NO se introduce "Método"), evidencia documental adjunta específica de Laboratorio (**PENDIENTE DE DEFINICIÓN**, ver §29).

## 4. Relación con Producción

- Laboratorio se apoya en `production_orders` (COD, fecha, turno), `production_process_events` (etapas EXTRACCION, DECARBOXILACION, EMPAQUE con `stage_status` ACTIVA/COMPLETADA), `production_inputs`, `big_bags` y `biomass_receptions`.
- Producción solo LEE atributos analíticos (RPC `get_production_laboratory_attributes`, panel "ATRIBUTOS ANALÍTICOS · SOLO LECTURA"). No los edita.
- Resultados pendientes de Laboratorio NO bloquean Producción.
- Producción COMPLETADA ≠ Laboratorio completado (ver §18).
- COD identifica una producción/proceso; ISOL identifica un lote de aislado; no se confunden.

## 5. Flujo completo de Laboratorio

PENDIENTE → MUESTRA TOMADA → EN ANÁLISIS → RESULTADO REGISTRADO → VALIDADO → CERRADA OPERATIVAMENTE (histórico).

"Cerrada operativamente" no elimina el registro.

## 6. Apertura y temporalidad de análisis

- Una muestra solo puede existir si la etapa de producción asociada existe en la misma producción con `stage_status` ACTIVA o COMPLETADA (trigger `private.validate_laboratory_record_context`).
- Tipo de muestra ↔ etapa: BIOMASS, RESIDUE y EXTRACTION → evento EXTRACCION; STAGE_OUTPUT → DECARBOXILACION o EMPAQUE.
- Una muestra BIOMASS requiere consumo real del proveedor/lote en esa orden (validado por el trigger).
- Los análisis aparecen a medida que Producción activa/completa etapas; no hay apertura previa a la etapa.

## 7. Muestras

Tabla `laboratory_samples`. Tipos: BIOMASS, RESIDUE, EXTRACTION, STAGE_OUTPUT.
- BIOMASS: una por orden + evento + proveedor + lote agrícola (índice único por origen).
- RESIDUE / EXTRACTION / STAGE_OUTPUT: una por salida/etapa (índice único).
- Código de muestra BIOMASS: `{código de ensayo}-{supplier_code}`.
- La creación es idempotente (`create_laboratory_sample`, `on conflict`): no duplica.

## 8. Ensayos

Tabla `laboratory_tests`, relación 1:1 con la muestra. Código `COD{cod:02}{BIO|RES|EXT|DEC|EMP}`.

## 9. Resultados

Tabla `laboratory_results`, única por (test, sample, attribute). Unidad `%`, rango 0–100. `save_laboratory_result` hace upsert (actualizar no duplica) y lleva la muestra a EN ANÁLISIS.

## 10. Atributos analíticos

Nombres CP14 (no se cambian):

| Tipo de muestra | Atributos |
|---|---|
| BIOMASS | CBDA, CBD, MOISTURE_BIOMASS |
| RESIDUE | CBDA, CBD, MOISTURE_RESIDUE |
| EXTRACTION | CBDA_EXTRACTION, CBD_EXTRACTION |
| STAGE_OUTPUT · DECARBOXILACION | CBDA_DECARBOXYLATION, CBD_DECARBOXYLATION |
| STAGE_OUTPUT · EMPAQUE | CBD_PACKING |

(Los códigos exactos por tipo están definidos en MPCF-029; ver conflicto C-10 sobre verificación textual.)

## 11. Estados

PENDIENTE, MUESTRA TOMADA, EN ANÁLISIS, RESULTADO REGISTRADO, VALIDADO. Estados de etapa de Producción usados como contexto: ACTIVA, COMPLETADA.

## 12. Reglas de validación

- Resultados esperados para pasar a RESULTADO REGISTRADO / VALIDADO: BIOMASS 3, RESIDUE 3, EXTRACTION 2, DECARBOXILACION 2, EMPAQUE 1.
- Validación de contexto por trigger (§6).
- Cambios de estado vía `set_laboratory_sample_status`.
- Una muestra VALIDADO no admite nueva captura, nueva validación, reapertura, modificación ni borrado (§17).

## 13. LFW

`private.get_laboratory_lfw`:
- Ponderado por kg realmente consumidos (`production_inputs` → `big_bags` → `biomass_receptions`), agrupados por proveedor + lote agrícola.
- Usa solo muestras BIOMASS en estado RESULTADO REGISTRADO o VALIDADO.
- Valor = Σ(kg cubiertos × valor) / Σ(kg cubiertos), redondeado a 2 decimales.
- Estado: `RESULTADO REGISTRADO` si cobertura = total (±0.001 kg); si no, `PARCIAL`.
- Fórmula LFW: NO modificable.

## 14. composition_code

Definido en `get_laboratory_lfw`. La versión de MPCF-029 es reemplazada por MPCF-030:
- Proveedor único → nombre normalizado (sin prefijo `M_` ni porcentaje).
- Múltiples proveedores → `M_<NOMBRE>_<%>_...`, porcentajes enteros por método de mayor resto sumando 100, ordenados por nombre. Ejemplo: `M_ECUACANNABIS_79_HEOMGROUP_21` (626 / 165 kg).
- MPCF-030 solo corrige `composition_code`; no cambia la fórmula LFW.

## 15. Reglas de múltiples proveedores

- Una producción puede consumir de varios proveedores/lotes; se genera una muestra BIOMASS por combinación proveedor + lote.
- Una combinación VALIDADO permanece histórica y no se vuelve a solicitar.
- Una nueva combinación solo habilita la nueva muestra.
- El LFW combina todas las muestras BIOMASS registradas/validadas.
- Caso de referencia (COD119): HEOMGROUP 85 kg validada; luego ECUACANNABIS 500 kg → solo se solicita la nueva muestra; el LFW incorpora ambas. (Caso usado como ejemplo funcional; no hay evidencia de ejecución real en Supabase.)

## 16. Reglas de kg consumidos

Los pesos del LFW y de los porcentajes de composición provienen de kg efectivamente consumidos (`production_inputs`), no de peso declarado ni de recepción. Un Big Bag puede consumirse parcialmente y participar en varias producciones.

## 17. Cierre operativo

Implementado en MPCF-029 (modificación CP14):
- Función `private.guard_laboratory_operational_closure()` y triggers `laboratory_samples_operational_closure` (before update/delete) y `laboratory_results_operational_closure` (before insert/update/delete).
- Guardas "VALIDADO está cerrada operativamente" en `save_laboratory_result` y `set_laboratory_sample_status`.
- UI: no muestra captura ni validación para muestras VALIDADO ("Muestra cerrada operativamente"); `saveLaboratoryResults` y `setLaboratoryStatus` bloquean.
- No se elimina el registro.

## 18. Reglas de histórico

- Muestras y resultados VALIDADO permanecen almacenados y consultables.
- MPCF-031: un COD se considera **Laboratorio completado** cuando existe muestra STAGE_OUTPUT en estado VALIDADO del evento EMPAQUE de esa orden (`private.is_laboratory_order_completed`).
- Un COD completado pasa a HISTÓRICO y es solo lectura: triggers `prevent_laboratory_completed_order_mutations` sobre samples y results ("completed laboratory order is read-only").
- `get_laboratory_orders` devuelve `laboratory_completed` y `laboratory_completed_at` (= `updated_at` de la muestra).
- UI: listas OPERATIVOS / HISTÓRICO; histórico limitado a los 7 más recientes (`.slice(0,7)`), ordenado por `laboratory_completed_at` desc, luego fecha, luego COD. Este límite y orden son SOLO de presentación (frontend); la RPC devuelve todos.

## 19. Realtime

- MPCF-031 añade `laboratory_samples`, `laboratory_tests` y `laboratory_results` a `supabase_realtime` (con verificación de existencia; sin REPLICA IDENTITY).
- Las tablas de producción/consumo ya estaban publicadas por MPCF-016.
- Frontend: canal `laboratory-{org}` con postgres_changes sobre 9 tablas (production_inputs, production_orders, production_process_events, biomass_receptions, big_bags, organizations, laboratory_samples, laboratory_tests, laboratory_results); refresco con debounce 250 ms; se detiene al salir del módulo y en login.
- Requisito técnico: Postgres Changes necesita `GRANT SELECT`; MPCF-029 hacía `REVOKE ALL`. MPCF-031 concede `SELECT` a `authenticated` sobre las 3 tablas (decisión autorizada explícitamente por el usuario), protegido por RLS.

## 20. Permisos

- `laboratorio.read`, `laboratorio.write` (reutilizados), `produccion.read` (solo lectura de atributos).
- Lectura: laboratorio.read OR produccion.read. Escritura: laboratorio.write. Evaluados con `private.current_user_has_permission`.
- Los permisos NO se modifican.
- RPC públicas: `get_laboratory_orders`, `get_laboratory_order_context`, `create_laboratory_sample`, `save_laboratory_result`, `set_laboratory_sample_status`, `get_production_laboratory_attributes`. Su exposición en Data API es manual (no automática).

## 21. RLS

- RLS activa en laboratory_samples/tests/results, por `organization_id`; políticas read y write según §20.
- MPCF-029: `REVOKE ALL` a public/anon/authenticated. MPCF-031: `GRANT SELECT` a authenticated (RLS sigue filtrando).
- La seguridad no depende del frontend; los botones ocultos no son seguridad.

## 22. Trazabilidad

- Muestra → ensayo → resultados, ligados a orden de producción, evento de etapa y (BIOMASS) proveedor + lote agrícola.
- El LFW se reconstruye desde consumo real hacia Big Bag y recepción.
- Estados y cambios con fecha/hora (`updated_at`). Evidencia documental específica de Laboratorio: no definida (§29).
- No se inventa genealogía; las brechas se muestran como PARCIAL / pendientes.

## 23. Reglas que NO deben modificarse

- Fórmula LFW.
- Nombres de atributos CP14.
- Modelo laboratory_samples / laboratory_tests / laboratory_results.
- Permisos laboratorio.read / laboratorio.write y RLS.
- Producción solo lectura de atributos analíticos.
- No introducir "Método".
- No eliminar muestras VALIDADO.
- No crear lógica independiente por pantalla/tipo de muestra.
- No modificar SQL ejecutado; todo cambio estructural va en migración MPCF nueva.

## 24. Relación con CP14

CP14 define el modelo de Laboratorio (MPCF-029), la corrección horizontal de cierre operativo (§17) y la corrección de `composition_code` (MPCF-030, tratada en CP15 como parte funcional de CP14; ver C-4).

## 25. Relación con CP15

CP15 añade Realtime e histórico por COD completado (MPCF-031, §18–19), sin cambiar LFW, composition_code, permisos ni RLS.

## 26. Migraciones técnicas asociadas

Ubicación: `database/migrations/` (sin moverlas).

| Migración | Aporta | Estado |
|---|---|---|
| MPCF-029_LABORATORY_QUALITY_V1 | Tablas, RLS, validación de contexto, RPCs, LFW, cierre operativo | VERSIONADO; ejecución NO CONFIRMADA |
| MPCF-030_LABORATORY_COMPOSITION_CODE_FIX_V1 | Corrección de `composition_code` en `get_laboratory_lfw` | VERSIONADO; ejecución NO CONFIRMADA |
| MPCF-031_LABORATORY_REALTIME_HISTORY_V1 | Publicación Realtime, completado por EMPAQUE, solo lectura, `get_laboratory_orders` extendida, GRANT SELECT | VERSIONADO; ejecución NO CONFIRMADA |

Orden de aplicación esperado: 029 → 030 → 031. Cada una debe validarse antes de la siguiente (trabajo incremental).

## 27. Pruebas validadas

Solo pruebas locales (estáticas/unitarias, `node --test`), no pruebas funcionales en Supabase:
- `tests/test_laboratory_operational_closure.js` (CP14)
- `tests/test_mpcf_030_composition_code.js` (MPCF-030)
- `tests/test_cp15_laboratory_realtime_history.js` (CP15)
- Última ejecución registrada: 13 tests pasan; sintaxis JS inline OK; `git diff --check` limpio.

Estado: pruebas locales PASAN; **VALIDADO funcionalmente en Supabase: NO**.

## 28. Estado actual

| Componente | Estado |
|---|---|
| Modelo CP14 (MPCF-029) | VERSIONADO; ejecución NO CONFIRMADA |
| Corrección composition_code (MPCF-030) | VERSIONADO; ejecución NO CONFIRMADA |
| Realtime/histórico (MPCF-031) | VERSIONADO; ejecución NO CONFIRMADA |
| UI Laboratorio en `index.html` | Código presente; depende de las migraciones (muestra "Requiere MPCF-031" si falta) |
| Exposición de RPC en Data API | NO CONFIRMADA |
| Validación real en Supabase | PENDIENTE |

## 29. Pendientes

- Ejecutar y validar en Supabase MPCF-029, luego 030, luego 031.
- Exponer en Data API las RPC de Laboratorio y confirmar `EXECUTE` (§Anexo C-2).
- Validar escenarios reales: un proveedor; dos proveedores (A validado, B pendiente); actualización sin duplicado; Producción solo lectura; LFW; Realtime; histórico de 7.
- Definir evidencia documental propia de Laboratorio (no definida).
- Definir si el límite/orden del histórico debe vivir en backend (hoy solo frontend).
- Definir si `laboratory_tests` debe quedar bloqueada en COD completado (hoy el trigger no la cubre).
- Mostrar nombre de proveedor en lugar de UUID en tarjetas de muestra (UI actual muestra UUID).
- Actualizar AGENTS.md §11.1 (lista migraciones solo hasta MPCF-020).

## 30. Decisiones funcionales vigentes

1. Muestra VALIDADO = histórica, cerrada operativamente, no eliminada.
2. Nueva combinación proveedor/lote → solo nueva muestra.
3. LFW usa muestras BIOMASS registradas/validadas ponderadas por kg consumidos; fórmula intocable.
4. composition_code según MPCF-030.
5. COD completado (EMPAQUE VALIDADO) → histórico solo lectura.
6. Producción solo lee atributos analíticos; no se bloquea por resultados pendientes.
7. Realtime vía Postgres Changes con SELECT protegido por RLS (autorizado por el usuario).
8. No se introduce "Método".
9. Permisos sin cambios.

---

## 31. Anexo — Conflictos / pendientes de validación

Registrados sin resolver:

- **C-1 — Estado de CP14.** El usuario indicó "CP14 ya implementado y probado"; el repositorio solo evidencia SQL versionado (cabecera de MPCF-029: "PREPARED - NOT EXECUTED") y ejecución NO CONFIRMADA. CONFLICTO / PENDIENTE DE VALIDACIÓN.
- **C-2 — RPC y GRANT EXECUTE en MPCF-031.** `database/README.md` habla de seis RPC a exponer; MPCF-031 reemplaza `get_laboratory_orders` sin nuevo GRANT EXECUTE; se asume conservado por `create or replace` (no verificado).
- **C-3 — MPCF-029 modificado tras documentarse como preparado.** El mismo archivo fue editado en CP14 (cierre operativo) sin nueva versión. Si alguien ya lo ejecutó antes, el contenido ejecutado podría diferir del archivo actual. PENDIENTE DE VALIDACIÓN.
- **C-4 — MPCF-030 como parte de CP14.** El prompt CP15 lo trata como parte funcional de CP14; en el repo figura como archivo sin commit y sin ejecución confirmada.
- **C-5 — Regla de 7 COD.** Solo presentación (frontend); el criterio de CP15 permitía backend o frontend.
- **C-6 — Cobertura del bloqueo de solo lectura.** El trigger de MPCF-031 cubre samples y results, no tests; `create_laboratory_sample` y `get_laboratory_order_context` no excluyen explícitamente COD completados salvo por los triggers.
- **C-7 — GRANT SELECT vs. documentación previa.** `database/migrations/README.md` (sección MPCF-029) afirma que las tablas nuevas no se exponen directamente al navegador; MPCF-031 concede SELECT a authenticated (autorizado). La afirmación previa no fue actualizada.
- **C-8 — AGENTS.md §11.1** solo lista migraciones hasta MPCF-020.
- **C-9 — Proveedor mostrado por UUID** en tarjetas de muestra de la UI, frente a la regla de no usar identificadores técnicos como identidad visible.
- **C-10 — Códigos de atributo exactos.** La tabla de §10 resume los atributos desde evidencia previa de la sesión; los códigos textuales definitivos son los de MPCF-029 y deben verificarse contra el SQL antes de usarse como contrato.
