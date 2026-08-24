# Guion de demostración — Administración de Bases de Datos

Duración total: ~12 minutos. Todos los comandos son copy-paste desde la raíz
de este repositorio con la base levantada (`make up`).

---

## 0. Preparación antes de la exposición (checklist)

```bash
make up                              # PostgreSQL 16 en localhost:5434
make setup                           # esquema + seed + roles + 1.86M registros (~3 min)
./scripts/evidencia-admin.sh todo    # evidencias frescas en docs/admin/evidencias/
```

Verificación rápida antes de salir:

```bash
docker exec sged_admin_bd psql -U postgres -d sged_db -tAc \
  "SELECT COUNT(*) FROM seguridad.personas;"   # debe devolver ~72,021
```

Tener abierto en pestañas del navegador:
- Este archivo y `docs/admin/evidencias/caso-0-resumen-comparativo.txt`
- `db/admin/backups/PLAN-RESPALDOS.md`

---

## 1. Volumen: más de 1 millón de registros coherentes (~2 min)

**Qué mostrar:** el resumen final de la carga.

```bash
make limpieza && make setup   # demuestra que es reversible Y recargable
```

> **Qué decir:** "La carga usa `generate_series` con fórmulas determinísticas,
> no tablas aleatorias: cada sesión tiene exactamente 150 asistentes distintos,
> cada estudiante tiene representante, pagos coherentes con su fecha de ingreso.
> Es transaccional de punta a punta y reancla las secuencias al inicio porque
> las secuencias en PostgreSQL NO son transaccionales — un intento fallido
> dejaría la secuencia adelantada y rompería la recarga. Ese fue un hallazgo
> real durante el desarrollo."
>
> **Cierre:** "Total del sistema: **1,855,925 registros**, requisito de 1M cumplido."

Si preguntan por limpieza: el script purga solo lo marcado `@mass.sged.com`
en ~17 s y deja la base semilla intacta, incluido el registro de auditoría
de la propia purga.

---

## 2. Usuarios, roles y privilegios a nivel motor (~3 min)

```bash
docker exec -i sged_admin_bd psql -U postgres -d sged_db < db/admin/01-usuarios-roles.sql
```

Mostrar la matriz de roles y luego las pruebas de permisos **conectándose de
verdad como cada usuario** (no simuladas):

```bash
# Recepción SÍ lee estudiantes...
docker exec -i sged_admin_bd psql -U u_sged_recepcion -d sged_db -c \
  "SELECT COUNT(*) AS puede_leer FROM academico.estudiantes;"

# ...pero NO toca pagos (permission denied esperado)
docker exec -i sged_admin_bd psql -U u_sged_recepcion -d sged_db -c \
  "DELETE FROM academico.pagos WHERE id_pago = 1;"
```

> **Qué decir:** "Seis roles-grupo SIN login y seis usuarios con login que
> heredan: el patrón recomendado porque revocar un privilegio es quitarlo del
> rol una vez, no usuario por usuario. Además endurecí los defaults de
> PostgreSQL: `REVOKE ALL ON SCHEMA public FROM PUBLIC`, sin crear bases ni
> schemas por defecto. La contraseña del seed ya no vive en texto plano:
> es hash bcrypt cost 12."

Evidencia impresa de respaldo: `docs/admin/evidencias/02-usuarios-roles.txt`.

---

## 3. Respaldos y recuperación (~3 min)

```bash
make backup       # dump verificado + retención, ~5 s
make restaurar    # restaura en sged_restaurada y valida conteos
```

> **Qué decir:** "Formato custom `-Fc` con compresión y verificación con
> `pg_restore --list` ANTES de dar el respaldo por bueno — un respaldo sin
> verificar no es un respaldo. La restauración va a una base de prueba, nunca
> encima de la producción. El plan formal está en PLAN-RESPALDOS.md: RPO de
> 24 h con diario completo + incremental semanal + mensual retenida un año;
> RTO menor a 1 hora medido: dump 5 s, restauración validada 5 s."

**Pregunta segura:** ¿y si se corrompe el disco? → "El plan exige copia
offsite (rclone a otro proveedor) y la evolución natural es PITR con
archivado WAL, documentada en la sección 7 del plan."

---

## 4. Optimización de consultas con EXPLAIN (~3 min)

La joya de la demo — planes reales antes/después:

```bash
docker exec sged_admin_bd psql -U postgres -d sged_db -x -c \
  "EXPLAIN (ANALYZE, BUFFERS) SELECT estado, COUNT(*) FROM deportivo.asistencias
   WHERE estado IN ('AUSENTE','TARDE') GROUP BY estado;"
```

> Con índice presente mostrará **Index Only Scan** con `Heap Fetches: 0`.
> Luego comparar con la tabla comparativa:

```bash
cat docs/admin/evidencias/caso-0-resumen-comparativo.txt
```

| Caso | Antes | Después | Estrategia |
|---|---|---|---|
| A ausencias (900k filas) | ~65 ms / 11,113 páginas | **~8 ms / 107 páginas** | índice `estado` → Index Only Scan |
| B `ILIKE '%gar%'` | ~44 ms | **~6 ms** | `pg_trgm` + GIN |
| C reporte financiero | ~47 ms | **~20 ms** | compuesto `(tipo, fecha_pago)` |

> **Qué decir:** "No optimicé a ciegas: cada caso parte de un plan Seq Scan
> con lectura masiva de heap y termina en Index/Bitmap scan midiendo BUFFERS,
> no solo tiempo. Caso A: 100× menos páginas leídas. El caso B es el más
> didáctico: un ILIKE con comodín inicial es inmune a índices b-tree por la
> colación; trigram convierte el patrón en firmas indexables."
>
> **Honestidad técnica que suma:** "Para el agregado SIN filtro (GROUP BY del
> 100% de filas) el planificador sigue eligiendo Seq Scan paralelo, y está
> bien: ningún índice gana cuando se leen todos los datos. Lo dejé documentado."

---

## 5. Auditoría antimanipulable (~3 min)

```bash
docker exec sged_admin_bd psql -U postgres -d sged_db <<'EOF'
UPDATE academico.pagos SET motivo_anulacion='demo en vivo' WHERE id_pago=1;
SELECT operacion, objeto, registro_id, cambios FROM seguridad.v_auditoria_reciente LIMIT 3;
EOF
```

Luego el remate — intentar destruir la evidencia:

```bash
docker exec -i sged_admin_bd psql -U u_sged_auditor -d sged_db -c \
  "DELETE FROM seguridad.auditoria_dml;"    # permission denied esperado
```

> **Qué decir:** "El trigger captura antes/después en JSONB vía
> `to_jsonb(OLD/NEW)` — genérico para cualquier columna sin mantener listas.
> La tabla de auditoría es propiedad de un rol dedicado; el dueño de la tabla
> auditada NO puede escribir en ella, y el rol auditor solo puede LEER. El
> DDL también queda registrado con un event trigger. Bonus verificable:
> la carga masiva de 1.86M registros dejó 474 mil entradas de auditoría —
> trazabilidad incluso del proceso de carga."

---

## Preguntas probables del jurado (con respuesta corta)

| Pregunta | Respuesta |
|---|---|
| ¿Por qué no `ON CONFLICT` en la carga? | Prefiero unicidad por construcción con fórmulas determinísticas; `ON CONFLICT` oculta problemas de diseño en lugar de evitarlos. |
| ¿Secuencias tras un fallo? | Se reanclan con `setval(pg_get_serial_sequence(...))` al inicio de cada carga; descubrimos que son no-transaccionales por las vías duras. |
| ¿Por qué SECURITY DEFINER en la función de auditoría? | El trigger corre con permisos del invocante; sin él, un usuario sin permiso sobre la tabla de auditoría rompería su propio UPDATE. |
| ¿Índice para FK? | Hallazgo del proyecto: PostgreSQL no indexa automáticamente el lado hijo; sin índice, cada DELETE del padre dispara secuencial sobre el hijo. Lo sufrimos con 60k estudiantes y lo documentamos creando 11 índices. |
| ¿pg_dump vs pg_basebackup? | Lógico = portabilidad y restauración selectiva, ideal para este volumen; físico/PITR queda como evolución en el plan. |
| ¿Cómo sabes que el respaldo sirve? | `pg_restore --list` verifica integridad del archive Y simulacro de restauración con conteos mínimos, ambos automatizados. |

## Plan B si algo falla en vivo

Todas las salidas están versionadas en `docs/admin/evidencias/`: mostrar los
archivos y explicar que fueron generados por `scripts/evidencia-admin.sh`,
que es reproducible (`make evidencia`). Ningún resultado depende de la
suerte de la demo.
