# Runbook: `TargetDown` — Componente Indisponível (`up == 0`)

- **Alertas cobertos:** `TargetDown`
- **Severidade:** `critical`
- **Expressão PromQL:** `up{job=~"fastapi-app|node-exporter|loki|grafana-alloy"} == 0` (por `10s`)
- **Impacto no Usuário / SLO:** Quando `job="fastapi-app"` cai, 100% das requisições falham na borda e o serviço deixa de reportar métricas; agentes de coleta (`grafana-alloy`, `loki`, `node-exporter`) caídos deixam o ambiente cego.

---

## 1. Triagem e Diagnóstico Rápido (< 2 minutos)

### 1.1 Identificar qual container/serviço parou
```bash
docker compose ps -a
```

### 1.2 Inspecionar o código de saída (`ExitCode` / `OOMKilled`) e os últimos logs
```bash
# Substitua <container> pelo alvo indicado no label `job` (ex.: fastapi-app, alloy, loki)
docker inspect <container> --format 'Status={{.State.Status}} ExitCode={{.State.ExitCode}} OOMKilled={{.State.OOMKilled}}'
docker logs --tail 50 <container>
```

### 1.3 Consultar logs no Loki antes da queda (via API ou Grafana Explore)
```bash
curl -G -s "http://127.0.0.1:3100/loki/api/v1/query_range" \
  --data-urlencode 'query={container="fastapi-app"}' \
  --data-urlencode 'limit=20'
```

---

## 2. Ação de Mitigação / Recuperação

### Cenário A: Container parado manualmente ou por falha transitória
```bash
docker compose up -d <servico>
```

### Cenário B: Container em `CrashLoop` / `OOMKilled` (`ExitCode 137`)
1. Verifique se houve deploy recente quebrado (`git log -n 3`).
2. Reverta a imagem/configuração ou ajuste o limite de memória em `docker-compose.yml` e recrie:
```bash
docker compose up -d --build <servico>
```

---

## 3. Verificação de Resolução

1. Confirmar que o endpoint de saúde responde `200 OK`:
```bash
curl -fsS http://127.0.0.1:8000/health
```
2. Confirmar que o Prometheus voltou a enxergar `up == 1`:
```bash
curl -fsS "http://127.0.0.1:9090/api/v1/query?query=up"
```
3. Verificar que o alerta `TargetDown` mudou para `resolved` no Alertmanager (`http://127.0.0.1:9093`).
