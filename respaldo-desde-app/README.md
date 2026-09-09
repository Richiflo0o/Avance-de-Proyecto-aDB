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
{"nombre":"sged_db_20260908_204834.sql","tamanioBytes":101217839}
```

≈96,5 MB, verificado como volcado íntegro (`grep -c 'COPY deportivo.asistencias'`
devuelve `1`) y restaurable con `psql -U postgres -d sged_db -f <archivo>.sql`
sobre una base con el mismo esquema.

## Requisito adicional del Dockerfile del backend

Para que `pg_dump` exista dentro del contenedor del backend:

```dockerfile
RUN apt-get update && apt-get install -y --no-install-recommends postgresql-client \
    && rm -rf /var/lib/apt/lists/*
```

(el resto de la imagen no cambia)
