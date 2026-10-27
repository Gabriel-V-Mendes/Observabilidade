"""Testes unitários e de integração da instrumentação RED, endpoints de negócio e modo chaos."""

from __future__ import annotations

from fastapi.testclient import TestClient

from src.main import CHAOS_STATE, RECEIVED_ALERTS, app

client = TestClient(app)


def setup_function() -> None:
    """Garante que o modo chaos começa limpo antes de cada teste."""
    CHAOS_STATE["error_rate"] = 0.0
    CHAOS_STATE["extra_latency_ms"] = 0
    CHAOS_STATE["ready"] = True
    RECEIVED_ALERTS.clear()


def test_health_and_readiness() -> None:
    resp_live = client.get("/health")
    assert resp_live.status_code == 200
    assert resp_live.json()["status"] == "ok"

    resp_ready = client.get("/health/ready")
    assert resp_ready.status_code == 200
    assert resp_ready.json()["status"] == "ready"


def test_items_crud_and_request_id_header() -> None:
    resp_list = client.get("/items")
    assert resp_list.status_code == 200
    assert "X-Request-ID" in resp_list.headers
    initial_count = resp_list.json()["count"]

    resp_create = client.post("/items", json={"name": "Prometheus Rule", "category": "sre"})
    assert resp_create.status_code == 201
    assert resp_create.json()["name"] == "Prometheus Rule"

    resp_after = client.get("/items")
    assert resp_after.json()["count"] == initial_count + 1


def test_error_and_slow_endpoints_increment_red_metrics() -> None:
    resp_err = client.get("/error")
    assert resp_err.status_code == 500

    resp_slow = client.get("/slow?delay_ms=20")
    assert resp_slow.status_code == 200
    assert resp_slow.json()["delay_ms"] == 20

    metrics_text = client.get("/metrics").text
    assert 'app_requests_total{endpoint="/error",http_status="500",method="GET"}' in metrics_text
    assert 'app_errors_total{endpoint="/error",error_type="http_500",http_status="500",method="GET"}' in metrics_text
    assert 'app_request_duration_seconds_bucket{endpoint="/slow",le="0.3",method="GET"}' in metrics_text
    assert 'app_request_duration_seconds_bucket{endpoint="/slow",le="0.5",method="GET"}' in metrics_text


def test_unknown_path_normalization_prevents_cardinality_explosion() -> None:
    resp = client.get("/rota-inexistente-987654")
    assert resp.status_code == 404

    metrics_text = client.get("/metrics").text
    assert "/rota-inexistente-987654" not in metrics_text
    assert 'endpoint="/unknown"' in metrics_text


def test_chaos_mode_injection_and_readiness_degradation() -> None:
    resp_chaos = client.post(
        "/chaos",
        json={"error_rate": 1.0, "extra_latency_ms": 10, "ready": False},
    )
    assert resp_chaos.status_code == 200

    resp_ready = client.get("/health/ready")
    assert resp_ready.status_code == 503

    resp_items = client.get("/items")
    assert resp_items.status_code == 500


def test_alertmanager_webhook_receiver() -> None:
    payload = {
        "alerts": [
            {
                "status": "firing",
                "labels": {"alertname": "SLOErrorBudgetBurnFast", "severity": "critical"},
                "annotations": {
                    "summary": "Queima rápida do Error Budget",
                    "runbook_url": "https://github.com/Gabriel-V-Mendes/Observabilidade/blob/main/docs/runbooks/error-budget-burn.md",
                },
            }
        ]
    }
    resp = client.post("/webhook/alerts", json=payload)
    assert resp.status_code == 200
    assert resp.json()["count"] == 1

    listed = client.get("/webhook/alerts").json()
    assert listed["count"] == 1
    assert listed["alerts"][0]["alertname"] == "SLOErrorBudgetBurnFast"
