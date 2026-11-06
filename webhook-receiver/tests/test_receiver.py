"""Testes unitários do contêiner receptor de webhooks do Alertmanager."""

from __future__ import annotations

from fastapi.testclient import TestClient

from src.main import RECEIVED_ALERTS, app

client = TestClient(app)


def setup_function() -> None:
    RECEIVED_ALERTS.clear()


def test_receiver_health_and_metrics() -> None:
    resp = client.get("/health")
    assert resp.status_code == 200
    assert resp.json()["status"] == "ok"

    metrics_resp = client.get("/metrics")
    assert metrics_resp.status_code == 200
    assert "webhook_receiver_alerts_received_total" in metrics_resp.text


def test_receive_filter_and_clear_alertmanager_notifications() -> None:
    payload = {
        "alerts": [
            {
                "status": "firing",
                "labels": {
                    "alertname": "TargetDown",
                    "severity": "critical",
                    "job": "fastapi-app",
                },
                "annotations": {
                    "summary": "Componente indisponível: fastapi-app",
                    "description": "O alvo fastapi-app está inacessível.",
                    "runbook_url": "https://github.com/Gabriel-V-Mendes/Observabilidade/blob/main/docs/runbooks/target-down.md",
                },
                "startsAt": "2026-11-06T14:00:00Z",
            },
            {
                "status": "firing",
                "labels": {
                    "alertname": "SLOErrorBudgetBurnFast",
                    "severity": "critical",
                    "job": "fastapi-app",
                },
                "annotations": {
                    "summary": "Queima Crítica de Error Budget",
                    "runbook_url": "https://github.com/Gabriel-V-Mendes/Observabilidade/blob/main/docs/runbooks/error-budget-burn.md",
                },
            },
        ]
    }
    resp = client.post("/webhook/alerts", json=payload)
    assert resp.status_code == 200
    assert resp.json()["count"] == 2

    all_alerts = client.get("/webhook/alerts").json()
    assert all_alerts["count"] == 2

    target_down = client.get(
        "/webhook/alerts?alertname=TargetDown&status=firing&job=fastapi-app"
    ).json()
    assert target_down["count"] == 1
    assert target_down["alerts"][0]["alertname"] == "TargetDown"
    assert target_down["alerts"][0]["received_epoch"] > 0

    clear_resp = client.delete("/webhook/alerts")
    assert clear_resp.status_code == 200
    assert clear_resp.json()["cleared_count"] == 2
    assert client.get("/webhook/alerts").json()["count"] == 0
