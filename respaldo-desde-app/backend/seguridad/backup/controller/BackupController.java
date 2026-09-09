package org.uteq.backend.seguridad.backup.controller;

import lombok.RequiredArgsConstructor;
import org.springframework.core.io.FileSystemResource;
import org.springframework.core.io.Resource;
import org.springframework.http.ContentDisposition;
import org.springframework.http.HttpHeaders;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.security.access.prepost.PreAuthorize;
import org.springframework.web.bind.annotation.*;
import org.uteq.backend.seguridad.backup.service.BackupService;

import java.nio.file.Path;
import java.util.List;
import java.util.Map;

/**
 * Respaldos de la base de datos, disparados y descargados desde la propia
 * aplicación. Solo ADMINISTRADOR: generar y descargar un volcado completo
 * de la base es una operación sensible (expone todos los datos del
 * sistema), igual de restringida que /api/admin/auditorias.
 */
@RestController
@RequestMapping("/api/admin/backups")
@RequiredArgsConstructor
@PreAuthorize("hasRole('ADMINISTRADOR')")
public class BackupController {

    private final BackupService backupService;

    /** Dispara un nuevo respaldo con pg_dump y devuelve su nombre y tamaño. */
    @PostMapping
    public ResponseEntity<Map<String, Object>> generar() {
        String nombreArchivo = backupService.generarRespaldo();
        BackupService.RespaldoInfo info = backupService.listar().stream()
                .filter(r -> r.nombre().equals(nombreArchivo))
                .findFirst()
                .orElse(new BackupService.RespaldoInfo(nombreArchivo, -1));
        return ResponseEntity.ok(Map.of(
                "nombre", info.nombre(),
                "tamanioBytes", info.tamanioBytes()
        ));
    }

    /** Lista los respaldos existentes, más reciente primero. */
    @GetMapping
    public ResponseEntity<List<BackupService.RespaldoInfo>> listar() {
        return ResponseEntity.ok(backupService.listar());
    }

    /** Descarga un respaldo puntual como archivo .sql. */
    @GetMapping("/{nombreArchivo}")
    public ResponseEntity<Resource> descargar(@PathVariable String nombreArchivo) {
        Path ruta = backupService.rutaDe(nombreArchivo);
        Resource recurso = new FileSystemResource(ruta);
        return ResponseEntity.ok()
                .contentType(MediaType.APPLICATION_OCTET_STREAM)
                .header(HttpHeaders.CONTENT_DISPOSITION,
                        ContentDisposition.attachment().filename(nombreArchivo).build().toString())
                .body(recurso);
    }
}
