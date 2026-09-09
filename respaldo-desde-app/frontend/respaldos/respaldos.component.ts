import { Component, OnInit, inject, signal } from '@angular/core';
import { CommonModule } from '@angular/common';
import { CargandoComponent } from '../../core/cargando.component';
import { RespaldoInfo, RespaldoService } from './respaldo.service';

function formatoTamanio(bytes: number): string {
  if (bytes < 0) return '—';
  if (bytes < 1024) return `${bytes} B`;
  const kb = bytes / 1024;
  if (kb < 1024) return `${kb.toFixed(1)} KB`;
  return `${(kb / 1024).toFixed(2)} MB`;
}

@Component({
  selector: 'app-respaldos',
  standalone: true,
  imports: [CommonModule, CargandoComponent],
  template: `
    <div class="pantalla">
      <div class="encabezado">
        <h1 class="titulo-pantalla">Respaldos de la base de datos</h1>
        <p class="subtitulo-pantalla">Genera y descarga volcados completos (pg_dump) de la base PostgreSQL del sistema.</p>
      </div>

      <div class="card acciones">
        <button type="button" class="btn btn--primario" [disabled]="generando()" (click)="generar()">
          @if (generando()) { Generando respaldo… } @else { Generar nuevo respaldo }
        </button>
        @if (mensajeError()) {
          <p class="error">{{ mensajeError() }}</p>
        }
      </div>

      <div class="card tabla-card">
        @if (cargando()) {
          <app-cargando />
        } @else if (respaldos().length === 0) {
          <div class="vacio">
            <p class="vacio__titulo">Todavía no hay respaldos</p>
            <p class="vacio__texto">Genera el primero con el botón de arriba.</p>
          </div>
        } @else {
          <div class="tabla">
            <div class="fila fila--encabezado">
              <span>Archivo</span><span>Tamaño</span><span></span>
            </div>
            @for (r of respaldos(); track r.nombre) {
              <div class="fila">
                <span class="nombre">{{ r.nombre }}</span>
                <span>{{ formatoTamanio(r.tamanioBytes) }}</span>
                <a class="btn btn--ghost" [href]="urlDescarga(r.nombre)" target="_blank" rel="noopener">Descargar</a>
              </div>
            }
          </div>
        }
      </div>
    </div>
  `,
  styles: [`
    .pantalla { max-width: 900px; margin: 0 auto; padding: 1.5rem 1.25rem 3rem; display: flex; flex-direction: column; gap: 1.25rem; }
    .encabezado { display: flex; flex-direction: column; gap: .3rem; }
    .titulo-pantalla { font-size: 1.5rem; }
    .subtitulo-pantalla { color: var(--color-text-muted); font-size: .92rem; }
    .acciones { padding: 1.1rem 1.25rem; display: flex; flex-direction: column; gap: .6rem; align-items: flex-start; }
    .error { color: var(--color-danger, #c0392b); font-size: .85rem; }
    .tabla-card { padding: 1.1rem 1.25rem; }
    .tabla { display: flex; flex-direction: column; font-size: .88rem; }
    .fila { display: grid; grid-template-columns: 1fr 120px 110px; gap: .75rem; padding: .65rem 0; border-bottom: 1px solid var(--color-border-light); align-items: center; }
    .fila:last-child { border-bottom: none; }
    .fila--encabezado { font-weight: 700; color: var(--color-text-faint); font-size: .72rem; text-transform: uppercase; letter-spacing: .03em; }
    .nombre { font-family: monospace; font-size: .82rem; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .vacio { text-align: center; padding: 2rem .5rem; }
    .vacio__titulo { font-weight: 700; font-size: .95rem; }
    .vacio__texto { color: var(--color-text-muted); font-size: .85rem; margin-top: .25rem; }
  `],
})
export class RespaldosComponent implements OnInit {
  readonly formatoTamanio = formatoTamanio;

  private readonly servicio = inject(RespaldoService);

  readonly respaldos = signal<RespaldoInfo[]>([]);
  readonly cargando = signal(true);
  readonly generando = signal(false);
  readonly mensajeError = signal<string | null>(null);

  ngOnInit(): void {
    this.cargar();
  }

  cargar(): void {
    this.cargando.set(true);
    this.servicio.listar().subscribe({
      next: (r) => { this.respaldos.set(r); this.cargando.set(false); },
      error: () => { this.cargando.set(false); },
    });
  }

  generar(): void {
    this.generando.set(true);
    this.mensajeError.set(null);
    this.servicio.generar().subscribe({
      next: () => { this.generando.set(false); this.cargar(); },
      error: (err) => {
        this.generando.set(false);
        this.mensajeError.set('No se pudo generar el respaldo. ' + (err?.error?.message ?? ''));
      },
    });
  }

  urlDescarga(nombre: string): string {
    return this.servicio.urlDescarga(nombre);
  }
}
