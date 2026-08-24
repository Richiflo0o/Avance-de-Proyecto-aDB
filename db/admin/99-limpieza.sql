-- ==============================================================
-- SGED - Administración de Bases de Datos
-- 99: Limpieza de los datos masivos
--
-- Elimina EXACTAMENTE los registros generados por
-- db/admin/02-datos-masivos.sql usando el marcador de origen
-- (@mass.sged.com / "(datos masivos)"), sin tocar los datos reales
-- del seed ni lo creado por la aplicación.
--
-- Dos decisiones de diseño documentadas:
--
-- 1. ÍNDICES DE SOPORTE DE INTEGRIDAD (se crean y PERMANECEN):
--    al borrar un padre, PostgreSQL valida cada FK con un lookup en
--    la columna hija. Cinco FKs carecían de índice en el lado hijo y
--    cada borrado degeneraba en secuencial masivo (p. ej., borrar
--    estudiantes sin índice en notificaciones.id_estudiante equivale
--    a ~9 mil millones de visitas de fila). Son idempotentes y
--    benefician igualmente a la operación normal del sistema.
--
-- 2. PURGA CON AUDITORÍA SUSPENDIDA:
--    borrar ~470k filas de tablas auditadas dispararía el mismo
--    número de entradas de auditoría (con JSONB completo), volviendo
--    la purga impráctica. Durante ESTA operación administrativa se
--    desactivan los triggers trg_aud_* y se registra UNA entrada
--    manual que documenta la purga. Es una decisión explícita y
--    reversible: cualquier borrado hecho por vías normales sigue
--    auditándose fila a fila.
--
-- Orden: hijos antes que padres. Transaccional: o todo o nada.
--
-- Ejecutar como superusuario:
--   docker exec -i sged_postgres psql -U postgres -d sged_db \
--     < db/admin/99-limpieza.sql
-- ==============================================================

\set ON_ERROR_STOP on

-- ------------------------------------------------------------
-- 0. Índices de soporte de RI (comprometidos fuera de la transacción:
--    deben sobrevivir aunque la limpieza se revierta)
-- ------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_notificaciones_estudiante
    ON academico.notificaciones(id_estudiante);
CREATE INDEX IF NOT EXISTS idx_usuarios_id_persona
    ON seguridad.usuarios(id_persona);
CREATE INDEX IF NOT EXISTS idx_sesiones_horario
    ON deportivo.sesiones_entrenamiento(id_horario);
CREATE INDEX IF NOT EXISTS idx_consentimientos_representante
    ON academico.consentimientos(id_representante);
CREATE INDEX IF NOT EXISTS idx_usuario_rol_usuario
    ON seguridad.usuario_rol(id_usuario);
CREATE INDEX IF NOT EXISTS idx_consentimientos_registrado_por
    ON academico.consentimientos(registrado_por_id_usuario);
CREATE INDEX IF NOT EXISTS idx_consentimientos_revocado_por
    ON academico.consentimientos(revocado_por_id_usuario);
CREATE INDEX IF NOT EXISTS idx_pagos_registrado_por
    ON academico.pagos(registrado_por_id_usuario);
CREATE INDEX IF NOT EXISTS idx_pagos_anulado_por
    ON academico.pagos(anulado_por_id_usuario);
CREATE INDEX IF NOT EXISTS idx_movimientos_registrado_por
    ON inventario.movimientos_stock(registrado_por_id_usuario);
CREATE INDEX IF NOT EXISTS idx_asignaciones_registrado_por
    ON inventario.asignaciones(registrado_por_id_usuario);

BEGIN;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM seguridad.personas WHERE correo LIKE '%@mass.sged.com') THEN
        RAISE EXCEPTION 'No hay datos masivos que limpiar.';
    END IF;
END $$;

-- ------------------------------------------------------------
-- 0.1 Suspensión temporal de la auditoría DML para la purga
--     (DDL transaccional: si algo falla, todo vuelve solo)
-- ------------------------------------------------------------
ALTER TABLE seguridad.personas            DISABLE TRIGGER trg_aud_personas;
ALTER TABLE seguridad.usuarios            DISABLE TRIGGER trg_aud_usuarios;
ALTER TABLE academico.pagos               DISABLE TRIGGER trg_aud_pagos;
ALTER TABLE academico.estudiantes         DISABLE TRIGGER trg_aud_estudiantes;
ALTER TABLE inventario.movimientos_stock  DISABLE TRIGGER trg_aud_movimientos;

-- ------------------------------------------------------------
-- 1. Inventario (artículos marcados "(datos masivos)")
-- ------------------------------------------------------------
DELETE FROM inventario.asignaciones a
 USING inventario.articulos art
 WHERE art.id_articulo = a.id_articulo
   AND art.descripcion LIKE '%(datos masivos)';

DELETE FROM inventario.movimientos_stock m
 USING inventario.articulos art
 WHERE art.id_articulo = m.id_articulo
   AND art.descripcion LIKE '%(datos masivos)';

DELETE FROM inventario.articulos WHERE descripcion LIKE '%(datos masivos)';

-- ------------------------------------------------------------
-- 2. Evaluaciones (trazan al entrenador masivo)
-- ------------------------------------------------------------
DELETE FROM deportivo.detalle_evaluacion d
 USING deportivo.evaluacion_estudiante ee,
       deportivo.evaluaciones_diarias   ev,
       deportivo.entrenadores           ent,
       seguridad.personas               p
WHERE d.id_evaluacion_estudiante = ee.id_evaluacion_estudiante
  AND ev.id_evaluacion = ee.id_evaluacion
  AND ent.id_entrenador = ev.id_entrenador
  AND p.id_persona = ent.id_persona
  AND p.correo LIKE '%@mass.sged.com';

DELETE FROM deportivo.evaluacion_estudiante ee
 USING deportivo.evaluaciones_diarias ev,
       deportivo.entrenadores         ent,
       seguridad.personas             p
WHERE ev.id_evaluacion = ee.id_evaluacion
  AND ent.id_entrenador = ev.id_entrenador
  AND p.id_persona = ent.id_persona
  AND p.correo LIKE '%@mass.sged.com';

DELETE FROM deportivo.evaluaciones_diarias ev
 USING deportivo.entrenadores ent,
       seguridad.personas     p
WHERE ent.id_entrenador = ev.id_entrenador
  AND p.id_persona = ent.id_persona
  AND p.correo LIKE '%@mass.sged.com';

-- ------------------------------------------------------------
-- 3. Asistencias y agenda (sesiones/horarios del entrenador masivo)
-- ------------------------------------------------------------
DELETE FROM deportivo.asistencias a
 USING seguridad.personas p,
       academico.estudiantes e
WHERE e.id_estudiante = a.id_estudiante
  AND p.id_persona = e.id_persona
  AND p.correo LIKE '%@mass.sged.com';

DELETE FROM deportivo.sesiones_entrenamiento s
 USING deportivo.entrenadores ent,
       seguridad.personas     p
WHERE ent.id_entrenador = s.id_entrenador
  AND p.id_persona = ent.id_persona
  AND p.correo LIKE '%@mass.sged.com';

DELETE FROM deportivo.horarios_entrenamiento h
 USING deportivo.entrenadores ent,
       seguridad.personas     p
WHERE ent.id_entrenador = h.id_entrenador
  AND p.id_persona = ent.id_persona
  AND p.correo LIKE '%@mass.sged.com';

-- ------------------------------------------------------------
-- 4. Partidos y estadísticas (equipos masivos 'SEL-xx')
--    (id_estudiante/id_equipo_* no tienen FK por diseño heredado;
--     se eliminan por coincidencia con los ids del lote masivo)
-- ------------------------------------------------------------
DELETE FROM deportivo.estadistica_partidos ep
 USING deportivo.partidos pa,
       deportivo.equipos  eq
WHERE ep.id_partido = pa.id_partido
  AND pa.id_equipo_local = eq.id_equipo
  AND eq.siglas LIKE 'SEL-%';

DELETE FROM deportivo.partidos pa
 USING deportivo.equipos eq
WHERE pa.id_equipo_local = eq.id_equipo
  AND eq.siglas LIKE 'SEL-%';

DELETE FROM deportivo.equipos WHERE siglas LIKE 'SEL-%';

-- ------------------------------------------------------------
-- 5. Finanzas y notificaciones (vía estudiantes/representantes masivos)
-- ------------------------------------------------------------
DELETE FROM academico.pagos pg
 USING academico.estudiantes e,
       seguridad.personas    p
WHERE e.id_estudiante = pg.id_estudiante
  AND p.id_persona = e.id_persona
  AND p.correo LIKE '%@mass.sged.com';

DELETE FROM academico.notificaciones n
 USING seguridad.personas p,
       academico.estudiantes e
WHERE n.id_estudiante = e.id_estudiante
  AND p.id_persona = e.id_persona
  AND p.correo LIKE '%@mass.sged.com';

-- ------------------------------------------------------------
-- 6. Vínculos, consentimientos y tablas padre
-- ------------------------------------------------------------
DELETE FROM academico.consentimientos c
 USING seguridad.personas p,
       academico.representantes r
WHERE c.id_representante = r.id_representante
  AND p.id_persona = r.id_persona
  AND p.correo LIKE '%@mass.sged.com';

DELETE FROM academico.representante_estudiante re
 USING seguridad.personas p,
       academico.representantes r
WHERE re.id_representante = r.id_representante
  AND p.id_persona = r.id_persona
  AND p.correo LIKE '%@mass.sged.com';

DELETE FROM academico.estudiantes e
 USING seguridad.personas p
WHERE p.id_persona = e.id_persona
  AND p.correo LIKE '%@mass.sged.com';

DELETE FROM academico.representantes r
 USING seguridad.personas p
WHERE p.id_persona = r.id_persona
  AND p.correo LIKE '%@mass.sged.com';

DELETE FROM deportivo.entrenadores ent
 USING seguridad.personas p
WHERE p.id_persona = ent.id_persona
  AND p.correo LIKE '%@mass.sged.com';

DELETE FROM seguridad.usuario_rol ur
 USING seguridad.usuarios u
WHERE u.id_usuario = ur.id_usuario
  AND u.username ~ '^(est|rep|ent)[0-9]+$';

DELETE FROM seguridad.usuarios u
 USING seguridad.personas p
WHERE p.id_persona = u.id_persona
  AND p.correo LIKE '%@mass.sged.com';

DELETE FROM seguridad.personas WHERE correo LIKE '%@mass.sged.com';

-- Categorías añadidas por la carga masiva
DELETE FROM deportivo.categorias
WHERE descripcion LIKE '%(carga masiva)%';

-- ------------------------------------------------------------
-- 7. Reactivar la auditoría y registrar el evento de purga
-- ------------------------------------------------------------
ALTER TABLE seguridad.personas            ENABLE TRIGGER trg_aud_personas;
ALTER TABLE seguridad.usuarios            ENABLE TRIGGER trg_aud_usuarios;
ALTER TABLE academico.pagos               ENABLE TRIGGER trg_aud_pagos;
ALTER TABLE academico.estudiantes         ENABLE TRIGGER trg_aud_estudiantes;
ALTER TABLE inventario.movimientos_stock  ENABLE TRIGGER trg_aud_movimientos;

-- Entrada manual que documenta la purga en el propio registro de
-- auditoría (trazabilidad del mantenimiento, aunque los borrados
-- individuales del lote no se auditaran fila a fila).
INSERT INTO seguridad.auditoria_dml
    (usuario_bd, operacion, esquema, tabla, registro_id, datos_anteriores)
SELECT session_user,
       'DELETE',
       'sistema',
       'purga_datos_masivos',
       NULL,
       jsonb_build_object(
           'evento',   'purga del lote masivo',
           'script',   'db/admin/99-limpieza.sql',
           'personas', (SELECT COUNT(*) FROM seguridad.personas
                         WHERE correo LIKE '%@mass.sged.com'));

COMMIT;
