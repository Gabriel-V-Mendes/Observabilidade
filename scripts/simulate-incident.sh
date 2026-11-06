#!/usr/bin/env bash
# ==============================================================================
# Exercício de Game Day — Simulação Controlada & Medição de TTD e TTR
#
# Arquitetura de medição real:
#   - O receptor de webhooks (`webhook-receiver:8080`) roda em um contêiner
#     separado da API monitorada (`fastapi-app:8000`).
#   - O TTD (Time to Detect) só é considerado concluído quando a notificação
#     do Alertmanager é EFETIVAMENTE ENTREGUE no contêiner `webhook-receiver`.
#
# Etapas do Game Day:
#   Fase 1 -> Queima de Error Budget (`SLOErrorBudgetBurnFast` > 14.4x)
#             Injeta falhas HTTP 500 via modo chaos e cronometra:
#               a) Pico de Burn Rate (1m) medido no Prometheus;
#               b) Transição para `firing` no Prometheus;
#               c) TTD de entrega real da notificação em `webhook-receiver:8080`.
#   Fase 2 -> Queda Proposital do Componente (`docker compose stop app`)
#             Interrompe o contêiner `fastapi-app` e cronometra:
#               a) Detecção de falha de scrape (`up == 0` -> `pending`);
#               b) Disparo da regra `TargetDown` (`firing` no Prometheus);
#               c) TTD de entrega real da notificação `TargetDown` no contêiner
#                  separado `webhook-receiver:8080` (mesmo com a API fora do ar).
#   Fase 3 -> Recuperação (`docker compose start app`) e Medição de TTR
#             Restaura o contêiner da API e cronometra o tempo até `up == 1`.
# ==============================================================================
set -euo pipefail

PROM_URL="http://127.0.0.1:9090"
APP_URL="http://127.0.0.1:8000"
WEBHOOK_URL="http://127.0.0.1:8081"

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
        print(f\"{float(res[0]['value'][1]):.1f}\")
        sys.exit(0)
except Exception:
    pass
print('0.0')
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

check_webhook_delivered() {
  local alertname="$1"
  local status="$2"
  local job="${3:-}"
  python3 -c "
import urllib.request, urllib.parse, json, sys
params = {'alertname': sys.argv[1], 'status': sys.argv[2]}
if sys.argv[3]:
    params['job'] = sys.argv[3]
try:
    url = '${WEBHOOK_URL}/webhook/alerts?' + urllib.parse.urlencode(params)
    req = urllib.request.urlopen(url, timeout=2)
    data = json.loads(req.read().decode())
    if data.get('count', 0) > 0:
        print('delivered')
        sys.exit(0)
except Exception:
    pass
print('waiting')
" "$alertname" "$status" "$job"
}

echo "=================================================================="
echo "PREPARAÇÃO DO GAME DAY · Limpando histórico do webhook-receiver (:8081)"
echo "=================================================================="
curl -fsS -X DELETE "${WEBHOOK_URL}/webhook/alerts" >/dev/null
echo "✔ Contêiner webhook-receiver pronto e zerado."

echo ""
echo "=================================================================="
echo "FASE 1 · Game Day: Queima de Error Budget (Burn Rate > 14.4x)"
echo "=================================================================="
curl -fsS -X POST "${APP_URL}/chaos" \
  -H "Content-Type: application/json" \
  -d '{"error_rate": 1.0, "extra_latency_ms": 200, "ready": true}' >/dev/null

BURN_START=$(date +%s)
BURN_START_ISO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
BURN_FIRING_AT=""
BURN_WEBHOOK_TTD=""
PEAK_BURN_RATE="0.0"

(
  for _ in $(seq 1 60); do
    curl -s -o /dev/null "${APP_URL}/items" || true
    sleep 0.4
  done
) &
TRAFFIC_PID=$!

echo "[T=0s | ${BURN_START_ISO}] Injetando falhas HTTP 500 contínuas em /items..."
for _ in $(seq 1 45); do
  BURN_RATE="$(query_metric 'job:slo_error_burn_rate:ratio_rate1m')"
  PEAK_BURN_RATE="$(python3 -c "import sys; print(f'{max(float(sys.argv[1]), float(sys.argv[2])):.1f}')" "$PEAK_BURN_RATE" "$BURN_RATE")"
  STATE_BURN="$(get_alert_state 'SLOErrorBudgetBurnFast')"
  WH_BURN="$(check_webhook_delivered 'SLOErrorBudgetBurnFast' 'firing')"

  NOW_TS=$(date +%s)
  DELTA=$((NOW_TS - BURN_START))
  echo "  [+${DELTA}s] Burn Rate (1m)=${BURN_RATE}x (pico=${PEAK_BURN_RATE}x) | Prometheus=${STATE_BURN} | Webhook=${WH_BURN}"

  if [ "$STATE_BURN" = "firing" ] && [ -z "$BURN_FIRING_AT" ]; then
    BURN_FIRING_AT="$DELTA"
    echo "  ⚡ SLOErrorBudgetBurnFast entrou em FIRING no Prometheus em +${BURN_FIRING_AT}s"
  fi

  if [ "$WH_BURN" = "delivered" ]; then
    BURN_WEBHOOK_TTD="$DELTA"
    echo "  ✅ Notificação SLOErrorBudgetBurnFast ENTREGUE no webhook-receiver em TTD = ${BURN_WEBHOOK_TTD}s!"
    break
  fi
  sleep 1
done

kill "$TRAFFIC_PID" >/dev/null 2>&1 || true
curl -fsS -X POST "${APP_URL}/chaos" \
  -H "Content-Type: application/json" \
  -d '{"error_rate": 0.0, "extra_latency_ms": 0, "ready": true}' >/dev/null

echo ""
echo "=================================================================="
echo "FASE 2 · Game Day: Queda Proposital do Componente (docker compose stop app)"
echo "=================================================================="
OUTAGE_START=$(date +%s)
OUTAGE_ISO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
echo "[T=0s | ${OUTAGE_ISO}] Executando: docker compose stop app"
docker compose stop app >/dev/null

PENDING_SECONDS=""
FIRING_SECONDS=""
OUTAGE_WEBHOOK_TTD=""

for _ in $(seq 1 45); do
  UP_VAL="$(query_metric 'up{job="fastapi-app"}')"
  TARGET_STATE="$(get_alert_state 'TargetDown' 'fastapi-app')"
  WH_TARGET="$(check_webhook_delivered 'TargetDown' 'firing' 'fastapi-app')"

  NOW_TS=$(date +%s)
  DELTA=$((NOW_TS - OUTAGE_START))
  echo "  [+${DELTA}s] up(fastapi-app)=${UP_VAL} | Prometheus=${TARGET_STATE} | Webhook=${WH_TARGET}"

  if [ "$TARGET_STATE" = "pending" ] && [ -z "$PENDING_SECONDS" ]; then
    PENDING_SECONDS="$DELTA"
    echo "  ⚡ Scrape falhou (up == 0 -> pending) detectado pelo Prometheus em +${PENDING_SECONDS}s!"
  fi

  if [ "$TARGET_STATE" = "firing" ] && [ -z "$FIRING_SECONDS" ]; then
    FIRING_SECONDS="$DELTA"
    echo "  🚨 TargetDown entrou em FIRING no Prometheus em +${FIRING_SECONDS}s!"
  fi

  if [ "$WH_TARGET" = "delivered" ]; then
    OUTAGE_WEBHOOK_TTD="$DELTA"
    echo "  ✅ Notificação TargetDown ENTREGUE no contêiner separado webhook-receiver em TTD = ${OUTAGE_WEBHOOK_TTD}s!"
    break
  fi
  sleep 1
done

echo ""
echo "=================================================================="
echo "FASE 3 · Game Day: Recuperação (docker compose start app) e Medição de TTR"
echo "=================================================================="
RECOVERY_START=$(date +%s)
RECOVERY_ISO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
echo "[T=0s | ${RECOVERY_ISO}] Executando: docker compose start app"
docker compose start app >/dev/null

TTR_SECONDS=""
for _ in $(seq 1 35); do
  UP_VAL="$(query_metric 'up{job="fastapi-app"}')"
  TARGET_STATE="$(get_alert_state 'TargetDown' 'fastapi-app')"
  NOW_TS=$(date +%s)
  DELTA=$((NOW_TS - RECOVERY_START))
  echo "  [+${DELTA}s] up(fastapi-app)=${UP_VAL} | TargetDown state=${TARGET_STATE}"

  if [ "$UP_VAL" = "1.0" ] || [ "$UP_VAL" = "1" ]; then
    TTR_SECONDS="$DELTA"
    echo "  ✅ Componente recuperado e reportando up == 1 em TTR = ${TTR_SECONDS}s!"
    break
  fi
  sleep 1
done

if [ -z "$BURN_WEBHOOK_TTD" ] || [ -z "$OUTAGE_WEBHOOK_TTD" ] || [ -z "$TTR_SECONDS" ]; then
  echo "❌ Erro: alguma etapa do Game Day não completou dentro do tempo limite!" >&2
  exit 1
fi

echo ""
echo "=================================================================="
echo "RESUMO DAS MÉTRICAS DO EXERCÍCIO DE GAME DAY (EXECUÇÃO ÚNICA)"
echo "=================================================================="
echo "  • Pico de Burn Rate (1m) medido na Fase 1:                       ${PEAK_BURN_RATE}x"
echo "  • Queima de Budget (SLOErrorBudgetBurnFast -> firing Prometheus): ${BURN_FIRING_AT:-N/A}s"
echo "  • TTD Queima de Budget (notificação entregue no webhook-receiver): ${BURN_WEBHOOK_TTD}s"
echo "  • Queda do Componente (up == 0 -> pending no Prometheus):        ${PENDING_SECONDS:-N/A}s"
echo "  • Queda do Componente (TargetDown -> firing no Prometheus):      ${FIRING_SECONDS:-N/A}s"
echo "  • TTD Queda do Componente (notificação entregue no webhook):     ${OUTAGE_WEBHOOK_TTD}s"
echo "  • TTR Recuperação após restart (up == 1 no Prometheus):          ${TTR_SECONDS}s"
echo "=================================================================="
