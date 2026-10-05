# Pruebas MPCF

Este directorio contendrá pruebas automatizadas y casos de prueba del sistema.

## Propósito

- validar comportamiento funcional
- comprobar integridad de datos y trazabilidad
- cubrir casos reales y escenarios de operación
- proteger la evolución del proyecto frente a regresiones

## Contenidos esperados

- pruebas unitarias
- pruebas de integración
- casos de prueba del flujo industrial
- validación de trazabilidad y evidencias
- pruebas de seguridad y permisos relevantes

## Regla importante

Las pruebas deben validar comportamientos reales del dominio y no suposiciones de demo.

## MPCF-036 — MOD-011 Ventas V1

`test_mpcf_036_sales_v1.js` valida contratos SQL, permisos, responsables y timestamps automáticos, cantidad preparada, EXCESO trazable sin duplicar movimientos MOD-007, transiciones comerciales y vínculo del despacho completo con el mismo producto existente de Producto / ISOL.
