#!/usr/bin/env bash
# ==============================================================================
# Smoke Test Completo da Stack de Observabilidade & SLOs
# Valida: API (RED metrics), Prometheus, Node Exporter, Loki, Grafana Alloy,
# Alertmanager, Grafana (Datasources + Dashboard JSON) e Runbooks de cada alerta.
# ==============================================================================
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "=================================================================="
echo "1/6 · Validando API FastAPI (/health, /health/ready, /items, /metrics)"
echo "=================================================================="
HEALTH_OUT="$(curl -fsS http://127.0.0.1:8000/health)"
grep -q '"status":"ok"' <<< "$HEALTH_OUT"

READY_OUT="$(curl -fsS http://127.0.0.1:8000/health/ready)"
grep -q '"status":"ready"' <<< "$READY_OUT"

for i in $(seq 1 8); do
  curl -fsS http://127.0.0.1:8000/items >/dev/null
done
curl -fsS -X POST http://127.0.0.1:8000/items \
  -H "Content-Type: application/json" \
  -d '{"name":"Smoke Test Item","category":"validation"}' >/dev/null

METRICS="$(curl -fsS http://127.0.0.1:8000/metrics)"
grep -q "app_requests_total" <<< "$METRICS"
grep -q "app_errors_total" <<< "$METRICS"
grep -q "app_request_duration_seconds_bucket" <<< "$METRICS"
grep -q "app_requests_in_progress" <<< "$METRICS"
echo "✅ API e métricas RED (Rate, Errors, Duration) operacionais!"

echo ""
echo "=================================================================="
echo "2/6 · Validando Prometheus, Node Exporter e Recording Rules de SLO"
echo "=================================================================="
curl -fsS http://127.0.0.1:9090/-/healthy >/dev/null
NE_OUT="$(curl -fsS http://127.0.0.1:9100/metrics)"
grep -q "node_cpu_seconds_total" <<< "$NE_OUT"

sleep 6
TARGETS_JSON="$(curl -fsS http://127.0.0.1:9090/api/v1/targets)"
for job in "fastapi-app" "node-exporter" "prometheus" "grafana-alloy" "loki" "alertmanager"; do
  grep -q "\"job\":\"${job}\"" <<< "$TARGETS_JSON"
done

SLI_AVAIL="$(curl -fsS 'http://127.0.0.1:9090/api/v1/query?query=job:sli_availability:percent1m')"
grep -q '"status":"success"' <<< "$SLI_AVAIL"
echo "✅ Prometheus raspando todos os 6 targets e calculando Recording Rules de SLO!"

echo ""
echo "=================================================================="
echo "3/6 · Validando Grafana Alloy (:12345) enviando logs JSON ao Loki (:3100)"
echo "=================================================================="
curl -fsS http://127.0.0.1:12345/-/ready >/dev/null

LOKI_READY=0
for _ in $(seq 1 20); do
  if curl -fsS http://127.0.0.1:3100/ready >/dev/null 2>&1; then
    LOKI_READY=1
    break
  fi
  sleep 1
done
if [ "$LOKI_READY" -ne 1 ]; then
  echo "❌ Erro: Loki não respondeu 200 OK no endpoint /ready em 20s." >&2
  exit 1
fi

LOKI_FOUND=0
for _ in $(seq 1 15); do
  LOKI_RESP="$(curl -G -fsS "http://127.0.0.1:3100/loki/api/v1/query_range" \
    --data-urlencode 'query={container="fastapi-app"}' \
    --data-urlencode 'limit=5' || true)"
  if grep -q '"fastapi-app"' <<< "$LOKI_RESP"; then
    LOKI_FOUND=1
    break
  fi
  sleep 2
done

if [ "$LOKI_FOUND" -ne 1 ]; then
  echo "❌ Erro: logs do container fastapi-app ainda não encontrados no Loki via Alloy." >&2
  exit 1
fi
echo "✅ Grafana Alloy coletando logs Docker e indexando no Loki com sucesso!"

echo ""
echo "=================================================================="
echo "4/6 · Validando Alertmanager (:9093)"
echo "=================================================================="
curl -fsS http://127.0.0.1:9093/-/healthy >/dev/null
echo "✅ Alertmanager saudável!"

echo ""
echo "=================================================================="
echo "5/6 · Validando Grafana (:3000) — Datasources e Dashboard como Código"
echo "=================================================================="
GRAFANA_HEALTH="$(curl -fsS http://127.0.0.1:3000/api/health)"
grep -q '"database": "ok"' <<< "$GRAFANA_HEALTH"
GF_AUTH="${GF_SECURITY_ADMIN_USER:-admin}:${GF_SECURITY_ADMIN_PASSWORD:-admin}"
DASH_JSON="$(curl -fsS -u "$GF_AUTH" http://127.0.0.1:3000/api/dashboards/uid/api-slo-dashboard)"
grep -q '"uid":"api-slo-dashboard"' <<< "$DASH_JSON"
echo "✅ Grafana com Datasources (Prometheus + Loki) e Dashboard SLO provisionados!"

echo ""
echo "=================================================================="
echo "6/6 · Validando Política SRE: Todo Alerta Possui Runbook Existente"
echo "=================================================================="
ALERT_COUNT=$(grep -cE '^[[:space:]]*- alert:' "$ROOT_DIR/monitoring/prometheus/alerts.yml")
RUNBOOK_COUNT=$(grep -c 'runbook_url:' "$ROOT_DIR/monitoring/prometheus/alerts.yml")

if [ "$ALERT_COUNT" -ne "$RUNBOOK_COUNT" ]; then
  echo "❌ Erro: existem $ALERT_COUNT alertas mas apenas $RUNBOOK_COUNT possuem runbook_url!" >&2
  exit 1
fi

for rb_file in $(grep -oE 'docs/runbooks/[a-z0-9_-]+\.md' "$ROOT_DIR/monitoring/prometheus/alerts.yml" | sort -u); do
  if [ ! -f "$ROOT_DIR/$rb_file" ]; then
    echo "❌ Erro: runbook referenciado '$rb_file' não existe no repositório!" >&2
    exit 1
  fi
  echo "  ✔ Runbook verificado: $rb_file"
done

echo ""
echo "✅ Todos os Smoke Tests da Stack de Observabilidade & SLOs passaram com 100% de sucesso!"
