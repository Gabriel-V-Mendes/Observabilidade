# Guia de Instalação em Kubernetes (Mudança do Chart do Loki em 2026 + Grafana Alloy)

Este diretório contém os arquivos `values.yaml` atualizados para implantar a pilha de logs (**Grafana Loki + Grafana Alloy**) em qualquer cluster Kubernetes (`kind`, `k3s`, `EKS`, `GKE`), refletindo as duas principais mudanças oficiais da stack em **2026** com suas respectivas fontes documentais:

---

## 1. O que mudou em 2026 no Chart Oficial do Loki e no Coletor Promtail?

| Componente | Antes | A partir de Março/2026 (Atual) | Fontes Oficiais |
|---|---|---|---|
| **Helm Chart do Loki OSS** | Repositório legado `https://grafana.github.io/helm-charts` (`grafana/loki`) | O chart open-source do Loki migrou oficialmente para o repositório da comunidade **`grafana-community/helm-charts`** (`https://grafana-community.github.io/helm-charts` e OCI `oci://ghcr.io/grafana-community/helm-charts/loki`). O chart antigo no repositório `grafana` passou a ser mantido para o *Grafana Enterprise Logs (GEL)* | • [Grafana Loki Docs — *Upgrade to the community Helm chart*](https://grafana.com/docs/loki/latest/setup/upgrade/upgrade-to-community/)<br>• [Grafana Loki Docs — *Install with Helm*](https://grafana.com/docs/loki/latest/setup/install/helm/)<br>• [`grafana/loki` Helm Chart README](https://github.com/grafana/loki/blob/main/production/helm/loki/README.md) |
| **Agente Coletor de Logs** | **Promtail** (`grafana/promtail`) | O **Promtail** foi oficialmente depreciado pela Grafana Labs e colocado em modo de manutenção/descontinuação, sendo sucedido pelo coletor unificado **Grafana Alloy** (`grafana/alloy`) | • [Grafana Loki Docs — *Promtail (Deprecated / EOL)*](https://grafana.com/docs/loki/latest/send-data/promtail/)<br>• [Grafana Loki Docs — *Migrate from Promtail to Grafana Alloy*](https://grafana.com/docs/loki/latest/setup/migrate/migrate-to-alloy/) |

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
