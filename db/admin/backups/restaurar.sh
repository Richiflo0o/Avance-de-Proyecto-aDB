#!/usr/bin/env bash
# ==============================================================
# SGED - Restauración verificada de un respaldo lógico
#
# Uso:
#   ./db/admin/backups/restaurar.sh [archivo.dump] [base_destino]
#
#   archivo.dump   : dump a restaurar (por defecto el más reciente)
#   base_destino   : por defecto sged_restaurada (NUNCA toca la base
#                    en producción: primero se valida en una copia)
#
# Qué hace:
#   1. Crea la base destino limpia.
#   2. Restaura con pg_restore -j4 (roles y datos).
#   3. Ejecuta comprobaciones sanitarias: conteo mínimo por tabla y
#      presencia de los roles del sistema.
#   4. Deja la base lista para inspección; el cambio definitivo se
#      documenta en PLAN-RESPALDOS.md (paso 5 del procedimiento).
# ==============================================================

set -euo pipefail

CONTENEDOR="${CONTENEDOR:-sged_admin_bd}"
USUARIO_BD="${USUARIO_BD:-postgres}"

DIR_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIR_DUMPS="$DIR_SCRIPT/dumps"

ARCHIVO="${1:-$(ls -t "$DIR_DUMPS"/*.dump 2>/dev/null | head -n 1 || true)}"
[ -n "$ARCHIVO" ] || { echo "ERROR: no hay dumps en $DIR_DUMPS. Ejecute antes backup_completo.sh"; exit 1; }
[ -f "$ARCHIVO" ] || { echo "ERROR: no existe $ARCHIVO"; exit 1; }

DESTINO="${2:-sged_restaurada}"
LOG="$DIR_SCRIPT/logs/restauracion.log"
mkdir -p "$(dirname "$LOG")"
log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }

log "INICIO restauración de $(basename "$ARCHIVO") hacia $DESTINO"

# Copiar el dump al contenedor (evita depender de montajes de volúmenes)
docker cp "$ARCHIVO" "$CONTENEDOR:/tmp/_sged_restore.dump"

# 1. Recrear la base destino desde cero
docker exec "$CONTENEDOR" psql -U "$USUARIO_BD" -d postgres -q -c \
    "DROP DATABASE IF EXISTS $DESTINO;"
docker exec "$CONTENEDOR" psql -U "$USUARIO_BD" -d postgres -q -c \
    "CREATE DATABASE $DESTINO;"

# 2. Restaurar en paralelo
if ! docker exec "$CONTENEDOR" pg_restore -U "$USUARIO_BD" -d "$DESTINO" \
        -j4 --exit-on-error "/tmp/_sged_restore.dump" >> "$LOG" 2>&1; then
    log "ERROR pg_restore reportó problemas; revise $LOG"
    exit 1
fi

docker exec "$CONTENEDOR" rm -f "/tmp/_sged_restore.dump"

# 3. Comprobaciones sanitarias mínimas
log "INFO   ejecutando verificación post-restauración..."
SQL_VERIFICACION="
SELECT 'personas'     AS tabla, COUNT(*) AS filas FROM seguridad.personas
UNION ALL SELECT 'usuarios',   COUNT(*) FROM seguridad.usuarios
UNION ALL SELECT 'estudiantes',COUNT(*) FROM academico.estudiantes
UNION ALL SELECT 'asistencias',COUNT(*) FROM deportivo.asistencias
UNION ALL SELECT 'pagos',      COUNT(*) FROM academico.pagos;
SELECT 'roles_bd' AS objeto, COUNT(*) FROM pg_roles WHERE rolname LIKE 'rol_sged%';
SELECT 'auditoria_dml' AS tabla, COUNT(*) FROM seguridad.auditoria_dml;"

RESULTADO=$(docker exec "$CONTENEDOR" psql -U "$USUARIO_BD" -d "$DESTINO" -tAc "$SQL_VERIFICACION")
log "INFO   conteos tras restaurar:"
echo "$RESULTADO" | tee -a "$LOG"

FALLAS=$(echo "$RESULTADO" | awk -F'|' '
    $1=="personas"     && $2 < 72    {print}
    $1=="estudiantes"  && $2 < 8     {print}
    $1=="asistencias"  && $2 < 900000{print "asistencias|" $2}
    $1=="roles_bd"     && $2 < 6     {print}')

if [ -n "$FALLAS" ]; then
    log "ERROR  verificación FALLIDA: $FALLAS"
    exit 1
fi

log "OK     restauración verificada en la base '$DESTINO'"
log "INFO   para promoverla manualmente (ventana de mantenimiento):
        DROP DATABASE sged_db; ALTER DATABASE $DESTINO RENAME TO sged_db;"
echo "$DESTINO"
