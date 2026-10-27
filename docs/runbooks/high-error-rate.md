# Runbook: `HighErrorRate` — Taxa de Erro HTTP 5xx > 1%

- **Alertas cobertos:** `HighErrorRate`
- **Severidade:** `critical`
- **Expressão PromQL:** `job:slo_error_ratio:rate1m > 0.01 and job:app_requests:rate1m > 0.1` (`for: 20s`)
- **Impacto:** Mais de 1% dos clientes estão recebendo falhas internas (`HTTP 500/503`), o dobro da taxa máxima tolerada pelo SLO de 99.5%.

---

## 1. Diagnóstico

### 1.1 Identificar o tipo de erro (`error_type`) e endpoint afetado
```bash
curl -fsS "http://127.0.0.1:9090/api/v1/query?query=sum(rate(app_errors_total[1m]))by(endpoint,error_type,http_status)"
```

### 1.2 Consultar stacktraces / mensagens de erro no Loki
```bash
curl -G -s "http://127.0.0.1:3100/loki/api/v1/query_range" \
  --data-urlencode 'query={container="fastapi-app"} |= "ERROR"' \
  --data-urlencode 'limit=20'
```

### 1.3 Testar manualmente a prontidão da aplicação
```bash
curl -i http://127.0.0.1:8000/health/ready
```

---

## 2. Mitigação

1. **Verificar estado de dependências e modo `/chaos`:**
   ```bash
   curl -fsS -X POST http://127.0.0.1:8000/chaos \
     -H "Content-Type: application/json" \
     -d '{"error_rate": 0.0, "extra_latency_ms": 0, "ready": true}'
   ```
2. **Reiniciar ou reverter a versão da API** caso haja corrupção de estado em memória:
   ```bash
   docker compose restart app
   ```

---

## 3. Verificação

1. Gerar tráfego em `/items` e confirmar retorno `200 OK`:
```bash
for _ in $(seq 1 10); do curl -fsS http://127.0.0.1:8000/items >/dev/null; done
```
2. Confirmar que `job:slo_error_ratio:rate1m` retornou para `0`.
