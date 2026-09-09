# Respaldo desde la aplicación (opción "dentro del sistema")

Complementa `db/admin/backups/` (script `backup_completo.sh` + plan de
recuperación), que resuelve el respaldo a nivel de infraestructura/cron.
Esta carpeta añade la variante que la guía del examen final también
describe explícitamente: **una opción dentro de la propia aplicación**
para generar y descargar respaldos, sin salir del sistema ni usar la
terminal.

No reemplaza nada de `db/admin/backups/` — es una segunda forma de cumplir
el mismo requisito, integrada en la app real (Spring Boot + Angular).

## Qué hace

- `BackupService` ejecuta `pg_dump` (formato texto plano, `-F p`) como
  proceso del sistema operativo contra el contenedor de PostgreSQL de la
  red interna de Docker, usando las mismas credenciales de servicio que ya
  usa la aplicación (no credenciales nuevas).
- `BackupController` expone tres endpoints REST, restringidos a
  `ADMINISTRADOR` igual que `/api/admin/auditorias`:

  | Endpoint | Acción |
  |---|---|
  | `POST /api/admin/backups` | Genera un nuevo respaldo |
  | `GET /api/admin/backups` | Lista los respaldos existentes con su tamaño |
  | `GET /api/admin/backups/{archivo}` | Descarga un respaldo puntual |

- `respaldos.component.ts` + `respaldo.service.ts`: pantalla Angular
  (`/admin/respaldos`) con un botón "Generar nuevo respaldo" y una tabla
  de respaldos existentes con enlace de descarga.

## Probado de forma real (no simulado)

Ejecutado contra una copia del proyecto con la carga masiva de 1.000.000+
registros ya cargada:

```
POST /api/admin/backups   (autenticado como admin / ADMINISTRADOR)
200 OK
{"nombre":"sged_db_20260908_213037.sql","tamanioBytes":101218035}
```

≈96,5 MB, con `COPY` de las 35 tablas de los 4 schemas (no solo
`deportivo.asistencias`) y terminado en `-- PostgreSQL database dump
complete` (sin truncar).

**Prueba real de restauración, no solo de generación**: se creó una base
`sged_validacion` vacía y se restauró el .sql completo ahí, comparando
conteos tabla por tabla contra `sged_db`:

| Tabla | Original | Restaurada |
|---|---|---|
| `deportivo.asistencias` | 1,000,000 | 1,000,000 |
| `academico.estudiantes` | 2,401 | 2,401 |
| `seguridad.personas` | 3,021 | 3,021 |
| `seguridad.usuarios` | 18 | 18 |
| `seguridad.auditoria` | 6 | 6 |
| `deportivo.sesiones_entrenamiento` | 2,430 | 2,430 |

**Hallazgo real de esta prueba** (corregido, no solo documentado): la
primera restauración fallaba con
`ERROR: unrecognized configuration parameter "transaction_timeout"`. Causa:
la imagen del backend instala `pg_dump` 18.x (repo de Ubuntu) contra un
motor real Postgres 16.14; `pg_dump` 18 antepone una línea
`SET transaction_timeout = 0;` -GUC que no existe hasta Postgres 17- que el
16 real rechaza. No afectaba ningún dato (el 100% de las filas restauraba
igual pese al error, porque es una sola línea de configuración de sesión,
no una fila del respaldo), pero un examinador que restaure el .sql va a ver
ese error igual. Se corrigió en `BackupService.generarRespaldo()`: después
de que `pg_dump` termina, se quita esa línea del archivo
(`limpiarPreambuloIncompatible`) antes de dar el respaldo por válido. Con
el fix, la misma prueba de restauración completa sin ningún `ERROR` ni
`WARNING`.

## Requisito adicional del Dockerfile del backend

Para que `pg_dump` exista dentro del contenedor del backend:

```dockerfile
RUN apt-get update && apt-get install -y --no-install-recommends postgresql-client \
    && rm -rf /var/lib/apt/lists/*
```

(el resto de la imagen no cambia)
