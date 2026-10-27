# Runbook: `HighHostCPU` & `HighDiskUsage` — Saturação de Recursos do Host

- **Alertas cobertos:**
  - `HighHostCPU` (`warning`): Uso médio de CPU do host `> 85%` por 2 minutos
  - `HighDiskUsage` (`warning`): Ocupação da partição `/` `> 80%` por 5 minutos
- **Fonte da Métrica:** `node-exporter` (`:9100`)

---

## 1. Diagnóstico

### 1.1 Para `HighHostCPU`: identificar qual container ou processo consome mais CPU
```bash
docker stats --no-stream
ps -eo pid,ppid,cmd,%mem,%cpu --sort=-%cpu | head -n 15
```

### 1.2 Para `HighDiskUsage`: localizar diretórios/volumes pesados e imagens órfãs
```bash
df -h /
docker system df
```

---

## 2. Mitigação

### Limpeza segura de artefatos Docker e logs antigos (`HighDiskUsage`)
```bash
# Remove imagens não utilizadas, cache de build antigo e containers parados
docker image prune -f
docker builder prune -f
```

### Contenção de processo ofensor (`HighHostCPU`)
- Confirme que todos os serviços no `docker-compose.yml` possuem `deploy.resources.limits.cpus` configurados.
- Caso um container específico esteja em loop de CPU, reinicie-o e colete os logs antes via Loki.

---

## 3. Verificação

Verificar no Prometheus que o uso de disco (`< 80%`) e CPU (`< 85%`) normalizaram:
```bash
curl -fsS "http://127.0.0.1:9090/api/v1/query?query=100-(avg(rate(node_cpu_seconds_total{mode='idle'}[2m]))*100)"
```
