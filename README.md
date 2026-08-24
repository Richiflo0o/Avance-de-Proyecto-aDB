# Proyecto: Administración de Bases de Datos sobre PostgreSQL 16

Proyecto de la asignatura **Administración de Bases de Datos** aplicado al
esquema de SGED (sistema de gestión escolar deportiva). Este repositorio es
**autónomo**: contiene el esquema, los datos semilla y todos los scripts de
la tarea. No depende de la aplicación web.

---

## Requisitos de la tarea → dónde está cada uno

| # | Requisito | Entregable | Verificación en un comando |
|---|---|---|---|
| 1 | BD con **≥ 1 millón de registros coherentes** | `db/admin/02-datos-masivos.sql` | `make setup` (imprime el total al final) |
| 2 | **Usuarios, roles y privilegios** a nivel del motor | `db/admin/01-usuarios-roles.sql` | `docker exec -i sged_admin_bd psql -U u_sged_recepcion -d sged_db -c "DELETE FROM academico.pagos;"` → *permission denied* |
| 3 | **Plan de respaldos y recuperación** | `db/admin/backups/` (plan + scripts probados) | `make backup && make restaurar` |
| 4 | **Optimización con EXPLAIN antes/después** | `db/admin/04-optimizacion.sql` + evidencias `caso-*` | `cat docs/admin/evidencias/caso-0-resumen-comparativo.txt` |
| 5 | **Auditoría de la base de datos** | `db/admin/03-auditoria.sql` | ver §5 abajo (incluye prueba antimanipulación) |

Evidencias ejecutadas y versionadas en **`docs/admin/evidencias/`**:
ninguna cifra de este README es teórica; todas salen de esos archivos,
regenerables con `make evidencia`.

---

## Reproducción desde cero (lo que hay que ejecutar para revisar)

Requisitos: Docker + Docker Compose + GNU Make.

```bash
git clone <este-repo>.git && cd SGED-ADMIN-BD   # o descomprimir el ZIP
make setup        # levanta PostgreSQL 16 y aplica TODO en orden (~3 min)
```

`setup` ejecuta, en este orden:

1. `db/esquema-base.sql` — esquema (4 schemas, ~30 tablas)
2. `db/seed.sql` — datos semilla reales de la app (usuario admin incluido)
3. `db/admin/01-usuarios-roles.sql` — roles, usuarios, GRANT/REVOKE
4. `db/admin/02-datos-masivos.sql` — carga de ~1.86 millones de registros
5. `db/admin/03-auditoria.sql` — auditoría DML + DDL antimanipulable
6. `db/admin/04-optimizacion.sql` — índices con justificación

Conexión: `localhost:5434`, base `sged_db`, usuario `postgres`, clave
`postgres` (entorno de laboratorio).

> **Importante:** `make setup` asume una base limpia. Si ya ejecutaste el
> proyecto antes en este equipo, reinicia primero con `make clean`
> (borra el contenedor y el volumen) y luego `make setup`. El script
> `02-datos-masivos.sql` aborta de forma segura si los datos masivos ya
> fueron cargados, para no duplicar el millón de registros.

### Comandos de apoyo durante la revisión

```bash
make evidencia    # regenera TODAS las evidencias (~2 min)
make backup       # pg_dump -Fc verificado + retención de 7 días
make restaurar    # simulacro: restaura en sged_restaurada y valida conteos
make limpieza     # purga el lote masivo dejando la base semilla (~17 s)
make clean        # borra contenedor y volumen (reinicio total)
```

---

## Resultados medidos (no teóricos)

**Volumen:** 1,855,925 registros. La carga usa `generate_series` con
fórmulas determinísticas (p. ej., los 150 asistentes por sesión salen de
`(sesión*97+i) % 60000`) — coherencia estructural garantizada por diseño,
no por azar: todo estudiante tiene representante, consentimiento, pagos,
asistencias y evaluaciones.

**Optimización** (`EXPLAIN (ANALYZE, BUFFERS)` antes vs. después).
Los milisegundos varían entre ejecuciones según caché/IO del host; la señal
robusta es la caída de *buffers* leídos a disco. Valores de la última
regeneración automática (`make evidencia`, ver
`docs/admin/evidencias/caso-0-resumen-comparativo.txt`):

| Caso | Consulta | Antes | Después | Técnica |
|---|---|---|---|---|
| A | Ausencias/tardanzas sobre 900k asistencias | 148.6 ms / 11,111 páginas | **22.9 ms / 102 páginas** | índice `estado` → Index Only Scan |
| B | Búsqueda `ILIKE '%gar%'` de personas | 70.6 ms | **14.8 ms** | extensión `pg_trgm` + índice GIN |
| C | Reporte financiero mensual | 111.4 ms / 2,715 páginas leídas | **90.8 ms / 30 páginas leídas** | índice compuesto `(tipo, fecha_pago)` |

El caso C mejora sobre todo en I/O (buffers en disco 2,715 → 30) más que en
tiempo de pared, porque tras la carga el conjunto de datos ya está en caché;
en un servidor con presión de memoria la brecha de latencia se amplía.

Nota honesta documentada también en las evidencias: para el agregado SIN
filtro (GROUP BY del total de filas) el planificador sigue eligiendo Seq
Scan paralelo — ningún índice gana cuando se lee el 100 % de los datos.

**Respaldos:** dump comprimido de ~24 MB en ~5 s, verificado con
`pg_restore --list`; restauración simulada y validada por conteos en ~5 s.
Plan completo (RPO/RTO, estrategia, retención, offsite, evolución a PITR):
[`db/admin/backups/PLAN-RESPALDOS.md`](db/admin/backups/PLAN-RESPALDOS.md).

---

## Puntos técnicos que sustentan el diseño

* **Roles-grupo sin login + usuarios login que heredan** — patrón estándar
  de PostgreSQL: cambiar permisos es tocar el rol una vez.
* **Endurecimiento por defecto**: se revoca lo implícito (`PUBLIC`,
  `public`, crear BD), no solo se concede lo mínimo.
* **Secuencias reancladas al inicio de la carga**: en PostgreSQL las
  secuencias NO son transaccionales; un intento fallido las deja adelantadas
  y rompería recargas posteriores. Hallazgo real del desarrollo.
* **Auditoría genérica con JSONB**: `to_jsonb(OLD/NEW)` diff campo a campo;
  función `SECURITY DEFINER` de propietario dedicado para que ni el dueño
  de la tabla auditada pueda alterar el rastro (verificado con
  permission denied). Event trigger registra además el DDL.
* **Índices en el lado hijo de las FK**: PostgreSQL no los crea solos; sin
  ellos cada borrado de padre dispara secuenciales masivos. Se detectaron
  11 columnas afectadas y se documentaron en `99-limpieza.sql`.
* **Limpieza reversible**: el lote masivo se marca (`@mass.sged.com`) y se
  purga sin tocar datos semilla; la purga queda auditada.

## Estructura

```
├── README.md                  ← este archivo
├── Makefile                   ← setup / evidencia / backup / restaurar ...
├── docker-compose.yml         ← PostgreSQL 16 pinneado por digest
├── db/
│   ├── esquema-base.sql       ← esquema consolidado (DDL completo)
│   ├── seed.sql               ← datos semilla de la aplicación
│   └── admin/
│       ├── README.md          ← guía técnica detallada por script
│       ├── 01-usuarios-roles.sql
│       ├── 02-datos-masivos.sql
│       ├── 03-auditoria.sql
│       ├── 04-optimizacion.sql
│       ├── 99-limpieza.sql
│       └── backups/           ← PLAN-RESPALDOS.md + scripts probados
├── scripts/
│   └── evidencia-admin.sh     ← generador de todas las evidencias
└── docs/
    ├── GUION-DEMO.md          ← guion de demostración en vivo (~12 min)
    └── admin/evidencias/      ← salidas versionadas y regenerables
```
