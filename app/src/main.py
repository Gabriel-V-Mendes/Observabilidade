"""API FastAPI instrumentada com método RED (Rate, Errors, Duration) e logs JSON estruturados.

Projetada para o Projeto 4 (Observabilidade e SLOs):
- Exposição de métricas Prometheus em `/metrics` com buckets alinhados aos SLOs (p95 < 300ms, p99 < 500ms)
- Proteção contra explosão de cardinalidade de labels (normalização de rotas)
- Logs estruturados em JSON na stdout coletados pelo Grafana Alloy e indexados no Loki
- Endpoints de negócio (`/items`), probes (`/health`, `/health/ready`), injeção de falhas (`/error`, `/slow`, `/chaos`)
  e receptor local de webhooks do Alertmanager (`/webhook/alerts`) para validação ponta a ponta.
"""

from __future__ import annotations

import json
import logging
import os
import random
import sys
import time
import uuid
from datetime import datetime, timezone
from typing import Any

from fastapi import FastAPI, HTTPException, Request, Response
from prometheus_client import (
    CONTENT_TYPE_LATEST,
    Counter,
    Gauge,
    Histogram,
    generate_latest,
)
from pydantic import BaseModel, Field

APP_NAME = os.getenv("APP_NAME", "observability-api")
APP_VERSION = os.getenv("APP_VERSION", "2.0.0")

# ==============================================================================
# Configuração de Logs Estruturados em JSON (coletados pelo Grafana Alloy -> Loki)
# ==============================================================================
logger = logging.getLogger(APP_NAME)
logger.setLevel(os.getenv("LOG_LEVEL", "INFO").upper())
if not logger.handlers:
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(logging.Formatter("%(message)s"))
    logger.addHandler(handler)
logger.propagate = False


def log_json(level: str, message: str, **extra: Any) -> None:
    """Emite uma linha JSON estruturada na stdout para ingestão pelo Grafana Alloy."""
    payload = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "level": level.upper(),
        "service": APP_NAME,
        "version": APP_VERSION,
        "message": message,
        **extra,
    }
    logger.info(json.dumps(payload, ensure_ascii=False))


# ==============================================================================
# Métricas Prometheus — Padrão RED (Rate, Errors, Duration) + Saturation
# ==============================================================================

# 1. Rate: total de requisições por método, rota normalizada e status HTTP
REQUESTS_TOTAL = Counter(
    "app_requests_total",
    "Total de requisicoes HTTP processadas pela API",
    ["method", "endpoint", "http_status"],
)

# 2. Errors: contador explícito de falhas (HTTP 5xx ou exceções não tratadas)
ERRORS_TOTAL = Counter(
    "app_errors_total",
    "Total de erros HTTP 5xx e falhas internas na API",
    ["method", "endpoint", "http_status", "error_type"],
)

# 3. Duration: histograma com buckets calibrados exatamente nos limiares de SLO (300ms p95 e 500ms p99)
SLO_LATENCY_BUCKETS = (0.01, 0.025, 0.05, 0.1, 0.2, 0.3, 0.5, 0.75, 1.0, 2.5, 5.0)
REQUEST_DURATION = Histogram(
    "app_request_duration_seconds",
    "Distribuicao de latencia das requisicoes HTTP em segundos",
    ["method", "endpoint"],
    buckets=SLO_LATENCY_BUCKETS,
)

# 4. Saturation / Concorrência: requisições em andamento neste exato instante
REQUESTS_IN_PROGRESS = Gauge(
    "app_requests_in_progress",
    "Numero de requisicoes HTTP sendo processadas simultaneamente",
    ["method", "endpoint"],
)

# 5. Contador de notificações entregues pelo Alertmanager no webhook de auditoria
ALERT_WEBHOOKS_TOTAL = Counter(
    "app_alert_webhooks_received_total",
    "Total de alertas entregues pelo Alertmanager no receptor webhook da API",
    ["alertname", "status", "severity"],
)

# ==============================================================================
# Estado em Memória (Itens + Modo Chaos para Simulação de Incidente e Burn Rate)
# ==============================================================================
KNOWN_ENDPOINTS = {
    "/health",
    "/health/ready",
    "/items",
    "/error",
    "/slow",
    "/chaos",
    "/webhook/alerts",
}

ITEMS_DB: list[dict[str, Any]] = [
    {"id": 1, "name": "SLO Availability 99.5%", "category": "reliability"},
    {"id": 2, "name": "Grafana Alloy Log Pipeline", "category": "observability"},
]

CHAOS_STATE: dict[str, Any] = {
    "error_rate": 0.0,        # Probabilidade (0.0 a 1.0) de injetar erro HTTP 500 em /items
    "extra_latency_ms": 0,    # Latência artificial adicional (ms) injetada em /items
    "ready": True,            # Se False, /health/ready retorna 503 (degradação de dependência)
}

RECEIVED_ALERTS: list[dict[str, Any]] = []


class ItemCreate(BaseModel):
    name: str = Field(..., min_length=2, max_length=120)
    category: str = Field(default="general", min_length=2, max_length=60)


class ChaosConfig(BaseModel):
    error_rate: float = Field(default=0.0, ge=0.0, le=1.0)
    extra_latency_ms: int = Field(default=0, ge=0, le=5000)
    ready: bool = Field(default=True)


app = FastAPI(
    title="Observability & SLO API",
    version=APP_VERSION,
    description="API instrumentada com métricas RED, logs JSON estruturados e simulação de incidentes.",
)


def normalize_endpoint(path: str) -> str:
    """Normaliza o path para evitar explosão de cardinalidade no Prometheus."""
    if path in KNOWN_ENDPOINTS:
        return path
    if path.startswith("/items/"):
        return "/items/{id}"
    return "/unknown"


# ==============================================================================
# Middleware HTTP: coleta RED metrics e emite log estruturado por requisição
# ==============================================================================
@app.middleware("http")
async def observability_middleware(request: Request, call_next):
    raw_path = request.url.path
    if raw_path == "/metrics":
        return await call_next(request)

    endpoint = normalize_endpoint(raw_path)
    method = request.method
    request_id = request.headers.get("X-Request-ID", str(uuid.uuid4())[:8])

    REQUESTS_IN_PROGRESS.labels(method=method, endpoint=endpoint).inc()
    start_time = time.perf_counter()
    status_code = 500
    error_type: str | None = None

    try:
        response = await call_next(request)
        status_code = response.status_code
        if status_code >= 500:
            error_type = f"http_{status_code}"
        response.headers["X-Request-ID"] = request_id
        return response
    except Exception as exc:
        status_code = 500
        error_type = exc.__class__.__name__
        raise
    finally:
        duration = time.perf_counter() - start_time
        REQUESTS_IN_PROGRESS.labels(method=method, endpoint=endpoint).dec()
        REQUEST_DURATION.labels(method=method, endpoint=endpoint).observe(duration)
        REQUESTS_TOTAL.labels(
            method=method,
            endpoint=endpoint,
            http_status=str(status_code),
        ).inc()

        if status_code >= 500:
            ERRORS_TOTAL.labels(
                method=method,
                endpoint=endpoint,
                http_status=str(status_code),
                error_type=error_type or "internal_error",
            ).inc()

        level = "ERROR" if status_code >= 500 else ("WARN" if status_code >= 400 else "INFO")
        log_json(
            level=level,
            message=f"{method} {raw_path} -> {status_code}",
            request_id=request_id,
            method=method,
            path=raw_path,
            endpoint=endpoint,
            status_code=status_code,
            duration_ms=round(duration * 1000, 2),
        )


# ==============================================================================
# Rotas de Saúde, Métricas e Negócio
# ==============================================================================
@app.get("/health")
def health_liveness() -> dict[str, str]:
    """Liveness probe: confirma que o processo Python/Uvicorn está ativo."""
    return {"status": "ok", "service": APP_NAME, "version": APP_VERSION}


@app.get("/health/ready")
def health_readiness() -> dict[str, Any]:
    """Readiness probe: indica se a API está apta a receber tráfego."""
    if not CHAOS_STATE["ready"]:
        raise HTTPException(status_code=503, detail="Service temporarily not ready (chaos mode)")
    return {"status": "ready", "chaos": CHAOS_STATE}


@app.get("/metrics")
def metrics() -> Response:
    """Endpoint raspado pelo Prometheus para coleta das séries temporais."""
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.get("/items")
def list_items() -> dict[str, Any]:
    """Rota principal de negócio. Respeita parâmetros de chaos se estiverem ativos."""
    base_delay = random.uniform(0.015, 0.085)
    extra_delay = CHAOS_STATE["extra_latency_ms"] / 1000.0
    time.sleep(base_delay + extra_delay)

    if CHAOS_STATE["error_rate"] > 0 and random.random() < CHAOS_STATE["error_rate"]:
        log_json(
            level="ERROR",
            message="Falha injetada via modo chaos em /items",
            chaos_error_rate=CHAOS_STATE["error_rate"],
        )
        return Response(
            status_code=500,
            media_type="application/json",
            content=json.dumps({"detail": "Simulated failure via chaos mode"}),
        )

    return {"count": len(ITEMS_DB), "items": ITEMS_DB}


@app.post("/items", status_code=201)
def create_item(payload: ItemCreate) -> dict[str, Any]:
    """Cria um novo item e registra evento estruturado nos logs."""
    new_item = {
        "id": len(ITEMS_DB) + 1,
        "name": payload.name,
        "category": payload.category,
    }
    ITEMS_DB.append(new_item)
    log_json(level="INFO", message="Novo item criado", item_id=new_item["id"], item_name=payload.name)
    return new_item


# ==============================================================================
# Rotas de Simulação de Falha / Latência e Controle de Incidente
# ==============================================================================
@app.get("/slow")
def trigger_slow(delay_ms: int = 650) -> dict[str, Any]:
    """Simula rota lenta (default 650ms) para violar os SLOs de latência p95 (300ms) e p99 (500ms)."""
    bounded_delay = max(10, min(delay_ms, 5000)) / 1000.0
    time.sleep(bounded_delay)
    return {"message": "Slow response completed", "delay_ms": int(bounded_delay * 1000)}


@app.get("/error")
def trigger_error() -> Response:
    """Simula erro HTTP 500 com latência degradada para testar queima de Error Budget."""
    time.sleep(random.uniform(0.35, 0.65))
    log_json(level="ERROR", message="Erro critico simulado no endpoint /error", error_code="DB_TIMEOUT")
    return Response(
        status_code=500,
        media_type="application/json",
        content=json.dumps({"detail": "Internal server error (simulated incident)"}),
    )


@app.get("/chaos")
def get_chaos_state() -> dict[str, Any]:
    """Retorna o estado atual da injeção de falhas."""
    return CHAOS_STATE


@app.post("/chaos")
def update_chaos_state(config: ChaosConfig) -> dict[str, Any]:
    """Ativa ou desativa injeção controlada de erro/latência para testes de SLO."""
    CHAOS_STATE["error_rate"] = config.error_rate
    CHAOS_STATE["extra_latency_ms"] = config.extra_latency_ms
    CHAOS_STATE["ready"] = config.ready
    log_json(level="WARN", message="Estado de chaos atualizado", **CHAOS_STATE)
    return {"status": "updated", "chaos": CHAOS_STATE}


@app.post("/webhook/alerts")
async def receive_alertmanager_webhook(request: Request) -> dict[str, Any]:
    """Receptor local de webhooks do Alertmanager para auditoria e testes automatizados."""
    body = await request.json()
    alerts = body.get("alerts", [])
    for alert in alerts:
        labels = alert.get("labels", {})
        status = alert.get("status", "unknown")
        alertname = labels.get("alertname", "unknown")
        severity = labels.get("severity", "unknown")
        ALERT_WEBHOOKS_TOTAL.labels(
            alertname=alertname,
            status=status,
            severity=severity,
        ).inc()
        event = {
            "received_at": datetime.now(timezone.utc).isoformat(),
            "alertname": alertname,
            "status": status,
            "severity": severity,
            "summary": alert.get("annotations", {}).get("summary", ""),
            "runbook_url": alert.get("annotations", {}).get("runbook_url", ""),
        }
        RECEIVED_ALERTS.append(event)
        log_json(level="WARN", message=f"Alerta recebido do Alertmanager: {alertname} ({status})", **event)

    return {"status": "received", "count": len(alerts)}


@app.get("/webhook/alerts")
def list_received_alerts() -> dict[str, Any]:
    """Lista os alertas entregues pelo Alertmanager durante testes e incidentes."""
    return {"count": len(RECEIVED_ALERTS), "alerts": RECEIVED_ALERTS[-50:]}
