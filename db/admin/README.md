# Administración de Bases de Datos — SGED

Implementación sobre el esquema real de SGED (PostgreSQL 16) de los cinco
componentes exigidos: **volumen masivo**, **usuarios/roles/privilegios**,
**respaldos y recuperación**, **optimización de consultas** y **auditoría**.
Toda la evidencia queda versionada en `docs/admin/evidencias/`.

## Ejecución completa (orden obligatorio)

Con la base levantada y el esquema aplicado (`make setup` hace todo esto en orden):

```bash
# 0. (opcional, una vez) usuarios/roles/privilegios del motor
docker exec -i sged_admin_bd psql -U postgres -d sged_db \
  < db/admin/01-usuarios-roles.sql

# 1. Carga masiva (~1.86M registros; tarda ~50 s)
docker exec -i sged_admin_bd psql -U postgres -d sged_db \
  < db/admin/02-datos-masivos.sql

# 2. Auditoría a nivel motor (DML + DDL)
docker exec -i sged_admin_bd psql -U postgres -d sged_db \
  < db/admin/03-auditoria.sql

# 3. Optimización (índices; ver evidencias antes/después)
./scripts/evidencia-admin.sh optimizacion

# 4. Ciclo completo de respaldo y restauración verificado
./db/admin/backups/backup_completo.sh
./db/admin/backups/restaurar.sh

# (Opcional) Regenerar TODAS las evidencias en docs/admin/evidencias/
./scripts/evidencia-admin.sh todo
```

## Componente 1 — Base con más de un millón de registros

`02-datos-masivos.sql` genera **~1.86 millones de registros coherentes**
con el dominio (60k estudiantes, 900k asistencias, 220k pagos, etc.),
respetando todas las FKs y restricciones únicas por construcción:

- Fórmulas determinísticas (`generate_series`) que garantizan unicidad
  sin `ON CONFLICT`: p. ej., los 150 asistentes por sesión usan
  `(s*97+i) % 60000`, distinto dentro de cada sesión.
- Secuencias reancladas al inicio: los intentos fallidos no corrompen
  recargas posteriores (las secuencias no son transaccionales).
- Transaccional de punta a punta: cualquier error revierte todo.
- Marcador `@mass.sged.com` para detectar/limpiar el lote
  (`99-limpieza.sql`, purga verificada en ~17 s) sin tocar datos reales.

Evidencia: `docs/admin/evidencias/01-conteos-millon.txt`
(`TOTAL DEL SISTEMA: 1855925 registros — CUMPLE`).

## Componente 2 — Usuarios, roles y privilegios

`01-usuarios-roles.sql` crea la capa de autorización del motor,
independiente de la autenticación JWT de la aplicación:

| Usuario BD | Rol-grupo | Alcance |
|---|---|---|
| `u_sged_admin` | `rol_sged_admin` | Control total de los 4 esquemas |
| `u_sged_recepcion` | `rol_sged_recepcion` | Operación diaria (asistencias/pagos/inventario); sin DELETE |
| `u_sged_entrenador` | `rol_sged_entrenador` | Dominio deportivo (sesiones, evaluaciones, lesiones) |
| `u_sged_consulta` | `rol_sged_consulta` | Lectura limitada (sin datos financieros) |
| `u_sged_auditor` | `rol_sged_auditor` | Solo lectura del registro de auditoría |
| `u_sged_backup` | `rol_sged_backup` | SELECT total para `pg_dump` |

Incluye endurecimiento (`REVOKE ... FROM PUBLIC`), privilegios por defecto
para tablas futuras y pruebas de demostración en vivo (§6 del script).
Contraseñas didácticas de laboratorio (repo académico público).

Evidencia: `docs/admin/evidencias/02-usuarios-roles.txt`.

## Componente 3 — Respaldos y recuperación

Ver **[PLAN-RESPALDOS.md](backups/PLAN-RESPALDOS.md)** (RPO/RTO, estrategia,
retención, offsite, simulacro). Scripts:

```bash
./db/admin/backups/backup_completo.sh   # pg_dump -Fc + verificación + retención + log
./db/admin/backups/restaurar.sh         # restaura a 'sged_restaurada' y valida conteos mínimos
```

La restauración nunca toca la base original: se valida primero en una copia
y la promoción es un paso humano documentado.

Evidencia: `docs/admin/evidencias/04-respaldos.txt`.

## Componente 4 — Optimización de consultas

Metodología antes/después con `EXPLAIN (ANALYZE, BUFFERS)` en tres
consultas reales de alto costo (detalle y justificación en
`04-optimizacion.sql`; reproducible con `./scripts/evidencia-admin.sh optimizacion`):

| Caso | Consulta | Estrategia | Antes | Después |
|---|---|---|---|---|
| A | Ausencias/tardanzas sobre 900k asistencias | Índice `estado` → Index Only Scan | ~65 ms / 11.1k páginas | **~8 ms / 107 páginas** |
| B | Búsqueda `ILIKE '%gar%'` de personas | Extensión `pg_trgm` + GIN | ~44 ms | **~6 ms** |
| C | Reporte financiero mensual | Índice compuesto `(tipo, fecha_pago)` | ~47 ms | **~20 ms** |

> Hallazgo adicional documentado en `99-limpieza.sql`: el esquema tenía
> once FKs hacia tablas masivas cuyas columnas hijas carecían de índice;
> cada borrado de padre degeneraba en secuencial masivo (~9 mil millones
> de visitas de fila al purgar estudiantes). Los once índices se crean
> idempotentes y permanecen beneficiando también la operación normal.

Evidencia: `docs/admin/evidencias/caso-*-{antes,despues}.txt` y
`caso-0-resumen-comparativo.txt`.

## Componente 5 — Auditoría

Dos capas complementarias:

1. `seguridad.auditoria` (preexistente): acciones de negocio escritas por el backend (`@Auditado`).
2. **Este proyecto** (`03-auditoria.sql`): auditoría del motor, imposible de
   esquivar desde la aplicación:
   - `seguridad.auditoria_dml`: INSERT/UPDATE/DELETE sobre tablas sensibles
     (personas, usuarios, estudiantes, pagos, movimientos) con estado
     anterior/posterior en JSONB, usuario BD, IP y aplicación.
   - `seguridad.auditoria_ddl`: event trigger que registra cambios de esquema.
   - **Antimanipulación**: función disparadora `SECURITY DEFINER`; nadie puede
     escribir ni borrar el registro directamente (verificado con `rol_auditor`).
   - Ayudas de consulta: vista `v_auditoria_reciente` (diff de campos) y
     `fn_historial_registro(esquema, tabla, id)`.

Evidencia: `docs/admin/evidencias/03-auditoria.txt`.

## Estructura

```
db/admin/
├── README.md                  ← este archivo
├── 01-usuarios-roles.sql      ← roles-grupo + usuarios + GRANT/REVOKE
├── 02-datos-masivos.sql       ← ~1.86M registros determinísticos
├── 03-auditoria.sql           ← triggers DML + event trigger DDL
├── 04-optimizacion.sql        ← índices + justificación técnica
├── 99-limpieza.sql            ← reversa exacta de la carga masiva
└── backups/
    ├── PLAN-RESPALDOS.md      ← estrategia, RPO/RTO, procedimientos
    ├── backup_completo.sh     ← pg_dump diario con retención
    └── restaurar.sh           ← restauración verificada a base de prueba
```

Los mismos pasos están disponibles como targets de Make: `make admin-setup`,
`admin-limpieza`, `admin-evidencia`, `admin-backup`, `admin-restaurar`.

Para la exposición: [`docs/admin/GUION-DEMO.md`](../../docs/admin/GUION-DEMO.md).
