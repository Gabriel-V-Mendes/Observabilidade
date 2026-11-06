"""Receptor dedicado de Webhooks do Alertmanager (contêiner isolado da API monitorada).

Por que este serviço roda em um contêiner separado (`webhook-receiver:8081`)?
Se o receptor de alertas ficasse dentro da própria API monitorada (`fastapi-app`),
uma queda total da API (`TargetDown`) impediria o Alertmanager de entregar a
notificação justamente quando ela é mais necessária. Com um contêiner dedicado:
- O Alertmanager entrega notificações `firing` e `resolved` mesmo com `fastapi-app` parada;
- O Tempo de Detecção (TTD) no Game Day é medido até a notificação efetivamente entregue aqui;
- Os alertas recebidos são expostos para auditoria em `GET /webhook/alerts`, métricas em
  `/metrics` e logs JSON estruturados coletados pelo Grafana Alloy para o Loki.
"""

from __future__ import annotations

import json
import logging
import os
import sys
import time
from datetime import UTC, datetime
from typing import Any

from fastapi import FastAPI, Query, Request, Response
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Gauge, generate_latest

SERVICE_NAME = os.getenv("SERVICE_NAME", "alert-webhook-receiver")
SERVICE_VERSION = os.getenv("SERVICE_VERSION", "2.0.0")

logger = logging.getLogger(SERVICE_NAME)
logger.setLevel(os.getenv("LOG_LEVEL", "INFO").upper())
if not logger.handlers:
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(logging.Formatter("%(message)s"))
    logger.addHandler(handler)
logger.propagate = False


def log_json(level: str, message: str, **extra: Any) -> None:
    """Emite linha JSON estruturada na stdout para coleta pelo Grafana Alloy."""
    payload = {
        "timestamp": datetime.now(UTC).isoformat(),
        "level": level.upper(),
        "service": SERVICE_NAME,
        "version": SERVICE_VERSION,
        "message": message,
        **extra,
    }
    logger.info(json.dumps(payload, ensure_ascii=False))


WEBHOOK_ALERTS_TOTAL = Counter(
    "webhook_receiver_alerts_received_total",
    "Total de notificacoes de alerta entregues pelo Alertmanager no contêiner receptor",
    ["alertname", "status", "severity"],
)

LAST_ALERT_TIMESTAMP = Gauge(
    "webhook_receiver_last_alert_timestamp_seconds",
    "Timestamp Unix da ultima notificacao entregue pelo Alertmanager por alerta e status",
    ["alertname", "status"],
)

RECEIVED_ALERTS: list[dict[str, Any]] = []

app = FastAPI(
    title="Alertmanager Webhook Receiver",
    version=SERVICE_VERSION,
    description="Receptor dedicado e desacoplado para auditoria e medição de TTD de notificações entregues pelo Alertmanager.",
)


@app.get("/health")
def health() -> dict[str, str]:
    """Liveness/Readiness probe do receptor de alertas."""
    return {"status": "ok", "service": SERVICE_NAME, "version": SERVICE_VERSION}


@app.get("/metrics")
def metrics() -> Response:
    """Exposição de métricas Prometheus do receptor de webhooks."""
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.post("/webhook/alerts")
async def receive_alertmanager_webhook(request: Request) -> dict[str, Any]:
    """Recebe notificações HTTP POST despachadas pelo Alertmanager."""
    body = await request.json()
    alerts = body.get("alerts", [])
    now_epoch = round(time.time(), 3)
    now_iso = datetime.now(UTC).isoformat()

    for alert in alerts:
        labels = alert.get("labels", {})
        annotations = alert.get("annotations", {})
        status = alert.get("status", "unknown")
        alertname = labels.get("alertname", "unknown")
        severity = labels.get("severity", "unknown")
        job = labels.get("job", "")

        WEBHOOK_ALERTS_TOTAL.labels(
            alertname=alertname,
            status=status,
            severity=severity,
        ).inc()
        LAST_ALERT_TIMESTAMP.labels(
            alertname=alertname,
            status=status,
        ).set(now_epoch)

        event = {
            "received_at": now_iso,
            "received_epoch": now_epoch,
            "alertname": alertname,
            "status": status,
            "severity": severity,
            "job": job,
            "summary": annotations.get("summary", ""),
            "description": annotations.get("description", ""),
            "runbook_url": annotations.get("runbook_url", ""),
            "starts_at": alert.get("startsAt", ""),
        }
        RECEIVED_ALERTS.append(event)
        log_level = "WARN" if status == "firing" else "INFO"
        log_json(
            level=log_level,
            message=f"Notificacao entregue pelo Alertmanager: {alertname} ({status})",
            **event,
        )

    return {"status": "received", "count": len(alerts), "received_epoch": now_epoch}


@app.get("/webhook/alerts")
def list_received_alerts(
    alertname: str | None = Query(default=None),
    status: str | None = Query(default=None),
    job: str | None = Query(default=None),
) -> dict[str, Any]:
    """Lista notificações entregues pelo Alertmanager, permitindo filtro por alerta/status/job."""
    filtered = RECEIVED_ALERTS
    if alertname is not None:
        filtered = [a for a in filtered if a["alertname"] == alertname]
    if status is not None:
        filtered = [a for a in filtered if a["status"] == status]
    if job is not None:
        filtered = [a for a in filtered if a["job"] == job]
    return {"count": len(filtered), "alerts": filtered[-100:]}


@app.delete("/webhook/alerts")
def clear_received_alerts() -> dict[str, Any]:
    """Limpa o histórico em memória antes de iniciar um novo exercício de Game Day."""
    cleared = len(RECEIVED_ALERTS)
    RECEIVED_ALERTS.clear()
    log_json(level="INFO", message="Historico de alertas reiniciado para exercicio de Game Day", cleared_count=cleared)
    return {"status": "cleared", "cleared_count": cleared}
