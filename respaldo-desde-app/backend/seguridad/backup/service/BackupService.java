package org.uteq.backend.seguridad.backup.service;

import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Service;

import java.io.IOException;
import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.nio.file.StandardCopyOption;
import java.time.ZoneId;
import java.time.ZonedDateTime;
import java.time.format.DateTimeFormatter;
import java.util.Comparator;
import java.util.List;
import java.util.stream.Collectors;
import java.util.stream.Stream;

/**
 * Respaldos de la base de datos PostgreSQL, disparados desde la propia
 * aplicación (Examen Final, Administración de Bases de Datos: "debe existir
 * una opción dentro del sistema para generar o gestionar respaldos").
 *
 * Estrategia: invocar {@code pg_dump} como proceso externo (el binario del
 * cliente de PostgreSQL se instala en la imagen del backend, ver Dockerfile
 * -el repo de Ubuntu de esa imagen trae la 18.x, no la 16 del motor real-)
 * contra el servicio {@code postgres} de la red interna de Docker Compose
 * -host, puerto y nombre de base fijos porque los define esa red, igual que
 * hace JwtAuthenticationFilter con sus constantes de cookie- y guardar el
 * volcado en texto plano (formato -Fp) en un directorio dedicado dentro del
 * contenedor del backend. No requiere tocar el datasource JPA de la
 * aplicación: es un proceso aparte, de solo lectura sobre la base real.
 *
 * <p>Ese salto de version cliente/servidor (18 contra 16.14) tiene una
 * consecuencia real y verificada: pg_dump 18 agrega al volcado una linea
 * {@code SET transaction_timeout = 0;} -GUC que existe recien desde
 * PostgreSQL 17- que el motor 16 real rechaza con
 * "ERROR: unrecognized configuration parameter" al restaurar. Se detectó
 * restaurando un respaldo real completo contra una base de prueba limpia y
 * comparando conteos tabla por tabla (100% coincidentes pese al error: es
 * una sola linea de configuración de sesión, no un dato). {@link
 * #limpiarPreambuloIncompatible(Path)} la quita antes de dar el respaldo
 * por válido.</p>
 */
@Slf4j
@Service
@RequiredArgsConstructor
public class BackupService {

    private static final String PG_HOST = "postgres";
    private static final String PG_PORT = "5432";
    private static final String PG_DATABASE = "sged_db";
    private static final DateTimeFormatter NOMBRE_ARCHIVO =
            DateTimeFormatter.ofPattern("yyyyMMdd_HHmmss");

    @Value("${DB_USER:postgres}")
    private String dbUser;

    @Value("${DB_PASSWORD:changeme}")
    private String dbPassword;

    @Value("${backup.directorio:/app/backups}")
    private String directorioRespaldos;

    /**
     * Genera un nuevo respaldo con {@code pg_dump} y lo deja en el
     * directorio de respaldos. Devuelve el nombre del archivo creado.
     *
     * @throws IllegalStateException si pg_dump termina con código distinto
     *         de 0 (credenciales inválidas, base inalcanzable, etc.)
     */
    public String generarRespaldo() {
        try {
            Path dir = Paths.get(directorioRespaldos);
            Files.createDirectories(dir);

            String nombreArchivo = "sged_db_" +
                    ZonedDateTime.now(ZoneId.of("America/Guayaquil")).format(NOMBRE_ARCHIVO) + ".sql";
            Path destino = dir.resolve(nombreArchivo);

            ProcessBuilder pb = new ProcessBuilder(
                    "pg_dump",
                    "-h", PG_HOST,
                    "-p", PG_PORT,
                    "-U", dbUser,
                    "-d", PG_DATABASE,
                    "-F", "p",           // texto plano: legible y restaurable con psql -f
                    "--no-owner",
                    "--no-privileges",
                    "-f", destino.toString()
            );
            pb.environment().put("PGPASSWORD", dbPassword);
            pb.redirectErrorStream(false);

            Process proceso = pb.start();
            String salidaError;
            try (InputStream err = proceso.getErrorStream()) {
                salidaError = new String(err.readAllBytes());
            }
            int codigoSalida = proceso.waitFor();

            if (codigoSalida != 0) {
                Files.deleteIfExists(destino);
                log.error("pg_dump terminó con código {}: {}", codigoSalida, salidaError);
                throw new IllegalStateException(
                        "No se pudo generar el respaldo (pg_dump código " + codigoSalida + ")");
            }

            limpiarPreambuloIncompatible(destino);

            long tamanioBytes = Files.size(destino);
            log.info("Respaldo generado: {} ({} bytes)", nombreArchivo, tamanioBytes);
            return nombreArchivo;

        } catch (IOException | InterruptedException e) {
            if (e instanceof InterruptedException) {
                Thread.currentThread().interrupt();
            }
            throw new IllegalStateException("Error ejecutando pg_dump: " + e.getMessage(), e);
        }
    }

    /** Lista los respaldos existentes, más reciente primero. */
    public List<RespaldoInfo> listar() {
        Path dir = Paths.get(directorioRespaldos);
        if (!Files.isDirectory(dir)) {
            return List.of();
        }
        try (Stream<Path> archivos = Files.list(dir)) {
            return archivos
                    .filter(p -> p.toString().endsWith(".sql"))
                    .map(this::aRespaldoInfo)
                    .sorted(Comparator.comparing(RespaldoInfo::nombre).reversed())
                    .collect(Collectors.toList());
        } catch (IOException e) {
            throw new IllegalStateException("No se pudo listar los respaldos: " + e.getMessage(), e);
        }
    }

    /** Ruta absoluta de un respaldo por nombre, para descargarlo. */
    public Path rutaDe(String nombreArchivo) {
        // Evita path traversal: el nombre no puede contener separadores.
        if (nombreArchivo.contains("/") || nombreArchivo.contains("\\") || nombreArchivo.contains("..")) {
            throw new IllegalArgumentException("Nombre de archivo inválido");
        }
        Path ruta = Paths.get(directorioRespaldos).resolve(nombreArchivo);
        if (!Files.isRegularFile(ruta)) {
            throw new IllegalArgumentException("Respaldo no encontrado: " + nombreArchivo);
        }
        return ruta;
    }

    /**
     * Quita del volcado la línea {@code SET transaction_timeout = 0;} que
     * pg_dump 18 antepone (GUC desde PostgreSQL 17) y que Postgres 16, el
     * motor real, no reconoce al restaurar. Es una línea de configuración de
     * sesión que agrega pg_dump por su cuenta -no un dato del usuario- así
     * que quitarla no toca ninguna fila del respaldo. Se recorre el archivo
     * en streaming (no se carga en memoria) porque el volcado real supera
     * los 100 MB.
     */
    private void limpiarPreambuloIncompatible(Path archivo) throws IOException {
        Path temporal = archivo.resolveSibling(archivo.getFileName() + ".tmp");
        try (var lector = Files.newBufferedReader(archivo);
             var escritor = Files.newBufferedWriter(temporal)) {
            String linea;
            while ((linea = lector.readLine()) != null) {
                if (linea.startsWith("SET transaction_timeout")) {
                    continue;
                }
                escritor.write(linea);
                escritor.newLine();
            }
        }
        Files.move(temporal, archivo, StandardCopyOption.REPLACE_EXISTING);
    }

    private RespaldoInfo aRespaldoInfo(Path p) {
        try {
            return new RespaldoInfo(p.getFileName().toString(), Files.size(p));
        } catch (IOException e) {
            return new RespaldoInfo(p.getFileName().toString(), -1);
        }
    }

    public record RespaldoInfo(String nombre, long tamanioBytes) {}
}
