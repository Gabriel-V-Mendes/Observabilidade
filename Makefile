.DEFAULT_GOAL := help
SHELL := /bin/bash

.PHONY: help up down restart ps logs test lint smoke incident gameday secrets

help: ## Lista todos os comandos disponíveis no projeto
	@grep -E '^[a-zA-Z0-9_-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

up: ## Sobe toda a stack (FastAPI + Webhook Receiver + Prometheus + Node Exporter + Loki + Alloy + Alertmanager + Grafana) com 1 comando
	docker compose up -d --build --wait

down: ## Derruba todos os containers da stack (adicione V=-v para remover volumes)
	docker compose down $(V)

restart: down up ## Reinicia toda a stack limpa

ps: ## Mostra o status e healthchecks dos containers
	docker compose ps

logs: ## Exibe os logs em tempo real da API, do Webhook Receiver e do coletor Grafana Alloy
	docker compose logs -f app webhook-receiver alloy

test: ## Executa a suíte de testes automatizados (pytest + cobertura) da API e do receptor de webhooks
	docker run --rm -e PYTHONDONTWRITEBYTECODE=1 -e COVERAGE_FILE=/tmp/.coverage \
		-v "$$PWD/app:/app:ro" -v "$$PWD/webhook-receiver:/webhook-receiver:ro" -w /app python:3.12-slim-bookworm \
		sh -c "pip install -q --no-cache-dir --root-user-action=ignore -r requirements-dev.txt && pytest -v -o cache_dir=/tmp/pytest_cache --cov=src --cov-fail-under=90 && cd /webhook-receiver && pytest -v -o cache_dir=/tmp/pytest_cache_wr --cov=src --cov-fail-under=90"

lint: ## Valida código Python (Ruff), regras do Prometheus (promtool) e config do Alertmanager (amtool)
	docker run --rm -v "$$PWD/app:/app:ro" -v "$$PWD/webhook-receiver:/webhook-receiver:ro" -w /app ghcr.io/astral-sh/ruff:0.17.4 check --no-cache /app/src /app/tests /webhook-receiver/src /webhook-receiver/tests
	docker run --rm --entrypoint promtool -v "$$PWD/monitoring/prometheus:/etc/prometheus:ro" \
		prom/prometheus:v3.16.0 check config /etc/prometheus/prometheus.yml
	docker run --rm --entrypoint promtool -v "$$PWD/monitoring/prometheus:/etc/prometheus:ro" \
		prom/prometheus:v3.16.0 check rules /etc/prometheus/recording_rules.yml /etc/prometheus/alerts.yml
	docker run --rm --entrypoint amtool -v "$$PWD/monitoring/alertmanager:/etc/alertmanager:ro" \
		prom/alertmanager:v0.34.2 check-config /etc/alertmanager/alertmanager.yml
	@echo "✅ Código Python (API + Webhook Receiver), Prometheus (config + recording/alert rules) e Alertmanager válidos!"

smoke: ## Valida todos os 8 serviços, métricas RED, logs no Loki via Alloy, receptor de webhooks, Grafana e Runbooks
	chmod +x ./scripts/smoke-test.sh
	./scripts/smoke-test.sh

gameday: ## Executa o exercício de Game Day (Burn Rate + queda de componente) medindo TTD (notificação entregue no receptor externo) e TTR
	chmod +x ./scripts/simulate-incident.sh
	./scripts/simulate-incident.sh

incident: gameday ## Alias para make gameday (compatibilidade com CI)

secrets: ## Verifica com Gitleaks que nenhum segredo entrou no histórico Git
	docker run --rm -v "$$PWD:/repo" ghcr.io/gitleaks/gitleaks:v8.30.1 git /repo --redact --verbose --exit-code 1
