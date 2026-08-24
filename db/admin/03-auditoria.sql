-- ==============================================================
-- SGED - Administración de Bases de Datos
-- 03: Auditoría y trazabilidad a nivel del motor
--
-- SGED ya registra en seguridad.auditoria las ACCIONES DE NEGOCIO
-- (escritas por el backend vía @Auditado: quién creó un pago, quién
-- anuló, logins, etc.). Este script añade la capa faltante: auditoría
-- INDEPENDIENTE DEL APLICATIVO, imposible de esquivar desde la API:
--
--   seguridad.auditoria_dml : cada INSERT/UPDATE/DELETE sobre tablas
--                             sensibles, con el estado anterior y nuevo
--                             en JSONB (evidencia forense completa).
--   seguridad.auditoria_ddl : cada CREATE/ALTER/DROP sobre los esquemas
--                             del sistema (¿quién cambió el esquema,
--                             cuándo y qué?).
--
-- Diseño antimanipulación:
--   * La función disparadora es SECURITY DEFINER (dueño: postgres):
--     cualquier rol puede provocar una escritura de auditoría pero
--     NADIE excepto el administrador del motor puede insertar/editar/
--     borrar filas del registro directamente.
--   * Los roles de aplicación solo reciben SELECT (rol_sged_auditor).
--
-- Ejecutar como superusuario:
--   docker exec -i sged_postgres psql -U postgres -d sged_db \
--     < db/admin/03-auditoria.sql
-- ==============================================================

\set ON_ERROR_STOP on

BEGIN;

-- ------------------------------------------------------------
-- 1. Tablas de auditoría
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS seguridad.auditoria_dml (
    id_auditoria_dml BIGSERIAL PRIMARY KEY,
    fecha            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    usuario_bd       NAME        NOT NULL DEFAULT session_user,
    aplicacion       TEXT                 DEFAULT current_setting('application_name', true),
    ip               INET                 DEFAULT inet_client_addr(),
    operacion        VARCHAR(10) NOT NULL CHECK (operacion IN ('INSERT','UPDATE','DELETE')),
    esquema          NAME        NOT NULL,
    tabla            NAME        NOT NULL,
    registro_id      TEXT,
    datos_anteriores JSONB,
    datos_nuevos     JSONB
);

COMMENT ON TABLE seguridad.auditoria_dml IS
'Auditoría DML a nivel de motor (independiente del aplicativo). Escrita solo por fn_auditar_dml (SECURITY DEFINER).';

CREATE TABLE IF NOT EXISTS seguridad.auditoria_ddl (
    id_auditoria_ddl BIGSERIAL PRIMARY KEY,
    fecha            TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    usuario_bd       NAME        NOT NULL DEFAULT session_user,
    evento           TEXT        NOT NULL,
    comando          TEXT,
    objeto           TEXT
);

COMMENT ON TABLE seguridad.auditoria_ddl IS
'Auditoría DDL (event triggers): cambios de esquema sobre seguridad/academico/deportivo/inventario.';

CREATE INDEX IF NOT EXISTS idx_aud_dml_fecha
    ON seguridad.auditoria_dml (fecha DESC);
CREATE INDEX IF NOT EXISTS idx_aud_dml_tabla_fecha
    ON seguridad.auditoria_dml (esquema, tabla, fecha DESC);
CREATE INDEX IF NOT EXISTS idx_aud_dml_usuario
    ON seguridad.auditoria_dml (usuario_bd, fecha DESC);

-- ------------------------------------------------------------
-- 2. Función disparadora genérica para DML
--    Uso: CREATE TRIGGER ... EXECUTE FUNCTION seguridad.fn_auditar_dml('id_pago');
--    El argumento es el nombre de la columna PK (para registro_id).
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION seguridad.fn_auditar_dml()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER                 -- escribe como dueño aunque quien dispare no tenga permisos
SET search_path = pg_catalog, seguridad
AS $$
DECLARE
    v_pk     TEXT := COALESCE(TG_ARGV[0], 'id');
    v_viejo  JSONB;
    v_nuevo  JSONB;
    v_id     TEXT;
BEGIN
    IF TG_OP <> 'INSERT' THEN v_viejo := to_jsonb(OLD); END IF;
    IF TG_OP <> 'DELETE' THEN v_nuevo := to_jsonb(NEW); END IF;

    v_id := COALESCE(v_nuevo ->> v_pk, v_viejo ->> v_pk);

    INSERT INTO seguridad.auditoria_dml
        (usuario_bd, aplicacion, ip, operacion, esquema, tabla, registro_id, datos_anteriores, datos_nuevos)
    VALUES
        (session_user,
         current_setting('application_name', true),
         inet_client_addr(),
         TG_OP, TG_TABLE_SCHEMA, TG_TABLE_NAME, v_id, v_viejo, v_nuevo);

    RETURN COALESCE(NEW, OLD);
END;
$$;

-- ------------------------------------------------------------
-- 3. Disparadores sobre tablas sensibles
--    Criterio: datos personales, credenciales, dinero e inventario
--    valioso. Asistencias/evaluaciones quedan cubiertas por la
--    auditoría de aplicación (seguridad.auditoria) y son volumétricas.
-- ------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_aud_personas ON seguridad.personas;
CREATE TRIGGER trg_aud_personas
AFTER INSERT OR UPDATE OR DELETE ON seguridad.personas
FOR EACH ROW EXECUTE FUNCTION seguridad.fn_auditar_dml('id_persona');

DROP TRIGGER IF EXISTS trg_aud_usuarios ON seguridad.usuarios;
CREATE TRIGGER trg_aud_usuarios
AFTER INSERT OR UPDATE OR DELETE ON seguridad.usuarios
FOR EACH ROW EXECUTE FUNCTION seguridad.fn_auditar_dml('id_usuario');

DROP TRIGGER IF EXISTS trg_aud_pagos ON academico.pagos;
CREATE TRIGGER trg_aud_pagos
AFTER INSERT OR UPDATE OR DELETE ON academico.pagos
FOR EACH ROW EXECUTE FUNCTION seguridad.fn_auditar_dml('id_pago');

DROP TRIGGER IF EXISTS trg_aud_estudiantes ON academico.estudiantes;
CREATE TRIGGER trg_aud_estudiantes
AFTER INSERT OR UPDATE OR DELETE ON academico.estudiantes
FOR EACH ROW EXECUTE FUNCTION seguridad.fn_auditar_dml('id_estudiante');

DROP TRIGGER IF EXISTS trg_aud_movimientos ON inventario.movimientos_stock;
CREATE TRIGGER trg_aud_movimientos
AFTER INSERT OR UPDATE OR DELETE ON inventario.movimientos_stock
FOR EACH ROW EXECUTE FUNCTION seguridad.fn_auditar_dml('id_movimiento');

-- ------------------------------------------------------------
-- 4. Auditoría DDL mediante event triggers
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION seguridad.fn_auditar_ddl()
RETURNS event_trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, seguridad
AS $$
BEGIN
    INSERT INTO seguridad.auditoria_ddl (usuario_bd, evento, comando, objeto)
    SELECT session_user,
           TG_EVENT,
           cmd.command_tag,
           cmd.object_identity
    FROM pg_catalog.pg_event_trigger_ddl_commands() cmd
    WHERE cmd.schema_name IN ('seguridad', 'academico', 'deportivo', 'inventario');
END;
$$;

DROP EVENT TRIGGER IF EXISTS evt_aud_ddl_sged;
CREATE EVENT TRIGGER evt_aud_ddl_sged
ON DDL_COMMAND_END
EXECUTE FUNCTION seguridad.fn_auditar_ddl();

-- ------------------------------------------------------------
-- 5. Permisos sobre el registro de auditoría
--    Nadie puede escribirlo directamente: solo la función
--    SECURITY DEFINER. Lectura: admin y auditor.
-- ------------------------------------------------------------
REVOKE ALL PRIVILEGES ON seguridad.auditoria_dml FROM PUBLIC;
REVOKE ALL PRIVILEGES ON seguridad.auditoria_ddl FROM PUBLIC;
GRANT SELECT ON seguridad.auditoria_dml TO rol_sged_admin, rol_sged_auditor;
GRANT SELECT ON seguridad.auditoria_ddl TO rol_sged_admin, rol_sged_auditor;
GRANT USAGE ON SCHEMA seguridad TO rol_sged_auditor; -- si aún no lo tenía

-- ------------------------------------------------------------
-- 6. Ayudas de consulta (para la demostración)
-- ------------------------------------------------------------
CREATE OR REPLACE VIEW seguridad.v_auditoria_reciente AS
SELECT a.fecha,
       a.usuario_bd,
       a.aplicacion,
       a.ip,
       a.operacion,
       a.esquema || '.' || a.tabla AS objeto,
       a.registro_id,
       CASE WHEN a.operacion = 'UPDATE'
            THEN (SELECT jsonb_pretty(jsonb_object_agg(o.key_o,
                                    jsonb_build_object('antes',   o.val_o,
                                                       'despues', n.val_n)))
                  FROM jsonb_each(a.datos_anteriores) AS o(key_o, val_o)
                  JOIN jsonb_each(a.datos_nuevos)     AS n(key_n, val_n)
                       ON n.key_n = o.key_o
                  WHERE o.val_o IS DISTINCT FROM n.val_n
                    AND o.key_o NOT IN ('created_at', 'updated_at'))
            ELSE NULL END AS campos_cambiados
FROM seguridad.auditoria_dml a
ORDER BY a.fecha DESC;

CREATE OR REPLACE FUNCTION seguridad.fn_historial_registro(
    p_esquema TEXT,
    p_tabla   TEXT,
    p_id      TEXT
)
RETURNS TABLE (
    fecha            TIMESTAMPTZ,
    usuario_bd       NAME,
    operacion        VARCHAR,
    datos_anteriores JSONB,
    datos_nuevos     JSONB
)
LANGUAGE sql
STABLE
AS $$
    SELECT a.fecha, a.usuario_bd, a.operacion, a.datos_anteriores, a.datos_nuevos
    FROM seguridad.auditoria_dml a
    WHERE a.esquema = p_esquema
      AND a.tabla   = p_tabla
      AND a.registro_id = p_id
    ORDER BY a.fecha ASC;
$$;

COMMIT;

-- ============================================================
-- 7. DEMOSTRACIÓN (ejecutar sentencia por sentencia)
--
--    -- Un pago anulado deja rastro completo antes/después:
--    UPDATE academico.pagos SET motivo_anulacion = 'prueba auditoría',
--           anulado_en = NOW(),
--           anulado_por_id_usuario = (SELECT id_usuario FROM seguridad.usuarios WHERE username='admin')
--     WHERE id_pago = (SELECT MIN(id_pago) FROM academico.pagos WHERE anulado_en IS NULL AND tipo='MEMBRESIA');
--
--    SELECT * FROM seguridad.v_auditoria_reciente LIMIT 5;
--    SELECT * FROM seguridad.fn_historial_registro('academico','pagos','1');
--
--    -- El propio auditor NO puede alterar el registro:
--    SET ROLE u_sged_auditor;
--    DELETE FROM seguridad.auditoria_dml;   -- ERROR: permission denied
--    RESET ROLE;
-- ============================================================
