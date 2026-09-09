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
 * cliente de PostgreSQL 16 se instala en la imagen del backend, ver
 * Dockerfile) contra el servicio {@code postgres} de la red interna de
 * Docker Compose -host, puerto y nombre de base fijos porque los define esa
 * red, igual que hace JwtAuthenticationFilter con sus constantes de cookie-
 * y guardar el volcado en texto plano (formato -Fp) en un directorio
 * dedicado dentro del contenedor del backend. No requiere tocar el
 * datasource JPA de la aplicación: es un proceso aparte, de solo lectura
 * sobre la base real.
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

    private RespaldoInfo aRespaldoInfo(Path p) {
        try {
            return new RespaldoInfo(p.getFileName().toString(), Files.size(p));
        } catch (IOException e) {
            return new RespaldoInfo(p.getFileName().toString(), -1);
        }
    }

    public record RespaldoInfo(String nombre, long tamanioBytes) {}
}
