# MPCF Platform by TRAZIX HG — Manual Maestro de Ingeniería

## 1. Propósito del documento

Este archivo define las reglas, principios, arquitectura y decisiones de trabajo del proyecto MPCF Platform by TRAZIX HG.

Su objetivo es servir como manual maestro para que futuros agentes de ingeniería trabajen de forma consistente, segura y alineada con la estrategia operacional del negocio.

Este repositorio no es un CRUD genérico. Es una plataforma orientada a trazabilidad industrial y operaciones, con énfasis en:
- integridad de datos
- evidencia documental
- seguridad por backend
- trazabilidad basada en relaciones y eventos
- operación real y no solo demostración

---

## 2. Identidad del proyecto

- Nombre visible: TRAZIX HG
- Plataforma: MPCF Platform
- Descripción: Industrial Traceability Platform / Traceability & Operations
- Objetivo: centralizar procesos, datos, trazabilidad, evidencia, seguridad, auditoría y análisis

La plataforma debe evolucionar progresivamente hacia el sistema operativo central de la empresa.

---

## 3. Objetivo funcional operativo

La arquitectura debe permitir el flujo industrial:

Cultivo
→ Recepción
→ Big Bag
→ Disponibilidad
→ Consumo
→ Producción
→ ISOL
→ Despacho

Este flujo debe interpretarse como una secuencia de eventos y relaciones, no como una concatenación de textos.

---

## 4. Principios fundamentales

### 4.1 Trazabilidad basada en relaciones y eventos
La trazabilidad debe modelarse como relaciones y eventos, no únicamente como strings concatenados.

Cada hecho debe ser representable como:
- entidad
- evento
- relación
- evidencia
- estado de relación
- fecha/hora
- actor / origen
- documento asociado

### 4.2 No inventar genealogía
No se deben inventar relaciones de genealogía que no estén sustentadas por evidencia o proceso real.

Cuando la relación no esté confirmada:
- se debe marcar como INFERIDO o PENDIENTE
- no debe asumirse como verdad operacional definitiva

### 4.3 Evidencia documental
Toda relación o evento relevante debe poder conservar evidencia documental.

Esto incluye:
- imágenes
- documentos
- comprobantes
- certificados
- actas
- registros de laboratorio
- evidencias de recepción, consumo, despacho y producción

### 4.4 Estados de relación
Las relaciones pueden tener estado:
- CONFIRMADO
- INFERIDO
- PENDIENTE

Esto debe aplicarse en cualquier relación donde exista incertidumbre operacional o documental.

### 4.5 REF-EXT / Código externo
REF-EXT / CÓDIGO EXTERNO es un identificador crítico y debe preservarse exactamente como fue recibido.

Reglas:
- no reemplazarlo por una interpretación arbitraria
- no truncarlo
- no normalizarlo si eso destruye el valor original
- permitir una interpretación auxiliar adicional si procede
- conservar el valor original en paralelo

### 4.6 Big Bag
Big Bag es una unidad física de trazabilidad.

Debe conservar:
- código
- referencia externa
- proveedor
- peso declarado
- peso verificado
- evidencia
- estado
- relación con recepción
- relaciones de consumo

Un Big Bag puede consumirse parcialmente y participar en múltiples producciones.

### 4.7 Diferenciar eventos
Recepción, disponibilidad, consumo, transformación, producción, ISOL y despacho son eventos diferentes.

No deben mezclarse ni reemplazarse unos por otros.

### 4.8 Identidad histórica
Debe preservarse la identidad histórica de los datos.

Esto incluye:
- identificadores operacionales visibles
- referencias externas
- aliases históricos
- cambios de estado
- notas de reconciliación

### 4.9 Identificadores auxiliares y referencias externas
Debe mantenerse la identidad interna técnica y las referencias externas asociadas.

Los proveedores pueden tener:
- identidad interna estable
- alias / nombre comercial
- referencias históricas
- relaciones múltiples en distintos periodos

### 4.10 Seguridad no depende del frontend
La seguridad no debe depender solamente del frontend.

Todo lo crítico debe estar protegido en backend/base de datos.

### 4.11 PostgreSQL/RLS forma parte de la arquitectura
PostgreSQL y RLS son parte fundamental de la seguridad.

Regla estricta:
- las reglas críticas deben estar en backend/base de datos
- el frontend no debe contener claves secretas ni service-role

### 4.12 Migraciones versionadas
Las migraciones SQL deben ser versionadas y trazables.

- cada cambio de esquema debe ser migración
- cada migración debe llevar identificador secuencial MPCF
- cada migración debe documentarse
- no se deben hacer cambios destructivos sin autorización explícita

### 4.13 Documentación de cambios importantes
Los cambios importantes deben quedar documentados.

Esto incluye:
- decisiones de negocio
- cambios de modelo
- cambios de seguridad
- cambios de trazabilidad
- cambios en reglas de integridad

### 4.14 Evidencia documental y trazabilidad
La evidencia documental es parte de la trazabilidad.

No se puede separar la historia real del material de sus documentos asociados.

### 4.15 Mostrar brechas, no inventar información
El sistema debe mostrar brechas de trazabilidad en lugar de inventar información.

Cuando falte una relación, debe marcarse como incompleta o pendiente.

---

## 5. Arquitectura conocida

### 5.1 Frontend
- Aplicación web
- Interfaz operativa y visual para usuarios
- Debe mantener identidad TRAZIX HG
- Debe operar sobre datos reales, no solo demo

### 5.2 Backend
- Supabase

### 5.3 Base de datos
- PostgreSQL

### 5.4 Seguridad
- Supabase Auth
- PostgreSQL RLS

### 5.5 Tiempo real
- Supabase Realtime

### 5.6 Restricción crítica
El frontend nunca debe contener claves secretas ni service-role.

---

## 6. Identidad técnica y operativa

### 6.1 Identidad técnica interna
El sistema usa UUID como identidad técnica interna.

### 6.2 Identidad operacional visible
Los identificadores operacionales visibles pueden seguir reglas propias del proceso.

Ejemplos:
- COD
- ISOL
- lote
- recepciones
- big bag
- producción

### 6.3 Diferencia entre COD e ISOL
- COD identifica una producción/proceso operacional
- ISOL identifica un lote de aislado

No deben confundirse.

### 6.4 Identidad operacional de producción
La identidad operacional de producción puede depender de:
- fecha
- turno
- COD

Ejemplo conceptual:
- fecha + turno + COD

---

## 7. Trazabilidad del dominio

### 7.1 Objetivo principal
El objetivo principal de trazabilidad es poder recorrer:

ISOL
→ producción
→ materiales consumidos
→ recepción
→ Big Bags
→ lote agrícola
→ cosecha
→ proveedor/origen

### 7.2 Relaciones reales
La relación puede ser N:1 o 1:N según el proceso real.

Esto implica que:
- no se asume un único proveedor por producción
- una producción puede recibir material de múltiples proveedores
- un Big Bag puede consumirse parcialmente
- un Big Bag puede participar en múltiples producciones

### 7.3 Regla de evidencia y precisión
La información debe mantenerse con precisión operativa y evidencia documental.

No se debe convertir una hipótesis en hecho solo porque visualmente parece coherente.

---

## 8. Proveedores y referencias externas

### 8.1 Entidad de proveedor
Los proveedores son entidades externas.

Ejemplos actuales:
- ECUACANNABIS
- NEW LIFE
- PILVICSA
- CANNANGOLD
- HEOMGROUP

### 8.2 Reglas
- no usar nombres truncados como identidad principal
- debe existir una identidad interna estable
- si corresponde, usar aliases o referencias históricas
- mantener la referencia externa histórica sin perder trazabilidad

---

## 9. Recepción y Big Bag

### 9.1 Recepción
La recepción representa el evento físico de ingreso de biomasa.

Debe distinguirse:
- peso declarado
- peso verificado
- disponibilidad
- consumo

### 9.2 Big Bag
Big Bag es una unidad física de trazabilidad.

Debe conservar:
- código
- referencia externa
- proveedor
- peso declarado
- peso verificado
- evidencia documental
- estado
- relación con recepción
- relaciones de consumo

### 9.3 Regla operativa útil
Un Big Bag puede consumirse parcialmente.

Esto debe soportarse sin destruir la identidad del Big Bag original.

---

## 10. REF-EXT

REF-EXT / CODIGO EXTERNO debe preservarse exactamente como fue recibido.

Reglas:
- almacenar el valor original
- no reinterpretar la referencia para construir una identidad principal si eso destruye el origen
- si existe una interpretación estructurada adicional, usarla como capa complementaria
- mantener ambos valores si son distintos

---

## 11. Migraciones SQL

### 11.1 Estado real verificado al 13-09-2026
Las migraciones deben usar identificadores secuenciales MPCF.

Matriz real del proyecto:
- MPCF-001 — Ejecutada online
- MPCF-002 — Ejecutada online
- MPCF-003 — Ejecutada online
- MPCF-004 — Ejecutada online
- MPCF-005 — Ejecutada online
- MPCF-006 — Ejecutada online
- MPCF-007 — Ejecutada online
- MPCF-008 — Ejecutada online
- MPCF-009 — Ejecutada online
- MPCF-010 — Ejecutada online
- MPCF-011 — Ejecutada online
- MPCF-012 — Ejecutada online
- MPCF-013 — Ejecutada online
- MPCF-014 — Ejecutada online
- MPCF-015 — Ejecutada online
- MPCF-016 — Ejecutada online + SQL físico en repo (`MPCF-016_REALTIME_CORE_V1.sql`)
- MPCF-017 — Ejecutada online
- MPCF-018 — Ejecutada online + SQL físico en repo (`MPCF-018_PROVIDER_MASTER_V1.sql`)
- MPCF-019 — SQL físico en repo (`MPCF-019_RECEIPTION_TRANSACTION_V1.sql`); ejecución NO CONFIRMADA en este corte
- MPCF-020 — Ejecutada online + SQL físico en repo + validación funcional (`MPCF-020_USER_CONTEXT_RPC_V1.sql`)

### 11.2 Estado real de MPCF-020
MPCF-020 USER_CONTEXT_RPC_V1

Estado:
- EJECUTADA Y VALIDADA

RPC:
- `public.get_current_user_context()`

Función:
- devuelve `user_id`, `full_name`, `organization_id`, `organization_name`, `organization_code` y `roles`
- usa `SECURITY DEFINER`
- usa `auth.uid()`
- no recibe `user_id` externo
- `EXECUTE` para `authenticated`
- `anon` revocado
- tablas sensibles de identidad no expuestas directamente al frontend

Resultado funcional confirmado:
- el frontend publicado muestra correctamente `TRAZIX HG` y `SUPERADMIN`

### 11.3 Estado real de la Data API
Data API:
- HABILITADO

Schemas:
- `public`: EXPUESTO
- `private`: NO EXPUESTO
- `Automatically expose new tables`: DESACTIVADO
- Tablas expuestas: 16 de 24
- Funciones expuestas: 1 de 6
- Función expuesta: `public.get_current_user_context`

### 11.4 Dashboard y autenticación
Dashboard:
- consulta datos reales desde Supabase
- validado: 1 lote agrícola, 2 recepciones, 2 producciones, 1 producto/ISOL

Autenticación:
- Supabase Auth real operativo
- Login real probado
- Logout probado
- Usuario administrativo real: TRAZIX HG / SUPERADMIN
- contexto recuperado mediante RPC
- el frontend no depende de consultas directas a `profiles`, `user_roles`, `organizations` ni `roles` para construir contexto del usuario

### 11.5 Caso real confirmado
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

La relación COD054 → ISOL04126 se documenta como relación técnica demostrada, no como reconstrucción completa de toda la genealogía histórica de ISOL04126.

### 11.6 Proveedores
Proveedor Master:
- ECUACANNABIS
- NEW LIFE
- PILVICSA
- CANNANGOLD
- HEOMGROUP

Clasificación: EXTERNO. La clasificación interna GRUPO/EXTERNO no debe mostrarse al proveedor.

### 11.7 Reglas de migración
- usar numeración secuencial
- mantener nombres claros y legibles
- documentar el propósito de cada migración
- no mezclar cambios de negocio con cambios operativos sin documentación
- mantener compatibilidad hacia atrás cuando aplique
- no ejecutar migraciones destructivas sin autorización explícita
- distinguir siempre entre ejecución en Supabase y SQL físico en GitHub
- no inventar SQL físicos ni marcar una migración como ejecutada sin evidencia
- trabajar con SQL versionado y trazable

### 11.8 Regla crítica de documentación
Nunca escribir “implementado” si solo está diseñado.
Nunca escribir “SQL disponible” si el archivo no existe físicamente.
Nunca escribir “migración ejecutada” si solo existe el archivo y no hay confirmación.

Los estados deben distinguirse siempre como:
- DISEÑADO
- PREPARADO
- VERSIONADO
- EJECUTADO
- VALIDADO

---

## 12. Regla de trabajo incremental

Se debe trabajar de manera incremental:

Módulo
→ datos reales
→ prueba real
→ validación
→ corrección
→ queda operativo
→ siguiente módulo

No se debe construir grandes volúmenes de funcionalidad sin validación real.

No reemplazar arquitectura existente sin justificarlo.

Antes de modificar una parte crítica, se debe inspeccionar:
- repositorio
- código existente
- dependencias
- estructura actual
- alcance real de la funcionalidad

---

## 13. Regla para decisiones no definidas

Cuando una decisión de negocio no esté definida, se debe señalarla explícitamente en lugar de inventarla.

Se debe priorizar:
- integridad
- evidencia
- trazabilidad
- claridad operativa

sobre conveniencia visual o rapidez de implementación.

---

## 14. Datos reales importantes

Existen casos reales relevantes que deben considerarse como referencia de validación y trazabilidad.

### Caso central
ISOL 04126
→ COD054
→ 626 kg consumidos
→ recepción REC-20260211-001
→ lote agrícola P19
→ lote L2
→ variedad MERLOT
→ proveedor/origen PILVICSA
→ cosecha 11-Feb-2026

Este caso debe considerarse un caso de prueba fundamental.

### Regla de reconciliación
Existe además trazabilidad histórica más amplia de ISOL 04126 que debe reconciliarse documentalmente.

La reconciliación debe hacerse con evidencia y no asumiendo relaciones sin soporte documental.

---

## 15. Reglas para el agente

### 15.1 Antes de implementar
Antes de implementar, el agente debe:
- inspeccionar el repositorio
- entender la arquitectura existente
- identificar dependencias
- verificar qué existe realmente
- no asumir que algo existe solo porque aparece en documentación
- no inventar tablas, columnas, APIs o relaciones
- no destruir funcionalidad existente

### 15.2 Para cambios de base de datos
- usar migraciones
- numerarlas
- documentarlas
- mantener compatibilidad
- no ejecutar migraciones destructivas sin autorización explícita

### 15.3 Para cambios de frontend
- preservar la identidad TRAZIX HG
- mantener la funcionalidad existente
- evitar introducir datos ficticios como si fueran reales
- separar claramente demo, datos reales y estados de prueba

### 15.4 Para trazabilidad
- priorizar integridad y evidencia sobre conveniencia visual
- modularizar y documentar la lógica de trazabilidad
- mantener relaciones explícitas y auditables

---

## 15.5 Regla estructural para Supabase/PostgreSQL
Ninguna modificación estructural de Supabase/PostgreSQL debe realizarse directamente como cambio manual.

Todo cambio estructural debe implementarse mediante una migración SQL MPCF versionada, revisable y trazable.

Esto incluye:
- creación o alteración de tablas
- cambios en columnas, índices, restricciones, enum y tipos
- alteraciones de políticas RLS
- cambios en funciones y triggers
- ajustes en relaciones y datos maestros críticos

La migración es el mecanismo oficial de evolución del esquema.

---

## 16. Principios de datos y seguridad

### 16.1 Los datos deben ser auditables
Todo cambio importante debe poder justificarse por:
- usuario
- fecha
- motivo
- evidencia

### 16.2 El sistema debe ser operativo, no solo demo
La solución debe prepararse para operación real, no solo para demostración.

### 16.3 No se debe ganar velocidad a costa de integridad
La velocidad de desarrollo no debe comprometer:
- trazabilidad
- evidencia
- seguridad
- auditoría
- calidad del dato

---

## 17. Política de trabajo recomendada para agentes futuros

### 17.1 Trabajo seguro
- leer antes de escribir
- entender antes de cambiar
- validar cambios incrementales
- evitar romper la funcionalidad actual

### 17.2 Trabajo con dominio industrial
- respetar el ciclo productivo real
- diferenciar eventos y estados
- no inventar relaciones ocultas
- mantener la trazabilidad verificable

### 17.3 Trabajo con base de datos
- schema versionado
- RLS y permisos por rol
- migraciones claras
- documentación precisa

---

## 18. Decisiones arquitectónicas que deben mantenerse

1. Supabase como backend principal.
2. PostgreSQL como base de datos principal.
3. RLS como columna vertebral de seguridad.
4. UUID como identidad técnica interna.
5. Relaciones y eventos sobre textos concatenados.
6. Preservación del valor REF-EXT original.
7. Big Bag como unidad física de trazabilidad.
8. Evidencia documental integrada a la trazabilidad.
9. Trazabilidad operativa con casos reales y no solo datos de demo.
10. Desarrollo incremental con validación real.

---

## 18.1 Fuentes de verdad del proyecto

- GitHub = código fuente oficial.
- Supabase/PostgreSQL = datos operacionales y backend.
- Migraciones MPCF = mecanismo oficial de evolución del esquema.
- AGENTS.md = reglas maestras de ingeniería.
- docs/ = documentación funcional, técnica y arquitectónica.

---

## 19. Resultado esperado para el proyecto

El proyecto debe avanzar hacia una plataforma que:
- mantenga trazabilidad industrial real
- apoye operaciones y auditoría
- proteja la integridad del dato
- soporte evidencia documental
- permita análisis y revisión de brechas
- esté preparado para despliegue operativo real

El sistema debe ser útil para operación y no solo para demostración visual.

---

## 20. Cierre

Este documento establece la línea base de ingeniería para MPCF Platform by TRAZIX HG.

Cualquier implementación futura debe cumplir con:
- integridad de dominio
- seguridad real
- trazabilidad basada en relaciones y eventos
- preservación de evidencia
- decisiones documentadas
- evolución incremental y verificable

Todo cambio que no cumpla estos principios debe ser revisado y corregido antes de incorporarse al proyecto.
