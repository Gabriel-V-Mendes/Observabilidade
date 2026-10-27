.DEFAULT_GOAL := help
SHELL := /bin/bash

.PHONY: help up down restart ps logs test lint smoke incident secrets

help: ## Lista todos os comandos disponíveis no projeto
	@grep -E '^[a-zA-Z0-9_-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

up: ## Sobe toda a stack (FastAPI + Prometheus + Node Exporter + Loki + Alloy + Alertmanager + Grafana) com 1 comando
	docker compose up -d --build --wait

down: ## Derruba todos os containers da stack (adicione V=-v para remover volumes)
	docker compose down $(V)

restart: down up ## Reinicia toda a stack limpa

ps: ## Mostra o status e healthchecks dos containers
	docker compose ps

logs: ## Exibe os logs em tempo real da API e do coletor Grafana Alloy
	docker compose logs -f app alloy

test: ## Executa a suíte de testes automatizados (pytest + cobertura) da API instrumentada
	docker run --rm -e PYTHONDONTWRITEBYTECODE=1 -e COVERAGE_FILE=/tmp/.coverage \
		-v "$$PWD/app:/app:ro" -w /app python:3.12-slim-bookworm \
		sh -c "pip install -q --no-cache-dir --root-user-action=ignore -r requirements-dev.txt && pytest -v -o cache_dir=/tmp/pytest_cache --cov=src --cov-fail-under=90"

lint: ## Valida código Python (Ruff), regras do Prometheus (promtool) e config do Alertmanager (amtool)
	docker run --rm -v "$$PWD/app:/app:ro" -w /app ghcr.io/astral-sh/ruff:0.9.2 check --no-cache src tests
	docker run --rm --entrypoint promtool -v "$$PWD/monitoring/prometheus:/etc/prometheus:ro" \
		prom/prometheus:v3.2.1 check config /etc/prometheus/prometheus.yml
	docker run --rm --entrypoint promtool -v "$$PWD/monitoring/prometheus:/etc/prometheus:ro" \
		prom/prometheus:v3.2.1 check rules /etc/prometheus/recording_rules.yml /etc/prometheus/alerts.yml
	docker run --rm --entrypoint amtool -v "$$PWD/monitoring/alertmanager:/etc/alertmanager:ro" \
		prom/alertmanager:v0.28.0 check-config /etc/alertmanager/alertmanager.yml
	@echo "✅ Código Python, Prometheus (config + recording/alert rules) e Alertmanager válidos!"

smoke: ## Valida todos os endpoints, métricas RED, logs no Loki via Alloy, Grafana e Runbooks
	chmod +x ./scripts/smoke-test.sh
	./scripts/smoke-test.sh

incident: ## Provoca incidente real (Burn Rate + queda do container app) e mede o Tempo de Detecção (TTD) e Recuperação (TTR)
	chmod +x ./scripts/simulate-incident.sh
	./scripts/simulate-incident.sh

secrets: ## Verifica com Gitleaks que nenhum segredo entrou no histórico Git
	docker run --rm -v "$$PWD:/repo" ghcr.io/gitleaks/gitleaks:v8.30.1 git /repo --redact --verbose --exit-code 1
