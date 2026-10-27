# Runbook: `SLOErrorBudgetBurnFast` & `SLOErrorBudgetBurnSlow` — Queima de Error Budget

- **Alertas cobertos:** `SLOErrorBudgetBurnFast` (`critical`, burn rate > `14.4x`) e `SLOErrorBudgetBurnSlow` (`warning`, burn rate > `2.0x`)
- **SLO Associado:** Disponibilidade `>= 99.5%` (Error Budget = `0.5%` = `0.005`)
- **Significado Matemático:**
  - **Fast Burn (`> 14.4x`):** A taxa de erros `5xx` atual ultrapassou `7.2%` (`14.4 × 0.5%`). Se mantida, **100% do orçamento de 30 dias será esgotado em ~50 horas** (consome 2% do orçamento mensal em apenas 1 hora). Exige intervenção imediata (Page).
  - **Slow Burn (`> 2.0x`):** A taxa de erros `5xx` está acima de `1.0%` (`2 × 0.5%`). Se mantida, o orçamento será esgotado na metade da janela. Exige investigação no expediente (Ticket).

---

## 1. Diagnóstico Rápido (< 3 minutos)

### 1.1 Verificar quais rotas estão gerando erros HTTP `5xx`
```bash
curl -fsS "http://127.0.0.1:9090/api/v1/query?query=sum(rate(app_requests_total{http_status=~'5..'}[1m]))by(endpoint,http_status)"
```

### 1.2 Inspecionar os logs estruturados de erro (`level="ERROR"`) coletados pelo Grafana Alloy no Loki
```bash
curl -G -s "http://127.0.0.1:3100/loki/api/v1/query_range" \
  --data-urlencode 'query={container="fastapi-app", level="ERROR"}' \
  --data-urlencode 'limit=20'
```

### 1.3 Verificar se o modo de injeção de falhas (`/chaos`) está ativo
```bash
curl -fsS http://127.0.0.1:8000/chaos
```

---

## 2. Mitigação

1. **Se for causado por injeção de falha / teste de caos ativo:**
   Desative imediatamente o modo chaos:
   ```bash
   curl -fsS -X POST http://127.0.0.1:8000/chaos \
     -H "Content-Type: application/json" \
     -d '{"error_rate": 0.0, "extra_latency_ms": 0, "ready": true}'
   ```
2. **Se for causado por regressão em release recente:**
   Execute rollback imediato para a última tag/commit estável e aplique `docker compose up -d --build app`.
3. **Política de Error Budget:**
   Se o painel **Error Budget Restante** no Grafana (`http://127.0.0.1:3000`) cair para `0%`, **congele novos deploys de funcionalidades** até que as ações corretivas do post-mortem sejam implementadas e o orçamento se recupere.

---

## 3. Verificação de Resolução

```bash
# Burn rate deve cair abaixo de 1.0x após 1-2 minutos de tráfego limpo:
curl -fsS "http://127.0.0.1:9090/api/v1/query?query=job:slo_error_burn_rate:ratio_rate1m"
```
