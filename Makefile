.DEFAULT_GOAL := help
COMPOSE := docker compose
PROD := docker compose -f docker-compose.prod.yml

SIM := docker compose --profile sim

# Target `local-*`: menjalankan API, worker, dan web langsung di host tanpa Docker.
-include Makefile.local

.PHONY: help up down logs build migrate revision downgrade seed test lint shell psql redis-cli \
        worker-logs worker-restart \
        sim-up sim-down sim-logs agent-up agent-down agent-logs \
        install prod-up prod-down prod-logs prod-restart prod-build prod-migrate prod-shell \
        prod-ps backup restore bundle trust-ca license-keygen

help: ## Tampilkan daftar perintah
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

up: ## Nyalakan seluruh stack (termasuk edge agent)
	$(COMPOSE) up -d --build

down: ## Matikan stack (volume tetap)
	$(COMPOSE) down

logs: ## Ikuti log semua service
	$(COMPOSE) logs -f

build: ## Build ulang image
	$(COMPOSE) build

migrate: ## Jalankan migrasi Alembic ke revisi terbaru
	$(COMPOSE) run --rm api alembic upgrade head

revision: ## Buat migrasi baru: make revision m="pesan"
	$(COMPOSE) run --rm api alembic revision --autogenerate -m "$(m)"

downgrade: ## Mundur satu revisi
	$(COMPOSE) run --rm api alembic downgrade -1

seed: ## Isi data awal (plans)
	$(COMPOSE) run --rm api python -m app.db.seed

test: ## Jalankan pytest
	$(COMPOSE) run --rm api pytest -q

lint: ## Ruff + format check
	$(COMPOSE) run --rm api ruff check app
	$(COMPOSE) run --rm api ruff format --check app

shell: ## Shell di container api
	$(COMPOSE) exec api bash

psql: ## psql ke database
	$(COMPOSE) exec db psql -U $${POSTGRES_USER:-scada} -d $${POSTGRES_DB:-scada}

redis-cli: ## redis-cli
	$(COMPOSE) exec redis redis-cli

worker-logs: ## Ikuti log worker (historian, alarm, retensi, watchdog)
	$(COMPOSE) logs -f worker

worker-restart: ## Nyalakan ulang worker
	$(COMPOSE) restart worker

# ─── Simulator & edge agent ──────────────────────────────────────────────────
# Keduanya di profil compose terpisah supaya `make up` sehari-hari tetap ringan.

sim-up: ## Nyalakan simulator perangkat (Modbus, MQTT, OPC UA)
	$(SIM) up -d --build mosquitto modbus-sim opcua-sim mqtt-sim

sim-down: ## Matikan simulator
	$(SIM) stop mosquitto modbus-sim opcua-sim mqtt-sim

sim-logs: ## Ikuti log simulator
	$(SIM) logs -f mosquitto modbus-sim opcua-sim mqtt-sim

agent-up: ## Nyalakan ulang edge agent (tanpa rebuild seluruh stack)
	$(COMPOSE) up -d --build agent

agent-down: ## Matikan edge agent
	$(COMPOSE) stop agent

agent-logs: ## Ikuti log edge agent
	$(COMPOSE) logs -f agent

# ─── Produksi / on-premise ───────────────────────────────────────────────────
# Semuanya memakai docker-compose.prod.yml; hanya Caddy yang membuka port.

install: ## Pasang instalasi baru (interaktif, membuat .env + admin pertama)
	./install.sh

prod-up: ## Nyalakan stack produksi
	$(PROD) up -d

prod-down: ## Matikan stack produksi (volume tetap)
	$(PROD) down

prod-restart: ## Muat ulang konfigurasi dan nyalakan ulang
	$(PROD) up -d --force-recreate

prod-pull: ## Tarik image terbaru dari ghcr.io (sebelum prod-restart)
	$(PROD) pull

prod-build: ## Build image lokal (hanya untuk pengembangan, prod memakai ghcr.io)
	$(PROD) build

prod-migrate: ## Migrasi Alembic di stack produksi
	$(PROD) run --rm api alembic upgrade head

prod-logs: ## Ikuti log stack produksi
	$(PROD) logs -f --tail=100

prod-ps: ## Status container produksi
	$(PROD) ps

prod-shell: ## Shell di container api produksi
	$(PROD) exec api bash

agent-prod-logs: ## Ikuti log edge agent (stack produksi)
	$(PROD) logs -f agent

agent-prod-restart: ## Restart edge agent produksi
	$(PROD) restart agent

agent-enroll: ## Daftarkan edge agent: make agent-enroll code=enr_xxxx
	@[ -n "$(code)" ] || (echo "\033[31mError:\033[0m Sertakan enrollment code: make agent-enroll code=enr_xxxx"; exit 1)
	@ENV_FILE="$(or $(ENV_FILE),.env)"; \
	 if grep -q '^AGENT_ENROLLMENT_CODE=' "$$ENV_FILE" 2>/dev/null; then \
	     sed -i.bak "s|^AGENT_ENROLLMENT_CODE=.*|AGENT_ENROLLMENT_CODE=$(code)|" "$$ENV_FILE" && rm -f "$$ENV_FILE.bak"; \
	 else \
	     echo "AGENT_ENROLLMENT_CODE=$(code)" >> "$$ENV_FILE"; \
	 fi; \
	 echo "\033[32m✔\033[0m Enrollment code disimpan ke $$ENV_FILE"
	$(PROD) restart agent
	@echo "\033[32m✔\033[0m Agent di-restart. Pantau log: make agent-prod-logs"

backup: ## Cadangkan database + rahasia ke ./backups
	./infra/scripts/backup.sh

restore: ## Pulihkan dari dump: make restore f=backups/scada-….dump
	./infra/scripts/restore.sh "$(f)"

bundle: ## Paket instalasi offline (air-gapped) → scada-bundle-*.tar.gz
	./infra/scripts/bundle.sh save

trust-ca: ## Ambil sertifikat CA internal Caddy untuk dibagikan ke klien
	./infra/scripts/trust-ca.sh

license-keygen: ## Buat pasangan kunci penandatangan lisensi (sisi vendor)
	python3 tools/license/issue_license.py keygen
