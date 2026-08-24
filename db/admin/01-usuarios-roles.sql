-- ==============================================================
-- SGED - Administración de Bases de Datos
-- 01: Gestión de usuarios, roles y privilegios a nivel del motor
--
-- Dos capas de seguridad conviven en SGED y NO compiten:
--   1. seguridad.usuarios (aplicación): autenticación JWT, la usa
--      Spring Security. Es la capa de negocio.
--   2. Roles/usuarios de PostgreSQL (este script): autorización a
--      nivel del motor. Limita qué puede hacer cada conexión directa
--      (BI, reportes, mantenimiento, soporte) aunque someone robe
--      credenciales de aplicación o ejecute SQL a mano.
--
-- Modelo: roles-grupo NOLOGIN + usuarios LOGIN que los heredan.
-- Principio de mínimo privilegio por rol funcional.
--
-- Ejecutar como superusuario:
--   docker exec -i sged_postgres psql -U postgres -d sged_db \
--     < db/admin/01-usuarios-roles.sql
--
-- NOTA: las contraseñas son de laboratorio (repo público académico).
-- En producción: usar secret manager y rotación periódica.
-- ==============================================================

-- ------------------------------------------------------------
-- 1. Roles-grupo (NOLOGIN): definen el conjunto de privilegios.
--    Ningún rol-grupo puede iniciar sesión.
--    (Bloques idempotentes: re-ejecutar el script es seguro.)
-- ------------------------------------------------------------
DO $$ BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'rol_sged_admin') THEN
        CREATE ROLE rol_sged_admin NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'rol_sged_recepcion') THEN
        CREATE ROLE rol_sged_recepcion NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'rol_sged_entrenador') THEN
        CREATE ROLE rol_sged_entrenador NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'rol_sged_consulta') THEN
        CREATE ROLE rol_sged_consulta NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'rol_sged_auditor') THEN
        CREATE ROLE rol_sged_auditor NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'rol_sged_backup') THEN
        CREATE ROLE rol_sged_backup NOLOGIN;
    END IF;
END $$;

COMMENT ON ROLE rol_sged_admin      IS 'SGED: administrador de base de datos';
COMMENT ON ROLE rol_sged_recepcion  IS 'SGED: recepcionista (operación diaria)';
COMMENT ON ROLE rol_sged_entrenador IS 'SGED: entrenador (dominio deportivo)';
COMMENT ON ROLE rol_sged_consulta   IS 'SGED: consultas de lectura limitada';
COMMENT ON ROLE rol_sged_auditor    IS 'SGED: auditor (solo lee el registro de auditoría)';
COMMENT ON ROLE rol_sged_backup     IS 'SGED: operador de respaldos (solo lectura completa para pg_dump)';

-- ------------------------------------------------------------
-- 2. Usuarios de inicio de sesión, miembros de su rol-grupo.
-- ------------------------------------------------------------
DO $$ BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'u_sged_admin') THEN
        CREATE ROLE u_sged_admin LOGIN PASSWORD 'Adm1n-SGED-2026!' IN ROLE rol_sged_admin;
    ELSE
        ALTER ROLE u_sged_admin PASSWORD 'Adm1n-SGED-2026!';
    END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'u_sged_recepcion') THEN
        CREATE ROLE u_sged_recepcion LOGIN PASSWORD 'R3cepcion-2026!' IN ROLE rol_sged_recepcion;
    ELSE
        ALTER ROLE u_sged_recepcion PASSWORD 'R3cepcion-2026!';
    END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'u_sged_entrenador') THEN
        CREATE ROLE u_sged_entrenador LOGIN PASSWORD 'Entr3nador-2026!' IN ROLE rol_sged_entrenador;
    ELSE
        ALTER ROLE u_sged_entrenador PASSWORD 'Entr3nador-2026!';
    END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'u_sged_consulta') THEN
        CREATE ROLE u_sged_consulta LOGIN PASSWORD 'C0nsulta-2026!' IN ROLE rol_sged_consulta;
    ELSE
        ALTER ROLE u_sged_consulta PASSWORD 'C0nsulta-2026!';
    END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'u_sged_auditor') THEN
        CREATE ROLE u_sged_auditor LOGIN PASSWORD 'Aud1tor-2026!' IN ROLE rol_sged_auditor;
    ELSE
        ALTER ROLE u_sged_auditor PASSWORD 'Aud1tor-2026!';
    END IF;
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'u_sged_backup') THEN
        CREATE ROLE u_sged_backup LOGIN PASSWORD 'B4ckup-2026!' IN ROLE rol_sged_backup;
    ELSE
        ALTER ROLE u_sged_backup PASSWORD 'B4ckup-2026!';
    END IF;
END $$;

-- ------------------------------------------------------------
-- 3. Endurecimiento general del cluster/base.
-- ------------------------------------------------------------
REVOKE CREATE ON SCHEMA public FROM PUBLIC;
REVOKE ALL ON DATABASE sged_db FROM PUBLIC;

-- Nadie excepto el propietario toca las tablas de forma implícita:
REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA seguridad, academico, deportivo, inventario FROM PUBLIC;
REVOKE ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA seguridad, academico, deportivo, inventario FROM PUBLIC;

-- ------------------------------------------------------------
-- 4. Privilegios por rol.
--    Matriz resumen (detalle en docs/admin):
--
--    rol          | seguridad | academico        | deportivo            | inventario | auditoria_dml
--    -------------+-----------+------------------+----------------------+------------+---------------
--    admin        | ALL       | ALL              | ALL                  | ALL        | SELECT
--    recepcion    | R personas| R estudiantes, W pagos/notif.| R+W asistencias | R articulos, W movimientos/asignaciones | -
--    entrenador   | R propias | R estudiantes    | R+W sesiones/asistencias/evaluaciones/lesiones | - | -
--    consulta     | R básicas | R catálogos      | R reportes agregados | -          | -
--    auditor      | -         | -                | -                    | -          | SELECT
--    backup       | SELECT    | SELECT           | SELECT               | SELECT     | SELECT
-- ------------------------------------------------------------

-- ---- 4.1 ADMIN: control total sobre los cuatro esquemas ----
GRANT ALL PRIVILEGES ON ALL TABLES    IN SCHEMA seguridad, academico, deportivo, inventario TO rol_sged_admin;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA seguridad, academico, deportivo, inventario TO rol_sged_admin;
GRANT USAGE, CREATE ON SCHEMA seguridad, academico, deportivo, inventario TO rol_sged_admin;

-- ---- 4.2 RECEPCIÓN: operación de mostrador ----
GRANT USAGE ON SCHEMA seguridad, academico, deportivo, inventario TO rol_sged_recepcion;
GRANT SELECT ON seguridad.personas, seguridad.usuarios,
               academico.estudiantes, academico.representantes,
               academico.representante_estudiante TO rol_sged_recepcion;
GRANT INSERT, UPDATE ON academico.pagos,
                      academico.notificaciones,
                      academico.consentimientos TO rol_sged_recepcion;
GRANT SELECT, INSERT, UPDATE ON deportivo.asistencias,
                               deportivo.sesiones_entrenamiento TO rol_sged_recepcion;
GRANT SELECT ON inventario.articulos TO rol_sged_recepcion;
GRANT INSERT, UPDATE ON inventario.movimientos_stock,
                        inventario.asignaciones TO rol_sged_recepcion;
-- No puede borrar nada: anulación lógica, no física (ver chk_pago_anulacion_completa).

-- ---- 4.3 ENTRENADOR: dominio deportivo ----
GRANT USAGE ON SCHEMA seguridad, academico, deportivo TO rol_sged_entrenador;
GRANT SELECT ON seguridad.personas,
               academico.estudiantes,
               deportivo.categorias,
               deportivo.posiciones,
               deportivo.criterios_evaluacion TO rol_sged_entrenador;
GRANT SELECT, INSERT, UPDATE ON deportivo.sesiones_entrenamiento,
                                deportivo.asistencias,
                                deportivo.evaluaciones_diarias,
                                deportivo.evaluacion_estudiante,
                                deportivo.detalle_evaluacion,
                                deportivo.observaciones_estudiante,
                                deportivo.horarios_entrenamiento,
                                deportivo.lesiones TO rol_sged_entrenador;

-- ---- 4.4 CONSULTA: lectura limitada (portal representante/estudiante, BI) ----
GRANT USAGE ON SCHEMA seguridad, academico, deportivo TO rol_sged_consulta;
GRANT SELECT ON deportivo.categorias, deportivo.posiciones,
               academico.estudiantes TO rol_sged_consulta;
-- El detalle financiero/personal sensible queda fuera a propósito.

-- ---- 4.5 AUDITOR: solo el registro de auditoría ----
GRANT USAGE ON SCHEMA seguridad TO rol_sged_auditor;
GRANT SELECT ON seguridad.auditoria TO rol_sged_auditor;
-- seguridad.auditoria_dml se concede en db/admin/03-auditoria.sql

-- ---- 4.6 BACKUP: lectura completa para pg_dump ----
GRANT USAGE ON SCHEMA seguridad, academico, deportivo, inventario TO rol_sged_backup;
GRANT SELECT ON ALL TABLES IN SCHEMA seguridad, academico, deportivo, inventario TO rol_sged_backup;

-- ------------------------------------------------------------
-- 5. Privilegios por defecto: lo que se cree DESPUÉS hereda
--    concesiones automáticamente (tablas futuras de Flyway).
-- ------------------------------------------------------------
ALTER DEFAULT PRIVILEGES IN SCHEMA seguridad, academico, deportivo, inventario GRANT SELECT ON TABLES TO rol_sged_backup;
ALTER DEFAULT PRIVILEGES IN SCHEMA seguridad, academico, deportivo, inventario GRANT ALL ON TABLES TO rol_sged_admin;
ALTER DEFAULT PRIVILEGES IN SCHEMA seguridad, academico, deportivo, inventario GRANT ALL ON SEQUENCES TO rol_sged_admin;

-- ------------------------------------------------------------
-- 6. Verificación rápida (para demostración en vivo).
--    Descomentar y ejecutar sentencia por sentencia:
--
--    SET ROLE u_sged_recepcion;
--    SELECT COUNT(*) FROM academico.estudiantes;          -- OK (SELECT concedido)
--    DELETE FROM academico.pagos WHERE id_pago = 1;       -- ERROR: permission denied
--    INSERT INTO seguridad.roles(nombre) VALUES ('HACK'); -- ERROR: permission denied
--    RESET ROLE;
--
--    SET ROLE u_sged_auditor;
--    SELECT * FROM seguridad.auditoria LIMIT 5;           -- OK
--    SELECT * FROM seguridad.personas LIMIT 5;            -- ERROR: permission denied
--    RESET ROLE;
--
--    SET ROLE u_sged_backup;
--    SELECT COUNT(*) FROM seguridad.personas;             -- OK (lectura total)
--    UPDATE seguridad.personas SET activo = FALSE WHERE id_persona = 1; -- ERROR
--    RESET ROLE;
-- ------------------------------------------------------------
