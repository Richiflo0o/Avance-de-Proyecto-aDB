# Plan de respaldos y recuperación — SGED

Base de datos: **PostgreSQL 16** (contenedor `sged_postgres`, base `sged_db`).

## 1. Objetivos de servicio

| Métrica | Meta (entorno académico) | Justificación |
|---|---|---|
| **RPO** (pérdida máxima de datos admisible) | ≤ 24 h | Respaldo completo diario; la operación del día se re-registra |
| **RTO** (tiempo máximo de restablecimiento) | ≤ 1 h | Restauración lógica en paralelo (`pg_restore -j4`) + verificación |

> En producción con SLA estricto el RPO bajaría a minutos activando
> archivado de WAL (PITR); la evolución propuesta está en §7.

## 2. Estrategia

| Elemento | Decisión |
|---|---|
| Tipo de respaldo | **Lógico completo** `pg_dump -Fc` (formato custom comprimido) |
| Frecuencia | Diaria, 02:00 (cron del host) |
| Retención local | 7 días (rotación automática en cada corrida) |
| Copia externa (offsite) | Al menos 4 dumps semanales copiados fuera del servidor (drive/repo privado/otro host) |
| Verificación | Cada dump se valida con `pg_restore --list`; prueba de restauración mensual obligatoria |
| Responsable | Administrador de BD del proyecto |

Por qué lógico y no físico: el volumen (~2 M filas) cabe holgadamente
en un dump comprimido de cientos de MB, permite restaurar en versiones
o arquitecturas distintas, es portable entre instalaciones Docker y su
verificación es trivial. El respaldo físico (pg_basebackup) aparece en §7
como evolución para RPO bajos.

## 3. Procedimiento de respaldo

```bash
# Manual
./db/admin/backups/backup_completo.sh

# Programado (crontab -e del host)
0 2 * * * /ruta/SGED_APPWEB/db/admin/backups/backup_completo.sh >> /ruta/SGED_APPWEB/db/admin/backups/logs/cron.log 2>&1
```

El script: ejecuta `pg_dump -Fc` dentro del contenedor → copia el dump a
`db/admin/backups/dumps/` → valida integridad (`pg_restore --list`) →
registra en `logs/respaldo.log` → aplica retención (borra > 7 días).
Salida típica: `sged_db_completo_20260823_210500.dump`.

## 4. Procedimiento de recuperación (simulacro de pérdida total)

```bash
./db/admin/backups/restaurar.sh                # usa el dump más reciente
./db/admin/backups/restaurar.sh dumps/sged_db_completo_20260823_210500.dump
```

Pasos que automatiza:

1. Crea base limpia `sged_restaurada` (jamás toca la original).
2. `pg_restore -j4 --exit-on-error` del dump.
3. **Verificación post-restauración**: conteos mínimos por tabla crítica
   (asistencias ≥ 900k, estudiantes, usuarios…), presencia de roles BD,
   tabla de auditoría presente.
4. Reporta OK o falla con detalle en `logs/restauracion.log`.

Promoción definitiva (ventana de mantenimiento, decisión humana):

```sql
DROP DATABASE sged_db;
ALTER DATABASE sged_restaurada RENAME TO sged_db;
```
y `docker compose up -d` para reconectar backend.

## 5. Escenarios cubiertos

| Amenaza | Cobertura | Mecanismo |
|---|---|---|
| Borrado/daño lógico de datos | ✅ | Dump diario + restauración puntual de tabla (`pg_restore -L` con lista editada o `COPY` desde la base restaurada) |
| Corrupción del volumen de datos | ✅ | Dump externo al volumen (`dumps/` queda en el host) |
| Pérdida total del host | ⚠️ parcial | Requiere la copia offsite semanal + `docker compose up` + restaurar |
| Error de esquema tras migración | ✅ | El dump contiene DDL completo; restaurar y validar antes de promover |
| Alteración maliciosa silenciosa | ✅ | `seguridad.auditoria_dml` permite identificar qué registros tocar y hasta cuándo; restauración selectiva |

## 6. Prueba mensual obligatoria (calendario)

1. Primer lunes de cada mes: `restaurar.sh` contra el dump más reciente.
2. Confirmar verificación sanitaria OK y registrar fecha en este archivo:

| Fecha | Dump | Resultado | Responsable |
|---|---|---|---|
| 2026-08-23 | `sged_db_completo_*.dump` | ✅ verificada | equipo SGED |

## 7. Evolución declarada (producción real)

- **WAL archiving + PITR**: `archive_mode=on`, archiver hacia almacenamiento
  objeto; permitiría recuperar a un instante exacto (RPO ≈ 0).
- **pg_basebackup semanal** como base física para PITR.
- **Réplica en caliente** (streaming replication) para HA y descarga de reportes.
- Cifrado del dump en reposo (age/gpg) y control de acceso al bucket offsite.
