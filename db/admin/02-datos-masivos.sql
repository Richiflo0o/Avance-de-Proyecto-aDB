-- ==============================================================
-- SGED - Administración de Bases de Datos
-- 02: Carga masiva de datos (~1.87 millones de registros)
--
-- Genera un volumen realista para evaluar el comportamiento del
-- motor con grandes cantidades de información, respetando TODAS las
-- llaves foráneas y restricciones únicas del esquema SGED.
--
-- Distribución planificada (coherente con el dominio):
--   personas .................... 72,200  (60k estudiantes, 12k representantes, 200 entrenadores)
--   usuarios .................... 72,200  (una cuenta por persona generada)
--   usuario_rol ................. 72,200
--   estudiantes ................. 60,000
--   representantes .............. 12,000  (cada uno tutor de 5 estudiantes)
--   entrenadores ................    200
--   representante_estudiante .... 60,000
--   consentimientos ............. 60,000
--   horarios_entrenamiento ......    600
--   sesiones_entrenamiento ......  6,000  (últimos ~360 días)
--   asistencias ................. 900,000 (150 por sesión, mezcla PRESENTE/TARDE/AUSENTE/JUSTIFICADO)
--   evaluaciones_diarias ........  6,000
--   evaluacion_estudiante ....... 15,000  (muestra detallada: primeras 100 sesiones)
--   detalle_evaluacion .......... 75,000  (todos los criterios por estudiante evaluado)
--   pagos ....................... 220,000 (membresías ene-jul 2026 + diarios)
--   notificaciones .............. 150,000
--   articulos / movimientos / asignaciones .... 40 / 50,000 / 20,000
--   equipos / partidos / estadísticas ......... 12 / 400 / 4,000
--   --------------------------------------------------------
--   TOTAL aproximado ........... 1,872,000+
--
-- Marcador de origen: todas las personas generadas usan correos
-- @mass.sged.com, lo que permite detectar y limpiar los datos
-- (ver db/admin/99-limpieza.sql).
--
-- Ejecución (una sola vez; tarda entre 2 y 5 minutos):
--   docker exec -i sged_postgres psql -U postgres -d sged_db \
--     < db/admin/02-datos-masivos.sql
--
-- Es idempotente-en-negativo: si ya se cargó, aborta sin duplicar.
-- Corre dentro de una transacción: cualquier error revierte TODO.
-- ==============================================================

\set ON_ERROR_STOP on

BEGIN;

-- ------------------------------------------------------------
-- 0. Guardia anti-doble-carga
-- ------------------------------------------------------------
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM seguridad.personas WHERE correo LIKE '%@mass.sged.com') THEN
        RAISE EXCEPTION 'Los datos masivos ya fueron cargados (existen personas @mass.sged.com). Ejecute db/admin/99-limpieza.sql antes de recargar.';
    END IF;
END $$;

-- ------------------------------------------------------------
-- 0.1 Reanclaje de secuencias.
--     Las secuencias NO son transaccionales: un intento de carga
--     fallido las deja adelantadas aunque los datos se reviertan,
--     y eso rompería la contigüidad [base+1 .. base+N] que asumen
--     las fórmulas de este script. Se reanclan al máximo REAL de
--     datos para que la carga sea determinista en cualquier estado.
-- ------------------------------------------------------------
SELECT setval(pg_get_serial_sequence('seguridad.personas', 'id_persona'),
              COALESCE((SELECT MAX(id_persona) FROM seguridad.personas), 0) + 1, false);
SELECT setval(pg_get_serial_sequence('seguridad.usuarios', 'id_usuario'),
              COALESCE((SELECT MAX(id_usuario) FROM seguridad.usuarios), 0) + 1, false);
SELECT setval(pg_get_serial_sequence('seguridad.usuario_rol', 'id_usuario_rol'),
              COALESCE((SELECT MAX(id_usuario_rol) FROM seguridad.usuario_rol), 0) + 1, false);
SELECT setval(pg_get_serial_sequence('academico.estudiantes', 'id_estudiante'),
              COALESCE((SELECT MAX(id_estudiante) FROM academico.estudiantes), 0) + 1, false);
SELECT setval(pg_get_serial_sequence('academico.representantes', 'id_representante'),
              COALESCE((SELECT MAX(id_representante) FROM academico.representantes), 0) + 1, false);
SELECT setval(pg_get_serial_sequence('academico.representante_estudiante', 'id_representante_estudiante'),
              COALESCE((SELECT MAX(id_representante_estudiante) FROM academico.representante_estudiante), 0) + 1, false);
SELECT setval(pg_get_serial_sequence('academico.consentimientos', 'id_consentimiento'),
              COALESCE((SELECT MAX(id_consentimiento) FROM academico.consentimientos), 0) + 1, false);
SELECT setval(pg_get_serial_sequence('academico.pagos', 'id_pago'),
              COALESCE((SELECT MAX(id_pago) FROM academico.pagos), 0) + 1, false);
SELECT setval(pg_get_serial_sequence('academico.notificaciones', 'id_notificacion'),
              COALESCE((SELECT MAX(id_notificacion) FROM academico.notificaciones), 0) + 1, false);
SELECT setval(pg_get_serial_sequence('deportivo.entrenadores', 'id_entrenador'),
              COALESCE((SELECT MAX(id_entrenador) FROM deportivo.entrenadores), 0) + 1, false);
SELECT setval(pg_get_serial_sequence('deportivo.horarios_entrenamiento', 'id_horario'),
              COALESCE((SELECT MAX(id_horario) FROM deportivo.horarios_entrenamiento), 0) + 1, false);
SELECT setval(pg_get_serial_sequence('deportivo.sesiones_entrenamiento', 'id_sesion'),
              COALESCE((SELECT MAX(id_sesion) FROM deportivo.sesiones_entrenamiento), 0) + 1, false);
SELECT setval(pg_get_serial_sequence('deportivo.asistencias', 'id_asistencia'),
              COALESCE((SELECT MAX(id_asistencia) FROM deportivo.asistencias), 0) + 1, false);
SELECT setval(pg_get_serial_sequence('deportivo.evaluaciones_diarias', 'id_evaluacion'),
              COALESCE((SELECT MAX(id_evaluacion) FROM deportivo.evaluaciones_diarias), 0) + 1, false);
SELECT setval(pg_get_serial_sequence('deportivo.evaluacion_estudiante', 'id_evaluacion_estudiante'),
              COALESCE((SELECT MAX(id_evaluacion_estudiante) FROM deportivo.evaluacion_estudiante), 0) + 1, false);
SELECT setval(pg_get_serial_sequence('deportivo.detalle_evaluacion', 'id_detalle'),
              COALESCE((SELECT MAX(id_detalle) FROM deportivo.detalle_evaluacion), 0) + 1, false);
SELECT setval(pg_get_serial_sequence('deportivo.equipos', 'id_equipo'),
              COALESCE((SELECT MAX(id_equipo) FROM deportivo.equipos), 0) + 1, false);
SELECT setval(pg_get_serial_sequence('deportivo.partidos', 'id_partido'),
              COALESCE((SELECT MAX(id_partido) FROM deportivo.partidos), 0) + 1, false);
SELECT setval(pg_get_serial_sequence('deportivo.estadistica_partidos', 'id_estadistica_partido'),
              COALESCE((SELECT MAX(id_estadistica_partido) FROM deportivo.estadistica_partidos), 0) + 1, false);
SELECT setval(pg_get_serial_sequence('inventario.articulos', 'id_articulo'),
              COALESCE((SELECT MAX(id_articulo) FROM inventario.articulos), 0) + 1, false);
SELECT setval(pg_get_serial_sequence('inventario.movimientos_stock', 'id_movimiento'),
              COALESCE((SELECT MAX(id_movimiento) FROM inventario.movimientos_stock), 0) + 1, false);
SELECT setval(pg_get_serial_sequence('inventario.asignaciones', 'id_asignacion'),
              COALESCE((SELECT MAX(id_asignacion) FROM inventario.asignaciones), 0) + 1, false);

-- ------------------------------------------------------------
-- 0.2 Bases de secuencia: máximos actuales. Todo id generado será
--     base + offset relativo, sin asumir valores concretos de SERIAL.
--     Con las secuencias reancladas (0.1), cada INSERT..SELECT limpio
--     produce ids contiguos [base+1 .. base+N], supuesto que usan
--     las fórmulas siguientes.
-- ------------------------------------------------------------
CREATE TEMP TABLE _base AS
SELECT COALESCE((SELECT MAX(id_persona)        FROM seguridad.personas), 0)               AS per_base,
       COALESCE((SELECT MAX(id_usuario)        FROM seguridad.usuarios), 0)               AS usr_base,
       COALESCE((SELECT MAX(id_estudiante)     FROM academico.estudiantes), 0)            AS est_base,
       COALESCE((SELECT MAX(id_representante)  FROM academico.representantes), 0)         AS rep_base,
       COALESCE((SELECT MAX(id_entrenador)     FROM deportivo.entrenadores), 0)           AS ent_base,
       COALESCE((SELECT MAX(id_horario)        FROM deportivo.horarios_entrenamiento), 0) AS hor_base,
       COALESCE((SELECT MAX(id_sesion)         FROM deportivo.sesiones_entrenamiento), 0) AS ses_base,
       COALESCE((SELECT MAX(id_articulo)       FROM inventario.articulos), 0)             AS art_base,
       COALESCE((SELECT MAX(id_equipo)         FROM deportivo.equipos), 0)                AS eq_base,
       COALESCE((SELECT MAX(id_partido)        FROM deportivo.partidos), 0)               AS par_base,
       (SELECT id_usuario FROM seguridad.usuarios WHERE username = 'admin')               AS admin_usr;

-- ------------------------------------------------------------
-- 0.2 Catálogo de categorías ampliado (SUB-08 a SUB-18).
--     El seed trae SUB-12/SUB-14/SUB-16; se agregan tres para
--     distribuir 60,000 estudiantes de forma creíble.
-- ------------------------------------------------------------
INSERT INTO deportivo.categorias (nombre, edad_min, edad_max, descripcion)
SELECT v.nombre, v.edad_min, v.edad_max, v.descripcion
FROM (VALUES ('SUB-08', 7,  8,  'Categoría sub-08 (carga masiva)'),
             ('SUB-10', 9,  10, 'Categoría sub-10 (carga masiva)'),
             ('SUB-18', 16, 18, 'Categoría sub-18 (carga masiva)')) AS v(nombre, edad_min, edad_max, descripcion)
WHERE NOT EXISTS (SELECT 1 FROM deportivo.categorias c WHERE c.nombre = v.nombre);

-- Categorías ordenadas por edad: rn 1..6 alineado con la edad
-- determinista 7+(g%6)*2 -> {7,9,11,13,15,17}.
CREATE TEMP TABLE _cats AS
SELECT id_categoria,
       ROW_NUMBER() OVER (ORDER BY edad_min) AS rn,
       COUNT(*) OVER ()                      AS n_cat,
       edad_min
FROM deportivo.categorias
WHERE activo = TRUE;

-- ============================================================
-- 1. PERSONAS (72,200)
--    Edad determinista alineada con categorías; cédulas únicas de
--    10 dígitos; correo como marcador de origen (@mass.sged.com).
-- ============================================================
INSERT INTO seguridad.personas (nombre, apellido, cedula, correo, telefono, fecha_nacimiento, activo)
SELECT nom.nombre,
       ape.apellido,
       LPAD((100000000 + g)::TEXT, 10, '0'),
       'est' || g || '@mass.sged.com',
       '09' || LPAD(((g * 7919) % 99999999)::TEXT, 8, '0'),
       CURRENT_DATE - make_interval(years => 7 + (g % 6) * 2, days => g % 330),
       (g % 97) <> 0
FROM generate_series(1, 60000) g
CROSS JOIN LATERAL (SELECT (ARRAY['Carlos','Juan','María','Sofía','Mateo','Valentina','Diego','Lucía','Andrés','Camila'])[1 + g % 10] AS nombre) nom
CROSS JOIN LATERAL (SELECT (ARRAY['García','Rodríguez','Martínez','López','Hernández','Torres','Ramírez','Flores','Vargas','Castillo'])[1 + (g * 3) % 10] AS apellido) ape;

INSERT INTO seguridad.personas (nombre, apellido, cedula, correo, telefono, fecha_nacimiento, activo)
SELECT nom.nombre,
       ape.apellido,
       LPAD((200000000 + g)::TEXT, 10, '0'),
       'rep' || g || '@mass.sged.com',
       '09' || LPAD(((g * 104729) % 99999999)::TEXT, 8, '0'),
       CURRENT_DATE - make_interval(years => 28 + g % 15, days => g % 330),
       TRUE
FROM generate_series(1, 12000) g
CROSS JOIN LATERAL (SELECT (ARRAY['Rosa','Elena','Fernando','Patricia','Miguel','Gabriela','Jorge','Mónica','Víctor','Paula'])[1 + g % 10] AS nombre) nom
CROSS JOIN LATERAL (SELECT (ARRAY['Pérez','Gómez','Ruiz','Díaz','Reyes','Cruz','Morales','Ortiz','Navarro','Salazar'])[1 + (g * 7) % 10] AS apellido) ape;

INSERT INTO seguridad.personas (nombre, apellido, cedula, correo, telefono, fecha_nacimiento, activo)
SELECT nom.nombre,
       ape.apellido,
       LPAD((300000000 + g)::TEXT, 10, '0'),
       'ent' || g || '@mass.sged.com',
       '09' || LPAD(((g * 1299709) % 99999999)::TEXT, 8, '0'),
       CURRENT_DATE - make_interval(years => 30 + g % 25, days => g % 330),
       TRUE
FROM generate_series(1, 200) g
CROSS JOIN LATERAL (SELECT (ARRAY['Luis','Pedro','Diego','Marco','Javier','Iván','Raúl','Néstor','Óscar','Hugo'])[1 + g % 10] AS nombre) nom
CROSS JOIN LATERAL (SELECT (ARRAY['Vera','Salazar','Castillo','Jiménez','Molina','Cabrera','Zambrano','Loor','Paredes','Cando'])[1 + (g * 5) % 10] AS apellido) ape;

-- ============================================================
-- 2. USUARIOS (72,200) + asignación de rol de aplicación
--    Hash BCrypt del seed (todas las cuentas comparten la contraseña
--    demo "sged2026"): es volumen sintético, no credencial real.
-- ============================================================
INSERT INTO seguridad.usuarios (id_persona, id_estado_general, username, password_hash, ultimo_acceso, activo)
SELECT p.id_persona, 1,
       split_part(p.correo, '@', 1),
       '$2a$12$.4TLX5R.HfQup7R0oOFeKuCCo.jUwIvyx9.DsyI95dM6RQsHFUdXm',
       NOW() - make_interval(hours => g % 720),
       p.activo
FROM generate_series(1, 60000) g
JOIN seguridad.personas p ON p.correo = 'est' || g || '@mass.sged.com';

INSERT INTO seguridad.usuarios (id_persona, id_estado_general, username, password_hash, ultimo_acceso, activo)
SELECT p.id_persona, 1,
       split_part(p.correo, '@', 1),
       '$2a$12$.4TLX5R.HfQup7R0oOFeKuCCo.jUwIvyx9.DsyI95dM6RQsHFUdXm',
       NOW() - make_interval(hours => g % 720),
       TRUE
FROM generate_series(1, 12000) g
JOIN seguridad.personas p ON p.correo = 'rep' || g || '@mass.sged.com';

INSERT INTO seguridad.usuarios (id_persona, id_estado_general, username, password_hash, ultimo_acceso, activo)
SELECT p.id_persona, 1,
       split_part(p.correo, '@', 1),
       '$2a$12$.4TLX5R.HfQup7R0oOFeKuCCo.jUwIvyx9.DsyI95dM6RQsHFUdXm',
       NOW() - make_interval(hours => g),
       TRUE
FROM generate_series(1, 200) g
JOIN seguridad.personas p ON p.correo = 'ent' || g || '@mass.sged.com';

INSERT INTO seguridad.usuario_rol (id_usuario, id_rol)
SELECT u.id_usuario, r.id_rol
FROM seguridad.usuarios u
JOIN seguridad.roles r ON r.nombre =
       CASE WHEN u.username LIKE 'est%' THEN 'ESTUDIANTE'
            WHEN u.username LIKE 'rep%' THEN 'REPRESENTANTE'
            WHEN u.username LIKE 'ent%' THEN 'ENTRENADOR'
       END
WHERE u.username ~ '^(est|rep|ent)[0-9]+$';

-- ============================================================
-- 3. ESTUDIANTES (60,000), REPRESENTANTES (12,000), ENTRENADORES (200)
-- ============================================================
INSERT INTO academico.estudiantes (id_persona, id_categoria, id_estado_general, codigo_estudiante,
                                   fecha_ingreso, peso, altura, id_posicion, rfid_codigo, activo)
SELECT p.id_persona,
       cat.id_categoria,
       CASE WHEN g % 23 = 0 THEN 2 ELSE 1 END,
       'EST-2025-' || LPAD(g::TEXT, 6, '0'),
       DATE '2023-09-01' + ((g % 700) || ' days')::interval,
       ROUND((22 + (7 + (g % 6) * 2) * 2.8 + (g % 50) / 10.0)::NUMERIC, 1),
       ROUND((1.02 + (7 + (g % 6) * 2) * 0.04 + (g % 15) / 200.0)::NUMERIC, 2),
       (g % 11) + 1,
       CASE WHEN g % 10 < 7 THEN 'RFID-' || LPAD(g::TEXT, 9, '0') END,
       (g % 97) <> 0
FROM generate_series(1, 60000) g
JOIN seguridad.personas p ON p.correo = 'est' || g || '@mass.sged.com'
JOIN _cats cat ON cat.rn = 1 + (g % cat.n_cat);

INSERT INTO academico.representantes (id_persona, id_usuario, parentesco, telefono_contacto, activo)
SELECT p.id_persona, u.id_usuario,
       (ARRAY['PADRE','MADRE','TÍO','ABUELO/A','HERMANO/A'])[1 + g % 5],
       '09' || LPAD(((g * 104729) % 99999999)::TEXT, 8, '0'),
       TRUE
FROM generate_series(1, 12000) g
JOIN seguridad.personas p ON p.correo = 'rep' || g || '@mass.sged.com'
JOIN seguridad.usuarios u ON u.username = 'rep' || g;

INSERT INTO deportivo.entrenadores (id_persona, id_usuario, id_especialidad, experiencia_anios, certificacion, activo)
SELECT p.id_persona, u.id_usuario,
       esp.id_especialidad,
       2 + (g % 18),
       (ARRAY['Licencia A','Licencia B','Licencia C'])[1 + g % 3],
       TRUE
FROM generate_series(1, 200) g
JOIN seguridad.personas p ON p.correo = 'ent' || g || '@mass.sged.com'
JOIN seguridad.usuarios u ON u.username = 'ent' || g
CROSS JOIN LATERAL (
    SELECT id_especialidad
    FROM deportivo.especialidades
    ORDER BY id_especialidad
    OFFSET g % 6 LIMIT 1
) esp;

-- Vínculo tutor-estudiante: el representante relativo r cubre los
-- estudiantes relativos r, r+12000, r+24000, r+36000, r+48000
-- (5 tutorados por representante, sin colisiones en UNIQUE).
INSERT INTO academico.representante_estudiante (id_representante, id_estudiante, relacion, contacto_principal, activo)
SELECT rep.id_representante,
       e.id_estudiante,
       rep.parentesco,
       j = 0,
       TRUE
FROM generate_series(1, 12000) r
CROSS JOIN generate_series(0, 4) j
CROSS JOIN _base b
JOIN academico.representantes rep ON rep.id_representante = b.rep_base + r
JOIN academico.estudiantes e ON e.codigo_estudiante = 'EST-2025-' || LPAD((r + j * 12000)::TEXT, 6, '0');

-- Consentimiento de tratamiento de datos por cada vínculo activo.
-- NOT EXISTS: si el seed ya otorgó el consentimiento de un vínculo
-- propio, no se duplica (índice único parcial de consentimientos).
INSERT INTO academico.consentimientos (id_representante, id_estudiante, alcance, otorgado_en, registrado_por_id_usuario)
SELECT re.id_representante, re.id_estudiante,
       'TRATAMIENTO_DATOS',
       NOW() - make_interval(days => (300 + ((re.id_representante * 7) % 60))::INT),
       (SELECT admin_usr FROM _base)
FROM academico.representante_estudiante re
WHERE NOT EXISTS (
    SELECT 1 FROM academico.consentimientos c
    WHERE c.id_representante = re.id_representante
      AND c.id_estudiante = re.id_estudiante
      AND c.alcance = 'TRATAMIENTO_DATOS'
);

-- ============================================================
-- 4. HORARIOS (600) Y SESIONES (6,000)
--    Cada entrenador: 3 bloques semanales (días distintos).
-- ============================================================
INSERT INTO deportivo.horarios_entrenamiento (id_entrenador, id_categoria, dia_semana, hora_inicio, hora_fin, campo, descripcion, activo)
SELECT ent.id_entrenador,
       cat.id_categoria,
       1 + (((h.g - 1) / 200) % 5),
       (ARRAY[TIME '07:00', TIME '16:00', TIME '17:30'])[1 + h.g % 3],
       (ARRAY[TIME '09:00', TIME '17:30', TIME '19:15'])[1 + h.g % 3],
       'Cancha ' || (1 + h.g % 3),
       'Bloque semanal (carga masiva)',
       TRUE
FROM generate_series(1, 600) h(g)
JOIN seguridad.usuarios u ON u.username = 'ent' || (1 + ((h.g - 1) % 200))
JOIN deportivo.entrenadores ent ON ent.id_usuario = u.id_usuario
JOIN _cats cat ON cat.rn = 1 + ((h.g / 200) % cat.n_cat);

INSERT INTO deportivo.sesiones_entrenamiento (id_horario, id_entrenador, id_categoria, fecha, hora_inicio, hora_fin, campo, estado)
SELECT ho.id_horario, ho.id_entrenador, ho.id_categoria,
       CURRENT_DATE - ((s % 360) + 1),
       ho.hora_inicio, ho.hora_fin, ho.campo,
       'FINALIZADA'
FROM generate_series(1, 6000) s
CROSS JOIN _base b
JOIN deportivo.horarios_entrenamiento ho ON ho.id_horario = b.hor_base + 1 + ((s - 1) % 600);

-- ============================================================
-- 5. ASISTENCIAS (900,000)
--    150 asistentes por sesión. La fórmula (s*97+i) % 60000 con
--    i en [0,149] garantiza estudiantes DISTINTOS dentro de cada
--    sesión -> respeta UNIQUE(id_sesion, id_estudiante) por
--    construcción, sin necesidad de ON CONFLICT.
--    Mezcla de estados: ~85% PRESENTE, 8% TARDE, 5% AUSENTE, 2% JUSTIFICADO.
-- ============================================================
INSERT INTO deportivo.asistencias (id_sesion, id_estudiante, hora_entrada, metodo, estado, observacion)
SELECT se.id_sesion,
       b.est_base + 1 + ((s * 97 + i) % 60000),
       CASE x.st WHEN 'PRESENTE' THEN se.hora_inicio + make_interval(mins => i % 25)
                 WHEN 'TARDE'    THEN se.hora_inicio + make_interval(mins => 25 + i % 15)
                 ELSE NULL END,
       (ARRAY['QR', 'RFID', 'MANUAL'])[1 + (s * 13 + i * 7) % 3],
       x.st,
       CASE WHEN x.st = 'JUSTIFICADO'                 THEN 'Justificada por el representante'
            WHEN x.st = 'AUSENTE' AND (s + i) % 7 = 0 THEN 'Sin aviso previo'
       END
FROM generate_series(1, 6000) s
CROSS JOIN generate_series(0, 149) i
CROSS JOIN _base b
JOIN deportivo.sesiones_entrenamiento se ON se.id_sesion = b.ses_base + s
CROSS JOIN LATERAL (
    SELECT CASE WHEN (s * 31 + i * 17) % 100 < 85 THEN 'PRESENTE'
                WHEN (s * 31 + i * 17) % 100 < 93 THEN 'TARDE'
                WHEN (s * 31 + i * 17) % 100 < 98 THEN 'AUSENTE'
                ELSE 'JUSTIFICADO' END AS st
) x;

-- ============================================================
-- 6. EVALUACIONES
--    Cabecera por cada sesión (6,000). Detalle por estudiante y
--    criterio solo para la muestra de las primeras 100 sesiones.
-- ============================================================
INSERT INTO deportivo.evaluaciones_diarias (id_sesion, id_entrenador, fecha, observacion_general, estado)
SELECT se.id_sesion, se.id_entrenador, se.fecha,
       'Sesión de rutina (carga masiva)',
       CASE WHEN se.fecha < CURRENT_DATE - INTERVAL '7 days' THEN 'FINALIZADA' ELSE 'BORRADOR' END
FROM _base b
JOIN deportivo.sesiones_entrenamiento se ON se.id_sesion > b.ses_base;

-- Mismos asistentes de las primeras 100 sesiones (misma fórmula).
INSERT INTO deportivo.evaluacion_estudiante (id_evaluacion, id_estudiante, id_categoria_dia, id_posicion_jugada)
SELECT ev.id_evaluacion,
       b.est_base + 1 + ((s * 97 + i) % 60000),
       se.id_categoria,
       (i % 11) + 1
FROM generate_series(1, 100) s
CROSS JOIN generate_series(0, 149) i
CROSS JOIN _base b
JOIN deportivo.sesiones_entrenamiento se ON se.id_sesion = b.ses_base + s
JOIN deportivo.evaluaciones_diarias ev ON ev.id_sesion = se.id_sesion;

INSERT INTO deportivo.detalle_evaluacion (id_evaluacion_estudiante, id_criterio, puntaje)
SELECT ee.id_evaluacion_estudiante,
       c.id_criterio,
       ROUND((5.0 + ((ee.id_evaluacion_estudiante * 7 + c.id_criterio * 13) % 51) / 10.0)::NUMERIC, 1)
FROM deportivo.evaluacion_estudiante ee
CROSS JOIN (SELECT id_criterio FROM deportivo.criterios_evaluacion WHERE activo = TRUE) c;

-- ============================================================
-- 7. PAGOS (220,000) Y NOTIFICACIONES (150,000)
--    Membresía ene-jul 2026 para los primeros 30,000 estudiantes:
--    el índice único parcial impide duplicar mes por estudiante y
--    aquí cada combinación se genera exactamente una vez.
-- ============================================================
INSERT INTO academico.pagos (id_estudiante, tipo, anio, mes, monto, fecha_pago, registrado_por_id_usuario)
SELECT b.est_base + g,
       'MEMBRESIA',
       2026,
       m,
       30 + (g % 4) * 5,
       make_date(2026, m, 1 + (g % 27)),
       b.admin_usr
FROM generate_series(1, 30000) g
CROSS JOIN generate_series(1, 7) m
CROSS JOIN _base b;

INSERT INTO academico.pagos (id_estudiante, tipo, monto, fecha_pago, registrado_por_id_usuario)
SELECT b.est_base + 1 + ((g * 137) % 60000),
       'DIARIO',
       3.50,
       CURRENT_DATE - (g % 55),
       b.admin_usr
FROM generate_series(1, 10000) g
CROSS JOIN _base b;

-- Notificación de asistencia dirigida al tutor correspondiente:
-- el tutor del estudiante relativo st es ((st-1) % 12000) + 1,
-- exactamente el vínculo creado en representante_estudiante.
INSERT INTO academico.notificaciones (id_representante, id_estudiante, tipo, mensaje, leida, created_at)
SELECT b.rep_base + (((q.st - 1) % 12000) + 1),
       b.est_base + q.st,
       'ASISTENCIA',
       'Asistencia registrada el ' || to_char(NOW() - make_interval(days => g % 80), 'DD/MM/YYYY'),
       (g % 3) = 0,
       NOW() - make_interval(days => g % 80, hours => g % 24)
FROM generate_series(1, 150000) g
CROSS JOIN _base b
CROSS JOIN LATERAL (SELECT (g % 60000) + 1 AS st) q;

-- ============================================================
-- 8. INVENTARIO: ARTÍCULOS (40), MOVIMIENTOS (50,000), ASIGNACIONES (20,000)
-- ============================================================
INSERT INTO inventario.articulos (nombre, tipo, talla, descripcion, stock_actual, stock_minimo, unidad_medida)
SELECT nombre, tipo, talla, descripcion, stock_actual, stock_minimo, unidad_medida
FROM (
    SELECT 'Uniforme oficial T-' || (ARRAY['S','M','L','XL'])[1 + g]          AS nombre, 'UNIFORME' AS tipo,
           (ARRAY['S','M','L','XL'])[1 + g]                                   AS talla,
           'Uniforme de juego (datos masivos)'                                AS descripcion,
           40 + (g * 37 % 160)                                                AS stock_actual,
           15                                                                 AS stock_minimo,
           'unidad'                                                           AS unidad_medida
    FROM generate_series(0, 3) g
    UNION ALL
    SELECT 'Uniforme alternativo T-' || (ARRAY['S','M','L','XL'])[1 + g], 'UNIFORME',
           (ARRAY['S','M','L','XL'])[1 + g],
           'Uniforme de entrenamiento (datos masivos)',
           40 + (g * 53 % 140), 10, 'unidad'
    FROM generate_series(0, 3) g
    UNION ALL
    SELECT 'Balón No.' || (ARRAY[3,4,5])[1 + g % 3] || (CASE WHEN g < 3 THEN ' Pro' ELSE ' Entrenamiento' END), 'BALON',
           NULL, 'Balón de fútbol (datos masivos)',
           20 + (g * 11 % 60), 8, 'unidad'
    FROM generate_series(0, 5) g
    UNION ALL
    SELECT 'Guante de portero T-' || (ARRAY['S','M','L','XL'])[1 + g], 'IMPLEMENTO',
           (ARRAY['S','M','L','XL'])[1 + g],
           'Guante de arquero (datos masivos)',
           10 + (g * 7 % 40), 5, 'par'
    FROM generate_series(0, 3) g
    UNION ALL
    SELECT 'Espinillera T-' || (ARRAY['XS','S','M','L'])[1 + g], 'IMPLEMENTO',
           (ARRAY['XS','S','M','L'])[1 + g],
           'Protección reglamentaria (datos masivos)',
           25 + (g * 13 % 75), 10, 'par'
    FROM generate_series(0, 3) g
    UNION ALL
    SELECT 'Zapatilla de césped T-' || (ARRAY['38','40','42','44'])[1 + g], 'OTRO',
           (ARRAY['38','40','42','44'])[1 + g],
           'Calzado deportivo (datos masivos)',
           8 + (g * 5 % 30), 4, 'par'
    FROM generate_series(0, 3) g
    UNION ALL
    SELECT 'Balón médico ' || (ARRAY['3 kg','5 kg'])[1 + g], 'BALON', NULL,
           'Implemento de fuerza (datos masivos)',
           6 + g * 4, 2, 'unidad'
    FROM generate_series(0, 1) g
    UNION ALL
    SELECT (ARRAY['Cono de entrenamiento','Peto numerado','Escalinata ágil','Banda elástica','Silbato profesional','Chaleco táctico'])[1 + g % 6]
           || (CASE WHEN g >= 6 THEN ' (lote B)' ELSE '' END), 'IMPLEMENTO', NULL,
           'Material de entrenamiento (datos masivos)',
           15 + (g * 17 % 85), 6, 'unidad'
    FROM generate_series(0, 11) g
) articulos;

-- El módulo 40 coincide con los 40 artículos recién creados:
-- todo movimiento apunta a un artículo del lote masivo.
INSERT INTO inventario.movimientos_stock (id_articulo, tipo_movimiento, cantidad, motivo, registrado_por_id_usuario, fecha_movimiento)
SELECT b.art_base + 1 + ((m.g * 29) % 40),
       CASE WHEN m.g % 10 < 5 THEN 'ENTRADA'
            WHEN m.g % 10 < 9 THEN 'SALIDA'
            ELSE 'AJUSTE' END,
       1 + (m.g % 50),
       CASE WHEN m.g % 10 < 5 THEN 'Compra a proveedor'
            WHEN m.g % 10 < 9 THEN 'Dotación / entrega'
            ELSE 'Ajuste por conteo físico' END,
       b.admin_usr,
       NOW() - make_interval(days => m.g % 180, hours => m.g % 24)
FROM generate_series(1, 50000) m(g)
CROSS JOIN _base b;

INSERT INTO inventario.asignaciones (id_articulo, cantidad, tipo_destinatario, id_estudiante, id_entrenador,
                                     fecha_asignacion, fecha_devolucion_esperada, fecha_devolucion_real, estado,
                                     registrado_por_id_usuario, observaciones)
SELECT b.art_base + 1 + ((a.g * 7) % 40),
       1 + a.g % 3,
       CASE WHEN a.g <= 15000 THEN 'ESTUDIANTE' ELSE 'ENTRENADOR' END,
       CASE WHEN a.g <= 15000 THEN b.est_base + 1 + ((a.g * 131) % 60000) END,
       CASE WHEN a.g > 15000 THEN b.ent_base + 1 + ((a.g - 15000) % 200) END,
       CURRENT_DATE - (a.g % 120),
       CURRENT_DATE - (a.g % 120) + 14,
       CASE WHEN a.g % 10 < 6 THEN CURRENT_DATE - (a.g % 120) + 9 END,
       CASE WHEN a.g % 10 < 6 THEN 'DEVUELTO'
            WHEN a.g % 10 < 9 THEN 'ASIGNADO'
            ELSE 'PERDIDO' END,
       b.admin_usr,
       'Asignación masiva'
FROM generate_series(1, 20000) a(g)
CROSS JOIN _base b;

-- ============================================================
-- 9. EQUIPOS (12), PARTIDOS (400), ESTADÍSTICAS (4,000)
-- ============================================================
INSERT INTO deportivo.equipos (id_categoria, id_estado_general, nombre_equipo, siglas, activo)
SELECT cat.id_categoria, 1,
       'Selección ' || cat.edad_min || '-' || (cat.edad_min + 1) || ' #' || (1 + g % 2),
       'SEL-' || LPAD(g::TEXT, 2, '0'),
       TRUE
FROM generate_series(1, 12) g
JOIN _cats cat ON cat.rn = 1 + (g % cat.n_cat);

INSERT INTO deportivo.partidos (id_equipo_local, id_equipo_visitante, fecha_partido, ubicacion, goles_local, goles_visitante)
SELECT b.eq_base + 1 + (p.g % 6),
       b.eq_base + 7 + (p.g % 6),
       CURRENT_DATE - (p.g % 300),
       'Cancha ' || (1 + p.g % 3),
       p.g % 5,
       (p.g * 3) % 4
FROM generate_series(1, 400) p(g)
CROSS JOIN _base b;

-- 10 estadísticas por partido; dentro de un mismo partido los 10
-- estudiantes son distintos ((p*13 + j*601) % 60000 con j en 0..9).
INSERT INTO deportivo.estadistica_partidos (id_partido, id_estudiante, goles, asistencias, tarjetas_amarillas, tarjetas_rojas, minutos_jugados)
SELECT b.par_base + 1 + ((e.g - 1) / 10),
       b.est_base + 1 + ((((e.g - 1) / 10) * 13 + (e.g % 10) * 601) % 60000),
       e.g % 3,
       (e.g / 7) % 2,
       (e.g % 11 = 0)::INT,
       0,
       60 + (e.g % 31)
FROM generate_series(1, 4000) e(g)
CROSS JOIN _base b;

ANALYZE;

COMMIT;

-- ============================================================
-- 10. VERIFICACIÓN DEL VOLUMEN (se ejecuta tras el commit)
-- ============================================================
WITH conteos AS (
    SELECT 'seguridad.personas' tabla, COUNT(*) registros FROM seguridad.personas
    UNION ALL SELECT 'seguridad.usuarios', COUNT(*) FROM seguridad.usuarios
    UNION ALL SELECT 'seguridad.usuario_rol', COUNT(*) FROM seguridad.usuario_rol
    UNION ALL SELECT 'academico.estudiantes', COUNT(*) FROM academico.estudiantes
    UNION ALL SELECT 'academico.representantes', COUNT(*) FROM academico.representantes
    UNION ALL SELECT 'academico.representante_estudiante', COUNT(*) FROM academico.representante_estudiante
    UNION ALL SELECT 'academico.consentimientos', COUNT(*) FROM academico.consentimientos
    UNION ALL SELECT 'academico.pagos', COUNT(*) FROM academico.pagos
    UNION ALL SELECT 'academico.notificaciones', COUNT(*) FROM academico.notificaciones
    UNION ALL SELECT 'deportivo.entrenadores', COUNT(*) FROM deportivo.entrenadores
    UNION ALL SELECT 'deportivo.horarios_entrenamiento', COUNT(*) FROM deportivo.horarios_entrenamiento
    UNION ALL SELECT 'deportivo.sesiones_entrenamiento', COUNT(*) FROM deportivo.sesiones_entrenamiento
    UNION ALL SELECT 'deportivo.asistencias', COUNT(*) FROM deportivo.asistencias
    UNION ALL SELECT 'deportivo.evaluaciones_diarias', COUNT(*) FROM deportivo.evaluaciones_diarias
    UNION ALL SELECT 'deportivo.evaluacion_estudiante', COUNT(*) FROM deportivo.evaluacion_estudiante
    UNION ALL SELECT 'deportivo.detalle_evaluacion', COUNT(*) FROM deportivo.detalle_evaluacion
    UNION ALL SELECT 'inventario.articulos', COUNT(*) FROM inventario.articulos
    UNION ALL SELECT 'inventario.movimientos_stock', COUNT(*) FROM inventario.movimientos_stock
    UNION ALL SELECT 'inventario.asignaciones', COUNT(*) FROM inventario.asignaciones
    UNION ALL SELECT 'deportivo.equipos', COUNT(*) FROM deportivo.equipos
    UNION ALL SELECT 'deportivo.partidos', COUNT(*) FROM deportivo.partidos
    UNION ALL SELECT 'deportivo.estadistica_partidos', COUNT(*) FROM deportivo.estadistica_partidos
)
SELECT * FROM conteos ORDER BY registros DESC;

DO $$
DECLARE
    v_total BIGINT;
BEGIN
    SELECT SUM(cnt) INTO v_total FROM (
        SELECT COUNT(*) cnt FROM seguridad.personas
        UNION ALL SELECT COUNT(*) FROM seguridad.usuarios
        UNION ALL SELECT COUNT(*) FROM seguridad.usuario_rol
        UNION ALL SELECT COUNT(*) FROM academico.estudiantes
        UNION ALL SELECT COUNT(*) FROM academico.representantes
        UNION ALL SELECT COUNT(*) FROM academico.representante_estudiante
        UNION ALL SELECT COUNT(*) FROM academico.consentimientos
        UNION ALL SELECT COUNT(*) FROM academico.pagos
        UNION ALL SELECT COUNT(*) FROM academico.notificaciones
        UNION ALL SELECT COUNT(*) FROM deportivo.entrenadores
        UNION ALL SELECT COUNT(*) FROM deportivo.horarios_entrenamiento
        UNION ALL SELECT COUNT(*) FROM deportivo.sesiones_entrenamiento
        UNION ALL SELECT COUNT(*) FROM deportivo.asistencias
        UNION ALL SELECT COUNT(*) FROM deportivo.evaluaciones_diarias
        UNION ALL SELECT COUNT(*) FROM deportivo.evaluacion_estudiante
        UNION ALL SELECT COUNT(*) FROM deportivo.detalle_evaluacion
        UNION ALL SELECT COUNT(*) FROM inventario.articulos
        UNION ALL SELECT COUNT(*) FROM inventario.movimientos_stock
        UNION ALL SELECT COUNT(*) FROM inventario.asignaciones
        UNION ALL SELECT COUNT(*) FROM deportivo.equipos
        UNION ALL SELECT COUNT(*) FROM deportivo.partidos
        UNION ALL SELECT COUNT(*) FROM deportivo.estadistica_partidos
    ) t;

    RAISE NOTICE '================================================';
    RAISE NOTICE 'TOTAL DE REGISTROS EN EL SISTEMA: %', v_total;
    IF v_total >= 1000000 THEN
        RAISE NOTICE 'REQUISITO CUMPLIDO: >= 1,000,000 de registros.';
    ELSE
        RAISE EXCEPTION 'REQUISITO NO CUMPLIDO: solo % registros.', v_total;
    END IF;
    RAISE NOTICE '================================================';
END $$;
