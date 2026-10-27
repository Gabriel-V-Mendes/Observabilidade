# Runbook: `HighLatencyP95` & `HighLatencyP99` — Degradação de Latência

- **Alertas cobertos:**
  - `HighLatencyP95` (`warning`): `job:sli_latency_p95:seconds1m > 0.300` (`> 300ms`)
  - `HighLatencyP99` (`critical`): `job:sli_latency_p99:seconds1m > 0.500` (`> 500ms`)
- **Impacto:** As respostas estão lentas, degradando a experiência dos usuários e aumentando o risco de esgotamento do pool de workers (`app_requests_in_progress`).

---

## 1. Diagnóstico

### 1.1 Identificar qual rota está puxando o p95/p99 para cima
```bash
curl -fsS "http://127.0.0.1:9090/api/v1/query?query=histogram_quantile(0.99,sum(rate(app_request_duration_seconds_bucket[1m]))by(le,endpoint))"
```

### 1.2 Verificar concorrência (`app_requests_in_progress`) e saturação de CPU do host
```bash
curl -fsS "http://127.0.0.1:9090/api/v1/query?query=app_requests_in_progress"
docker stats --no-stream fastapi-app
```

### 1.3 Filtrar requisições lentas nos logs estruturados do Loki (`duration_ms`)
```bash
curl -G -s "http://127.0.0.1:3100/loki/api/v1/query_range" \
  --data-urlencode 'query={container="fastapi-app"} | json | duration_ms > 300' \
  --data-urlencode 'limit=15'
```

---

## 2. Mitigação

1. **Remover latência artificial caso o modo `/chaos` esteja ativo:**
   ```bash
   curl -fsS -X POST http://127.0.0.1:8000/chaos \
     -H "Content-Type: application/json" \
     -d '{"error_rate": 0.0, "extra_latency_ms": 0, "ready": true}'
   ```
2. **Se houver contenção de CPU (throttling no container):**
   Aumentar `deploy.resources.limits.cpus` do serviço `app` no `docker-compose.yml` ou escalar horizontalmente o número de workers do Uvicorn.

---

## 3. Verificação

Confirmar que `job:sli_latency_p95:seconds1m < 0.3` e `job:sli_latency_p99:seconds1m < 0.5`:
```bash
curl -fsS "http://127.0.0.1:9090/api/v1/query?query=job:sli_latency_p95:seconds1m"
curl -fsS "http://127.0.0.1:9090/api/v1/query?query=job:sli_latency_p99:seconds1m"
```
