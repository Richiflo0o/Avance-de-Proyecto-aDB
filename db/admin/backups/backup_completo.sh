#!/usr/bin/env bash
# ==============================================================
# SGED - Respaldo lógico completo (pg_dump formato custom)
#
# Uso:
#   ./db/admin/backups/backup_completo.sh [directorio_destino]
#
# Qué hace:
#   1. pg_dump -Fc de sged_db dentro del contenedor (variable CONTENEDOR, por defecto sged_admin_bd).
#   2. Guarda el dump con marca de tiempo en <destino>/dumps/.
#   3. Verifica la integridad del archivo (pg_restore --list).
#   4. Registra la operación en <destino>/logs/respaldo.log.
#   5. Aplica retención local: borra dumps con más de RETENCION_DIAS.
#
# Programación sugerida (ver PLAN-RESPALDOS.md):
#   0 2 * * *  /ruta/SGED_APPWEB/db/admin/backups/backup_completo.sh
# ==============================================================

set -euo pipefail

CONTENEDOR="${CONTENEDOR:-sged_admin_bd}"
USUARIO_BD="${USUARIO_BD:-postgres}"
BASE_DATOS="${BASE_DATOS:-sged_db}"
RETENCION_DIAS="${RETENCION_DIAS:-7}"

DIR_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DESTINO="${1:-$DIR_SCRIPT}"
DIR_DUMPS="$DESTINO/dumps"
DIR_LOGS="$DESTINO/logs"
mkdir -p "$DIR_DUMPS" "$DIR_LOGS"

MARCA="$(date +%Y%m%d_%H%M%S)"
ARCHIVO="$DIR_DUMPS/${BASE_DATOS}_completo_${MARCA}.dump"
LOG="$DIR_LOGS/respaldo.log"

log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }

log "INICIO respaldo completo de $BASE_DATOS"

docker exec "$CONTENEDOR" pg_dump -U "$USUARIO_BD" -d "$BASE_DATOS" -Fc \
    --file "/tmp/_sged_backup.dump"

docker cp "$CONTENEDOR:/tmp/_sged_backup.dump" "$ARCHIVO"
docker exec "$CONTENEDOR" rm -f "/tmp/_sged_backup.dump"

TAMANO_MB=$(du -m "$ARCHIVO" | cut -f1)

# Verificación de integridad: un TOC legible implica archivo utilizable
if docker exec -i "$CONTENEDOR" pg_restore --list < "$ARCHIVO" > /dev/null 2>&1 \
   || pg_restore --list "$ARCHIVO" > /dev/null 2>&1; then
    log "OK     dump verificado: $ARCHIVO (${TAMANO_MB} MB)"
else
    log "ERROR  el dump no pasó la verificación pg_restore --list: $ARCHIVO"
    exit 1
fi

# Retención local
ELIMINADOS=$(find "$DIR_DUMPS" -name '*.dump' -mtime +"$RETENCION_DIAS" -print -delete | wc -l)
log "INFO   retención aplicada: $ELIMINADOS dump(s) mayor(es) a ${RETENCION_DIAS} días eliminado(s)"

log "FIN    respaldo completo finalizado"
echo "$ARCHIVO"
