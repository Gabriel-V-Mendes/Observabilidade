#!/usr/bin/env bash
# ==============================================================================
# Simulação Automatizada de Incidente & Medição de TTD (Time to Detect) e TTR
#
# Executa duas etapas práticas exigidas no Projeto 4:
#   Etapa 1 -> Queima de Error Budget (`SLOErrorBudgetBurnFast` + `HighErrorRate`)
#              Sustenta falhas HTTP 500 via modo chaos/rajada e cronometra
#              quantos segundos o Prometheus/Alertmanager levam para detectar e
#              notificar o receptor webhook.
#   Etapa 2 -> Derrubada Proposital de Componente (`docker compose stop app`)
#              Para o container da API de propósito, mede o tempo exato (em s)
#              até `up == 0` (Pending) e até o alerta `TargetDown` entrar em
#              `firing` (TTD), restaura o componente e mede o tempo de
#              recuperação (TTR).
# ==============================================================================
set -euo pipefail

PROM_URL="http://127.0.0.1:9090"
APP_URL="http://127.0.0.1:8000"

query_metric() {
  local expr="$1"
  python3 -c "
import urllib.request, urllib.parse, json, sys
try:
    url = '${PROM_URL}/api/v1/query?' + urllib.parse.urlencode({'query': sys.argv[1]})
    req = urllib.request.urlopen(url, timeout=2)
    data = json.loads(req.read().decode())
    res = data.get('data', {}).get('result', [])
    if res:
        print(float(res[0]['value'][1]))
        sys.exit(0)
except Exception:
    pass
print('0')
" "$expr"
}

get_alert_state() {
  local alertname="$1"
  local job="${2:-}"
  python3 -c "
import urllib.request, json, sys
target_alert = sys.argv[1]
target_job = sys.argv[2]
try:
    req = urllib.request.urlopen('${PROM_URL}/api/v1/alerts', timeout=2)
    data = json.loads(req.read().decode())
    for a in data.get('data', {}).get('alerts', []):
        labels = a.get('labels', {})
        if labels.get('alertname') == target_alert:
            if target_job and labels.get('job') != target_job:
                continue
            print(a.get('state', 'inactive'))
            sys.exit(0)
except Exception:
    pass
print('inactive')
" "$alertname" "$job"
}

echo "=================================================================="
echo "FASE 1 · Simulação de Queima de Error Budget (Burn Rate > 14.4x)"
echo "=================================================================="
# Ativa modo chaos com 100% de erro para sustentar queima de orçamento
curl -fsS -X POST "${APP_URL}/chaos" \
  -H "Content-Type: application/json" \
  -d '{"error_rate": 1.0, "extra_latency_ms": 200, "ready": true}' >/dev/null

BURN_START=$(date +%s)
BURN_DETECTED_AT=""

# Gera tráfego contínuo em background enquanto monitora
(
  for _ in $(seq 1 40); do
    curl -s -o /dev/null "${APP_URL}/items" || true
    sleep 0.5
  done
) &
TRAFFIC_PID=$!

echo "[T=0s] Injetando falhas 5xx contínuas para elevar o Burn Rate..."
for elapsed in $(seq 1 35); do
  BURN_RATE="$(query_metric 'job:slo_error_burn_rate:ratio_rate1m')"
  STATE_BURN="$(get_alert_state 'SLOErrorBudgetBurnFast')"
  echo "  [+${elapsed}s] Burn Rate (1m)=${BURN_RATE}x | Alerta SLOErrorBudgetBurnFast=${STATE_BURN}"

  if [ "$STATE_BURN" = "firing" ]; then
    NOW_TS=$(date +%s)
    BURN_DETECTED_AT=$((NOW_TS - BURN_START))
    echo "✅ Alerta SLOErrorBudgetBurnFast entrou em FIRING em TTD = ${BURN_DETECTED_AT}s!"
    break
  fi
  sleep 1
done

kill "$TRAFFIC_PID" >/dev/null 2>&1 || true
# Restaura modo normal
curl -fsS -X POST "${APP_URL}/chaos" \
  -H "Content-Type: application/json" \
  -d '{"error_rate": 0.0, "extra_latency_ms": 0, "ready": true}' >/dev/null

echo ""
echo "=================================================================="
echo "FASE 2 · Derrubando Componente de Propósito (docker compose stop app)"
echo "=================================================================="
OUTAGE_START=$(date +%s)
OUTAGE_ISO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
echo "[T=0s | ${OUTAGE_ISO}] Executando: docker compose stop app"
docker compose stop app >/dev/null

PENDING_SECONDS=""
FIRING_SECONDS=""

for elapsed in $(seq 1 35); do
  UP_VAL="$(query_metric 'up{job="fastapi-app"}')"
  TARGET_STATE="$(get_alert_state 'TargetDown' 'fastapi-app')"

  NOW_TS=$(date +%s)
  DELTA=$((NOW_TS - OUTAGE_START))
  echo "  [+${DELTA}s] up(fastapi-app)=${UP_VAL} | TargetDown state=${TARGET_STATE}"

  if [ "$TARGET_STATE" = "pending" ] && [ -z "$PENDING_SECONDS" ]; then
    PENDING_SECONDS="$DELTA"
    echo "  ⚡ Scrape falhou (up == 0) detectado pelo Prometheus em +${PENDING_SECONDS}s (Pending)!"
  fi

  if [ "$TARGET_STATE" = "firing" ]; then
    FIRING_SECONDS="$DELTA"
    echo "  🚨 INCIDENTE DETECTADO (TargetDown = FIRING) em TTD = ${FIRING_SECONDS}s!"
    break
  fi
  sleep 1
done

echo ""
echo "=================================================================="
echo "FASE 3 · Recuperando o Componente (docker compose start app) e Medindo TTR"
echo "=================================================================="
RECOVERY_START=$(date +%s)
echo "[T=0s] Executando: docker compose start app"
docker compose start app >/dev/null

TTR_SECONDS=""
for elapsed in $(seq 1 30); do
  UP_VAL="$(query_metric 'up{job="fastapi-app"}')"
  TARGET_STATE="$(get_alert_state 'TargetDown' 'fastapi-app')"
  echo "  [+${elapsed}s] up(fastapi-app)=${UP_VAL} | TargetDown state=${TARGET_STATE}"

  if [ "$UP_VAL" = "1.0" ] || [ "$UP_VAL" = "1" ]; then
    NOW_TS=$(date +%s)
    TTR_SECONDS=$((NOW_TS - RECOVERY_START))
    echo "✅ Componente recuperado e reportando up == 1 em TTR = ${TTR_SECONDS}s!"
    break
  fi
  sleep 1
done

echo ""
echo "=================================================================="
echo "RESUMO DAS MÉTRICAS DO INCIDENTE PROVOCADO"
echo "=================================================================="
echo "  • TTD Queima de Budget (SLOErrorBudgetBurnFast -> firing): ${BURN_DETECTED_AT:-N/A}s"
echo "  • TTD Queda do Componente (up == 0 -> pending):            ${PENDING_SECONDS:-N/A}s"
echo "  • TTD Queda do Componente (TargetDown -> firing):          ${FIRING_SECONDS:-N/A}s"
echo "  • TTR Recuperação após restart (up == 1):                  ${TTR_SECONDS:-N/A}s"
echo "=================================================================="
