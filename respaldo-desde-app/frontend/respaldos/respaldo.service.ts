import { Injectable, inject } from '@angular/core';
import { HttpClient } from '@angular/common/http';

export interface RespaldoInfo {
  nombre: string;
  tamanioBytes: number;
}

@Injectable({ providedIn: 'root' })
export class RespaldoService {
  private readonly http = inject(HttpClient);

  listar() {
    return this.http.get<RespaldoInfo[]>('/api/admin/backups');
  }

  generar() {
    return this.http.post<RespaldoInfo>('/api/admin/backups', {});
  }

  urlDescarga(nombre: string): string {
    return `/api/admin/backups/${encodeURIComponent(nombre)}`;
  }
}
