# Proyecto de Administración de Bases de Datos — revisión autónoma
SHELL := /bin/bash
.DEFAULT_GOAL := up

.PHONY: up setup evidencia backup restaurar limpieza down clean help

PG := docker exec -i sged_admin_bd psql -U postgres -d sged_db

help:
	@echo "make up          levanta PostgreSQL 16 (puerto host 5434)"
	@echo "make setup       esquema + seed + roles + 1.86M registros + auditoria + indices (~3 min)"
	@echo "make evidencia   regenera todas las evidencias en docs/admin/evidencias/"
	@echo "make backup      respaldo logico verificado con retencion"
	@echo "make restaurar   simulacro de recuperacion validado"
	@echo "make limpieza    purga el lote masivo dejando la base semilla (~17 s)"
	@echo "make down        apaga el contenedor (conserva datos)"
	@echo "make clean       apaga y ELIMINA el volumen (reinicio total)"

up:
	docker compose up -d --wait
	@echo "PostgreSQL listo en localhost:5434 (bd: sged_db, user: postgres, pass: postgres)"

## Reproduccion completa desde cero, en orden y sin pasos manuales.
## Cada script es idempotente o transaccional; 02 aborta si ya se aplico.
setup: up
	$(PG) -v ON_ERROR_STOP=1 -q -f /dev/stdin < db/esquema-base.sql
	$(PG) -v ON_ERROR_STOP=1 -q -f /dev/stdin < db/seed.sql
	$(PG) -v ON_ERROR_STOP=1 -q -f /dev/stdin < db/admin/01-usuarios-roles.sql
	docker exec -i sged_admin_bd psql -U postgres -d sged_db -v ON_ERROR_STOP=1 < db/admin/02-datos-masivos.sql
	$(PG) -v ON_ERROR_STOP=1 -q -f /dev/stdin < db/admin/03-auditoria.sql
	$(PG) -v ON_ERROR_STOP=1 -q -f /dev/stdin < db/admin/04-optimizacion.sql
	@echo ""
	@echo "Setup completo. Registros esperados: >= 1,000,000 (ver docs/admin/evidencias/)."

evidencia:
	./scripts/evidencia-admin.sh todo

backup:
	./db/admin/backups/backup_completo.sh

restaurar:
	./db/admin/backups/restaurar.sh

limpieza:
	docker exec -i sged_admin_bd psql -U postgres -d sged_db -v ON_ERROR_STOP=1 < db/admin/99-limpieza.sql

down:
	docker compose down

clean:
	docker compose down -v --remove-orphans
