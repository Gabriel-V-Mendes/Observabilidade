# Guia de Instalação em Kubernetes (Mudança do Chart do Loki em 2026 + Grafana Alloy)

Este diretório contém os arquivos `values.yaml` atualizados para implantar a pilha de logs (**Grafana Loki + Grafana Alloy**) em qualquer cluster Kubernetes (`kind`, `k3s`, `EKS`, `GKE`), refletindo as duas principais mudanças da stack em **2026**:

---

## 1. O que mudou em 2026 no Chart Oficial do Loki?

Em **16 de março de 2026**, a Grafana Labs alterou oficialmente a distribuição dos Helm charts do Loki:

| Antes de Março/2026 | A partir de Março/2026 (Atual) | Impacto |
|---|---|---|
| Repositório `https://grafana.github.io/helm-charts` (`grafana/loki`, congelado na versão `v6.55.0`) | Repositório **`grafana-community`** (`https://grafana-community.github.io/helm-charts` ou OCI `oci://ghcr.io/grafana-community/helm-charts/loki`) | O chart antigo no repo `grafana` passou a ser exclusivo para o **Grafana Enterprise Logs (GEL)**. Usuários de **Loki Open Source (OSS)** devem usar `grafana-community/loki` |
| Coletor de logs padrão: **Promtail** (`grafana/promtail`) | Coletor unificado: **Grafana Alloy** (`grafana/alloy`) | O Promtail foi depreciado no Loki 3.7 e encerrado em favor do **Grafana Alloy** (baseado em OpenTelemetry e configuração River) |

---

## 2. Comandos de Instalação Atualizados (Helm 3.16+)

### 2.1 Instalar o Grafana Loki (via OCI no GHCR — Recomendado)

```bash
helm upgrade --install loki oci://ghcr.io/grafana-community/helm-charts/loki \
  --namespace monitoring \
  --create-namespace \
  -f kubernetes/loki-values.yaml \
  --wait
```

Ou via repositório HTTPS tradicional (`grafana-community`):

```bash
helm repo add grafana-community https://grafana-community.github.io/helm-charts
helm repo update

helm upgrade --install loki grafana-community/loki \
  --namespace monitoring \
  --create-namespace \
  -f kubernetes/loki-values.yaml \
  --wait
```

### 2.2 Instalar o Grafana Alloy (DaemonSet coletando logs dos Pods)

```bash
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update

helm upgrade --install alloy grafana/alloy \
  --namespace monitoring \
  -f kubernetes/alloy-values.yaml \
  --wait
```
