-- ==============================================================
-- SGED - Administración de Bases de Datos
-- 04: Optimización de consultas sobre el volumen masivo
--
-- Metodología aplicada (reproducible con scripts/evidencia-admin.sh):
--   1. Identificar consultas relevantes de alto costo (reportes del
--      dominio que el backend ejecuta o ejecutará).
--   2. Medir con EXPLAIN (ANALYZE, BUFFERS) -> plan "antes".
--   3. Aplicar la estrategia (índice / extensión trigram).
--   4. Re-medir -> plan "después" y comparar tiempo + buffers.
--
-- Los tres casos y su justificación:
--
--   CASO A - Dashboard disciplinario: ausencias y tardanzas sobre la
--   tabla de 900,000 asistencias. El filtro por estado es selectivo
--   (~13% TARDE+AUSENTE): un Seq Scan lee TODAS las páginas del heap;
--   con el índice el motor responde con Index Only Scan sin tocar el
--   heap (Heap Fetches: 0 tras el vacuum de ANALYZE).
--   Nota de análisis honesto: para el agregado SIN filtro
--   (GROUP BY estado de las 900k filas) el planificador sigue
--   prefiriendo Seq Scan paralelo — el índice no ayuda cuando se lee
--   el 100% de los datos; esa comparación quedó documentada en la
--   evidencia y sustenta POR QUÉ se eligió la variante selectiva.
--
-- Consulta del caso:
--   SELECT estado, COUNT(*)
--     FROM deportivo.asistencias
--    WHERE estado IN ('AUSENTE','TARDE')
--    GROUP BY estado;
--
--   CASO B - Búsqueda de personas por apellido con coincidencia
--   parcial e insensible a mayúsculas (ILIKE '%...%'). Un B-tree NO
--   sirve para '%texto%' (el comodín inicial rompe el ordenamiento);
--   la estrategia correcta es pg_trgm + índice GIN.
--
--   CASO C - Reporte financiero: membresías cobradas en un mes. El
--   índice existente idx_pagos_estudiante(id_estudiante, fecha_pago)
--   no aplica sin filtro por estudiante. Índice compuesto
--   (tipo, fecha_pago): igualdad + rango, el patrón ideal B-tree.
--
-- Este archivo documenta y crea los objetos. La EVIDENCIA antes/
-- después se genera automáticamente con:
--   ./scripts/evidencia-admin.sh optimizacion
-- (el script elimina los índices, captura el plan "antes", los crea,
--  captura el plan "después" y guarda todo en docs/admin/evidencias/)
-- ==============================================================

\set ON_ERROR_STOP on

-- ============================================================
-- CASO A: asistencias por estado
-- ============================================================
-- Consulta 1 (agregado para dashboard):
--   SELECT estado, COUNT(*) FROM deportivo.asistencias GROUP BY estado;
--
-- Consulta 2 (repitentes del último bimestre, join con personas):
--   SELECT p.nombre || ' ' || p.apellido AS estudiante, COUNT(*) AS inasistencias
--     FROM deportivo.asistencias a
--     JOIN academico.estudiantes e ON e.id_estudiante = a.id_estudiante
--     JOIN seguridad.personas   p ON p.id_persona    = e.id_persona
--    WHERE a.estado IN ('AUSENTE','TARDE')
--    GROUP BY 1 HAVING COUNT(*) >= 8
--    ORDER BY inasistencias DESC LIMIT 15;
--
-- ANTES: Seq Scan sobre asistencias (900k filas, ~6-7k páginas leídas).
-- DESPUÉS: índice simple; el conteo pasa a Index Only Scan.
CREATE INDEX IF NOT EXISTS idx_asistencias_estado
    ON deportivo.asistencias (estado);

-- Variante considerada y descartada: índice PARCIAL
--   ... ON asistencias(estado) WHERE estado IN ('AUSENTE','TARDE')
-- Sería más pequeño aún, pero deja fuera PRESENTE/JUSTIFICADO del
-- dashboard (consulta 1). Preferimos cobertura completa con un costo
-- marginal: decisión documentada para sustentarla en la defensa.

-- VACUUM (ANALYZE), no solo ANALYZE: el Index Only Scan del caso A exige
-- visibility map, y tras una carga masiva ninguna página es all-visible
-- hasta que pasa un vacuum. En producción lo cubre el autovacuum.
VACUUM (ANALYZE) deportivo.asistencias;

-- ============================================================
-- CASO B: búsqueda de personas por apellido (ILIKE parcial)
-- ============================================================
--   SELECT id_persona, nombre, apellido, cedula
--     FROM seguridad.personas
--    WHERE apellido ILIKE '%gar%'
--    ORDER BY apellido, nombre LIMIT 20;
--
-- ANTES: Seq Scan con filtro regex sobre 72,221 filas.
-- DESPUÉS: GIN trigram: el índice descompone el texto en trigramas y
-- soporta %x% sin importar dónde esté el comodín.
CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE INDEX IF NOT EXISTS idx_personas_apellido_trgm
    ON seguridad.personas USING gin (apellido gin_trgm_ops);

ANALYZE seguridad.personas;

-- ============================================================
-- CASO C: reporte financiero mensual de membresías
-- ============================================================
--   SELECT date_trunc('month', fecha_pago)::date AS mes,
--          COUNT(*) AS pagos, SUM(monto) AS recaudado
--     FROM academico.pagos
--    WHERE tipo = 'MEMBRESIA'
--      AND fecha_pago >= '2026-05-01' AND fecha_pago < '2026-06-01'
--    GROUP BY 1;
--
-- ANTES: Seq Scan sobre 220,000 pagos.
-- DESPUÉS: (tipo, fecha_pago) resuelve igualdad + rango: ~30,000
-- entradas candidatas directamente del índice.
CREATE INDEX IF NOT EXISTS idx_pagos_tipo_fecha
    ON academico.pagos (tipo, fecha_pago);

ANALYZE academico.pagos;
