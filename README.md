# Projeto 4 · Observabilidade Cloud-Native, SLOs e Error Budget

[![Observability & SLO CI](https://github.com/Gabriel-V-Mendes/Observabilidade/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/Gabriel-V-Mendes/Observabilidade/actions/workflows/ci.yml)

Plataforma completa de **Observabilidade e Engenharia de Confiabilidade (SRE)** construída com **FastAPI instrumentada (Métricas RED + Logs JSON)**, **Prometheus**, **Node Exporter**, **Grafana Loki (`v3.4.2`, TSDB v13)**, **Grafana Alloy (`v1.7.1`, substituto oficial do Promtail)**, **Alertmanager** e **Grafana** provisionado 100% como código.

---

## 1. Problema (Antes vs Depois)

A primeira versão deste repositório (`commit 0064d1f`) demonstrava o básico de coleta, mas possuía lacunas críticas para operação real de SRE em 2026:

| Sintoma na versão antiga (`0064d1f`) | Consequência prática | Como foi resolvido |
|---|---|---|
| Usava **Promtail** (`grafana/promtail:latest`) lendo `/var/lib/docker/containers` | O Promtail foi **depreciado pela Grafana Labs em favor do coletor unificado Grafana Alloy** ([fonte oficial: Grafana Docs](https://grafana.com/docs/loki/latest/send-data/promtail/)) | Substituído por **Grafana Alloy** com pipeline declarativo River ([`monitoring/alloy/config.alloy`](monitoring/alloy/config.alloy)) descobrindo containers via Docker socket e extraindo campos JSON |
| Sem documentação/manifests da mudança do chart do Loki | O chart OSS do Loki migrou do repositório legado `grafana/loki` para o repositório oficial da comunidade **`grafana-community/helm-charts`** ([fonte oficial: Grafana Upgrade Docs](https://grafana.com/docs/loki/latest/setup/upgrade/upgrade-to-community/)) | Criado [`kubernetes/`](kubernetes/) documentando e configurando o repositório oficial **`grafana-community/loki`** (`oci://ghcr.io/grafana-community/helm-charts/loki`) + `grafana/alloy` |
| Todas as imagens usavam tag `:latest` e não tinham `healthcheck` nem limites de recursos | Builds não reprodutíveis e impossibilidade de usar `docker compose up --wait` | Imagens fixadas por versão, limites de CPU/RAM, Dependabot cobrindo 6 ecossistemas/alvos e healthchecks em todos os serviços |
| Métricas sem contador explícito de erros, buckets padrão e vulnerável a explosão de cardinalidade | Rotas `404` aleatórias criavam milhares de séries no Prometheus; faltava alerta de **Latência p95** e de **Queima de Error Budget (Burn Rate)** | Instrumentação **RED** completa em [`app/src/main.py`](app/src/main.py) com normalização de rotas, buckets alinhados aos SLOs (`0.3s` e `0.5s`) e **Recording Rules** de Burn Rate (`14.4x` e `2.0x`) |
| Alertas entregues na própria API monitorada e sem Runbook | *"Alerta sem ação é ruído"*, e se a API sofria queda total, o webhook caía junto | Receptor desacoplado em contêiner dedicado ([`webhook-receiver:8081`](webhook-receiver/)), 8 regras de alerta com `runbook_url` validado no CI e relatório consolidado de Game Day ([`INC-001`](docs/post-mortem/INC-001-api-outage-burn-rate.md)) |
| Zero testes automatizados e zero pipeline de CI | Alterações quebravam regras PromQL ou a API silenciosamente | Suíte `pytest` (>95% de cobertura na API e no Webhook Receiver), validação com `promtool` e `amtool`, scan `gitleaks` e pipeline E2E em [`.github/workflows/ci.yml`](.github/workflows/ci.yml) |

**Critérios de pronto atendidos:**
- [x] **Promtail trocado por Grafana Alloy** com fontes oficiais e instalação do **Loki** documentada em [`kubernetes/README.md`](kubernetes/README.md).
- [x] **Receptor de Webhooks desacoplado** em contêiner independente na porta `:8081` ([`webhook-receiver`](webhook-receiver/)), garantindo medição do TTD de notificação entregue mesmo em queda total da API.
- [x] **Dependabot ativo cobrindo 6 ecossistemas/alvos** (Compose, Dockerfiles app/webhook-receiver, pip app/webhook-receiver e GitHub Actions).
- [x] **API instrumentada (RED: Taxa, Erros, Duração)** + **Prometheus** + **Node Exporter** + **Dashboards versionados no Git**.
- [x] **SLOs e Error Budget definidos** com alertas de **Burn Rate (Fast/Slow)**, **Taxa de Erro**, **Latência p95 (< 300ms)**, **Latência p99 (< 500ms)** e **Queda de Componente (`TargetDown`)**.
- [x] **Exercício de Game Day consistente (`make gameday`)** com medição cronometrada via `date +%s` de **TTD** (33s para Burn Rate, 23s para queda com notificação entregue) e **TTR** (7s).
- [x] **Relatório de Game Day consolidado** ([`docs/post-mortem/INC-001-api-outage-burn-rate.md`](docs/post-mortem/INC-001-api-outage-burn-rate.md)) e **Runbook para cada alerta** ([`docs/runbooks/`](docs/runbooks/)).

---

## 2. Arquitetura

```mermaid
flowchart TB
    Client(["Clientes / Smoke & Incident Scripts"]) -->|"HTTP :8000\n/items, /error, /slow, /chaos"| API

    subgraph Stack["Docker Compose (observability_net) — Sobe com 1 Comando (make up)"]
        direction TB
        API["FastAPI App (UID 10001 non-root)\n• Métricas RED em /metrics\n• Logs JSON estruturados na stdout"]
        WR["Webhook Receiver (:8081)\n• Receptor isolado de alertas\n• Métricas e auditoria em /webhook/alerts"]
        NE["Node Exporter (:9100)\nCPU, Memória, Disco do Host"]
        Alloy["Grafana Alloy (:12345)\nSubstituto do Promtail (River pipeline)\ndiscovery.docker -> loki.process -> loki.write"]
        Loki[("Grafana Loki 3.4 (:3100)\nEngine TSDB Schema v13")]
        Prom[("Prometheus 3.2 (:9090)\nScrape 5s + Recording Rules SLO\n+ 8 Regras de Alerta")]
        AM["Alertmanager 0.28 (:9093)\nAgrupamento + Inibição\nWebhook / Slack / Discord / E-mail"]
        Grafana["Grafana 11.5 (:3000)\nProvisioning IaC: Datasources + Dashboard JSON"]

        API -. "stdout JSON logs" .-> Alloy
        WR -. "stdout JSON logs" .-> Alloy
        Alloy -->|"Push API /loki/api/v1/push"| Loki
        Prom -->|"Scrape 5s /metrics"| API & WR & NE & Alloy & Loki
        Prom -->|"Dispara alertas (com runbook_url)"| AM
        AM -->|"Notifica + audita (:8081)"| WR
        Grafana -->|"PromQL"| Prom
        Grafana -->|"LogQL"| Loki
    end
```

### Estrutura do Repositório

```text
.
├── .github/
│   ├── dependabot.yml                      # Atualização semanal cobrindo 6 ecossistemas/alvos
│   └── workflows/ci.yml                    # Pipeline CI: Gitleaks + Ruff + Pytest + promtool + amtool + E2E
├── Makefile                                # Atalhos: make up, down, test, lint, smoke, incident, secrets
├── docker-compose.yml                      # Stack completa com healthchecks, limites de recursos e versões fixas
├── .env.example                            # Variáveis de ambiente documentadas (zero segredos no Git)
├── app/
│   ├── Dockerfile                          # Multi-stage, Python 3.12-slim, sem pip, UID 10001, HEALTHCHECK
│   ├── requirements.txt                    # Dependências de produção fixadas
│   ├── requirements-dev.txt                # Pytest, pytest-cov, httpx, ruff
│   ├── src/main.py                         # FastAPI instrumentada (RED metrics, JSON logs, /items, /chaos)
│   └── tests/test_api.py                   # Testes unitários e de instrumentação (>95% cobertura)
├── webhook-receiver/
│   ├── Dockerfile                          # Multi-stage, Python 3.12-slim, non-root UID 10002, HEALTHCHECK :8081
│   ├── requirements.txt                    # Dependências de produção fixadas
│   ├── src/main.py                         # Receptor dedicado de alertas do Alertmanager (:8081)
│   └── tests/test_receiver.py              # Testes unitários do receptor de webhooks e métricas (>95%)
├── monitoring/
│   ├── alloy/config.alloy                  # Pipeline Grafana Alloy (substitui o antigo Promtail)
│   ├── loki/loki-config.yml                # Configuração Loki 3.4+ (TSDB schema v13 + retenção 7d)
│   ├── prometheus/
│   │   ├── prometheus.yml                  # Scrape de 5s nos 7 alvos da stack
│   │   ├── recording_rules.yml             # Pré-cálculo de SLIs, Error Budget Restante e Burn Rate (1m/5m)
│   │   └── alerts.yml                      # 8 alertas (Burn Rate, Erro, p95, p99, TargetDown, Host) com runbook_url
│   ├── alertmanager/alertmanager.yml       # Roteamento por severidade, inibição e templates Slack/Discord/Email
│   └── grafana/
│       ├── provisioning/datasources.yml    # Prometheus (uid: prometheus) e Loki (uid: loki) como código
│       ├── provisioning/dashboards.yml     # Provider automático de dashboards
│       └── dashboards/api-dashboard.json   # Dashboard de SLOs, Burn Rate, RED, Host e Logs do Alloy/Loki
├── kubernetes/
│   ├── README.md                           # Documentação da mudança do chart do Loki em mar/2026 + Alloy
│   ├── loki-values.yaml                    # Values para oci://ghcr.io/grafana-community/helm-charts/loki
│   └── alloy-values.yaml                   # Values para grafana/alloy (DaemonSet Kubernetes)
├── scripts/
│   ├── smoke-test.sh                       # Valida todos os componentes, métricas, logs no Loki e runbooks
│   └── simulate-incident.sh                # Provoca queima de budget + queda da API e cronometra TTD e TTR
└── docs/
    ├── slo-specification.md                # Definição formal dos SLIs, SLOs, matemática de Burn Rate e política
    ├── post-mortem/
    │   └── INC-001-api-outage-burn-rate.md # Post-mortem do Game Day (TTD 33s e 23s, TTR 7s consistentes)
    └── runbooks/                           # 1 runbook acionável para cada grupo de alerta
        ├── target-down.md
        ├── error-budget-burn.md
        ├── high-error-rate.md
        ├── high-latency.md
        └── host-resources.md
```

---

## 3. O que mudou em 2026: Promtail → Grafana Alloy e Novo Repositório Helm do Loki

### 3.1 Por que o Promtail foi substituído pelo Grafana Alloy?
O **Promtail** entrou em depreciação no Loki `3.7` e foi sucedido pelo **Grafana Alloy**, o coletor unificado da Grafana Labs baseado no **OpenTelemetry Collector** com sintaxe declarativa **River** ([`monitoring/alloy/config.alloy`](monitoring/alloy/config.alloy)).
Enquanto o Promtail coletava apenas logs, o Alloy descobre containers nativamente via `discovery.docker`, aplica relabeling (`discovery.relabel`), processa JSON estruturado (`loki.process`), envia logs ao Loki (`loki.write`) e expõe uma UI própria de inspeção de pipeline em `http://localhost:12345`.

### 3.2 Mudança do Repositório Oficial do Chart do Loki (Março de 2026)
Em **16 de março de 2026**, o chart Helm open-source do Loki deixou de ser publicado em `https://grafana.github.io/helm-charts` (onde parou na versão **`v6.55.0`**, ficando restrito ao *Grafana Enterprise Logs*) e migrou para o repositório **`grafana-community/helm-charts`** (com suporte direto a artefatos OCI no GHCR).

Comandos atuais para Kubernetes (detalhes completos e values prontos em [`kubernetes/README.md`](kubernetes/README.md)):

```bash
# 1. Instalar Loki OSS pelo novo registro OCI oficial (2026+):
helm upgrade --install loki oci://ghcr.io/grafana-community/helm-charts/loki \
  --namespace monitoring --create-namespace \
  -f kubernetes/loki-values.yaml --wait

# 2. Instalar Grafana Alloy como DaemonSet coletor de logs:
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
helm upgrade --install alloy grafana/alloy \
  --namespace monitoring \
  -f kubernetes/alloy-values.yaml --wait
```

---

## 4. Como Subir Tudo com Um Único Comando

Pré-requisitos: Docker com Compose v2.

```bash
make up     # ou: docker compose up -d --build --wait
```

O flag `--wait` aguarda todos os containers passarem nos healthchecks antes de liberar o terminal.

| Serviço | URL Local | Credenciais / Finalidade |
|---|---|---|
| **FastAPI App (`/docs` e `/metrics`)** | http://localhost:8000/docs | API monitorada (Métricas RED + Injeção de Falhas) |
| **Webhook Receiver (`/health` e `/webhook/alerts`)** | http://localhost:8081/webhook/alerts | Receptor dedicado de notificações em contêiner desacoplado |
| **Grafana (Dashboard SLO & Logs)** | http://localhost:3000 | `admin` / `admin` (Dashboard provisionado na pasta *SRE & SLOs*) |
| **Prometheus (Targets, Rules & Alerts)** | http://localhost:9090/alerts | Inspeção de SLIs, Recording Rules e estado dos alertas |
| **Grafana Alloy UI (Pipeline de Logs)** | http://localhost:12345 | Visualização ao vivo dos componentes River (`discovery.docker` → `loki.write`) |
| **Alertmanager** | http://localhost:9093 | Agrupamento, inibição e despacho de notificações para o `webhook-receiver` |
| **Loki Readiness** | http://localhost:3100/ready | API de ingestão e consulta LogQL |
| **Node Exporter** | http://localhost:9100/metrics | Métricas de CPU, memória, disco e rede do host |

Para validar que todos os 8 serviços, métricas RED, logs no Loki via Alloy, receptor de webhooks, dashboard no Grafana e runbooks estão funcionando:

```bash
make smoke
```

### Evidências Visuais da Stack em Execução (Grafana, Prometheus, Alloy e FastAPI)

![Grafana Dashboard — Observabilidade, SLOs, Error Budget, Métricas RED, Host e Logs JSON do Alloy/Loki](docs/screenshots/grafana-slo-dashboard.png)

![Prometheus Alert Rules — 8 regras de alerta com runbook_url validado](docs/screenshots/prometheus-alerts.png)

![Grafana Alloy UI — Todos os 5 componentes River Healthy coletando logs para o Loki](docs/screenshots/alloy-pipeline.png)

![Swagger UI da FastAPI Instrumentada (RED + Chaos + Injeção de Falhas)](docs/screenshots/fastapi-observability-swagger.png)

---

## 5. Definição de SLIs, SLOs, Error Budget e Regras de Alerta

A especificação completa encontra-se em [`docs/slo-specification.md`](docs/slo-specification.md).

### 5.1 Objetivos de Nível de Serviço (SLOs)

| Indicador (SLI) | Meta (SLO) | Error Budget (Janela de 30 dias) | Recording Rule no Prometheus |
|---|---|---|---|
| **Disponibilidade** (requisições sem erro `5xx`) | **`>= 99.5%`** | **`0.5%`** (~`216 minutos` de indisponibilidade em 30 dias) | `job:sli_availability:percent1m` e `job:slo_error_budget_remaining:percent5m` |
| **Latência p95** | **`< 300 ms`** (`0.300s`) | 5% das requisições podem superar `300 ms` | `job:sli_latency_p95:seconds1m` |
| **Latência p99** | **`< 500 ms`** (`0.500s`) | 1% das requisições podem superar `500 ms` | `job:sli_latency_p99:seconds1m` |

### 5.2 Catálogo de Alertas e Runbooks ("Alerta sem ação é ruído")

Todas as regras estão declaradas em [`monitoring/prometheus/alerts.yml`](monitoring/prometheus/alerts.yml) e possuem validação obrigatória de `runbook_url` no CI:

| Alerta | Condição PromQL | `for` | Severidade | Runbook Acionável |
|---|---|---|---|---|
| **`TargetDown`** | `up{job=~"fastapi-app\|node-exporter\|loki\|grafana-alloy"} == 0` | `10s` | `critical` | [`docs/runbooks/target-down.md`](docs/runbooks/target-down.md) |
| **`SLOErrorBudgetBurnFast`** | `job:slo_error_burn_rate:ratio_rate1m > 14.4` (taxa 5xx > 7.2%) | `15s` | `critical` | [`docs/runbooks/error-budget-burn.md`](docs/runbooks/error-budget-burn.md) |
| **`SLOErrorBudgetBurnSlow`** | `job:slo_error_burn_rate:ratio_rate5m > 2.0` (taxa 5xx > 1.0%) | `1m` | `warning` | [`docs/runbooks/error-budget-burn.md`](docs/runbooks/error-budget-burn.md) |
| **`HighErrorRate`** | `job:slo_error_ratio:rate1m > 0.01` (erros 5xx > 1%) | `20s` | `critical` | [`docs/runbooks/high-error-rate.md`](docs/runbooks/high-error-rate.md) |
| **`HighLatencyP95`** | `job:sli_latency_p95:seconds1m > 0.300` (`> 300ms`) | `20s` | `warning` | [`docs/runbooks/high-latency.md`](docs/runbooks/high-latency.md) |
| **`HighLatencyP99`** | `job:sli_latency_p99:seconds1m > 0.500` (`> 500ms`) | `20s` | `critical` | [`docs/runbooks/high-latency.md`](docs/runbooks/high-latency.md) |
| **`HighHostCPU`** | Uso médio de CPU do host `> 85%` | `2m` | `warning` | [`docs/runbooks/host-resources.md`](docs/runbooks/host-resources.md) |
| **`HighDiskUsage`** | Ocupação da partição `/` `> 80%` | `5m` | `warning` | [`docs/runbooks/host-resources.md`](docs/runbooks/host-resources.md) |

### 5.3 Janelas de Avaliação de Burn Rate: Laboratório vs Produção Real

Conforme detalhado na [Especificação Formal de SLOs](docs/slo-specification.md#3-janelas-de-avaliação-de-burn-rate-tempos-de-laboratório-vs-produção-real):
- **Janelas utilizadas neste Laboratório (`1m` e `5m`):** São tempos de laboratório calibrados para permitir que o pipeline de CI (`.github/workflows/ci.yml`) e o exercício automatizado de **Game Day** (`make gameday`) provoquem a queima de orçamento, ativem as regras no Prometheus e entreguem a notificação no `webhook-receiver` com medição de **TTD real em menos de 40 segundos**.
- **Janelas que seriam utilizadas em Produção Real (Multi-Window, Multi-Burn-Rate do Google SRE):** Em ambientes produtivos contínuos, janelas de 1 minuto causariam alertas ruidosos (falsos positivos) diante de oscilações transitórias de rede. A arquitetura de produção recomendada pelo *Google SRE Workbook* combina janelas longa e curta com validação mútua:
  - **Fast Burn (Alerta Crítico / Page):** Janela Longa de **`1 hora`** e Janela Curta de **`5 minutos`** com fator de queima **`14.4x`** (consome 2% do orçamento mensal de 30 dias em 1 hora).
  - **Medium Burn (Alerta Urgente / Page):** Janela Longa de **`6 horas`** e Janela Curta de **`30 minutos`** com fator de queima **`6.0x`** (consome 5% do orçamento mensal em 6 horas).
  - **Slow Burn (Alerta Não Urgente / Ticket):** Janela Longa de **`1 a 3 dias`** (24h–72h) e Janela Curta de **`2 a 6 horas`** com fator de queima **`1.0x` a `3.0x`** (consome 10% do orçamento mensal em poucos dias).

---

## 6. Exercício de Game Day, Medição de TTD/TTR e Relatório Consolidado

Para executar o exercício de **Game Day** automatizado (Fase 1: queima rápida de Error Budget via injeção contínua de falhas + Fase 2: queda proposital do container `fastapi-app` com entrega de notificação no contêiner dedicado `webhook-receiver` + Fase 3: recuperação do serviço com medição cronometrada de TTR):

```bash
make gameday     # ou: ./scripts/simulate-incident.sh (alias: make incident)
```

Saída real de execução única cronometrada na stack:

```text
==================================================================
RESUMO DAS MÉTRICAS DO EXERCÍCIO DE GAME DAY (EXECUÇÃO ÚNICA)
==================================================================
  • Pico de Burn Rate (1m) medido na Fase 1:                       175.2x
  • Queima de Budget (SLOErrorBudgetBurnFast -> firing Prometheus): 32s
  • TTD Queima de Budget (notificação entregue no webhook-receiver): 33s
  • Queda do Componente (up == 0 -> pending no Prometheus):        11s
  • Queda do Componente (TargetDown -> firing no Prometheus):      22s
  • TTD Queda do Componente (notificação entregue no webhook):     23s
  • TTR Recuperação após restart (up == 1 no Prometheus):          7s
==================================================================
```

O exercício de **Game Day** foi estruturado para garantir paridade e rastreabilidade absoluta entre a instrumentação e a documentação:
- **Medição precisa com `date +%s`:** O script [`scripts/simulate-incident.sh`](scripts/simulate-incident.sh) calcula os timestamps inteiros na origem (`BURN_START`, `OUTAGE_START`, `RECOVERY_START`), registrando tempos determinísticos.
- **Consistência ponta a ponta:** O **TTD de 33 s** (Queima de Budget), o **TTD de 23 s** (Queda com notificação entregue em `webhook-receiver:8081`) e o **TTR de 7 s** (Recuperação do container) aparecem idênticos e sincronizados no resumo de terminal, na tabela executiva de impacto e na linha do tempo detalhada.
- **Relatório completo de Game Day / Post-Mortem:** [`docs/post-mortem/INC-001-api-outage-burn-rate.md`](docs/post-mortem/INC-001-api-outage-burn-rate.md)

---

## 7. Testes, Validação Estática e Segurança

```bash
make lint       # Ruff (Python) + promtool check config/rules + amtool check-config
make test       # Pytest + cobertura mínima de 90% na API e no Webhook Receiver (atual: >95%)
make smoke      # Valida API, Webhook Receiver, Prometheus, Alloy->Loki, Alertmanager, Grafana e Runbooks
make incident   # Simula Game Day e cronometra TTD (notificação entregue) e TTR (alias: make gameday)
make secrets    # Gitleaks em todo o histórico Git (0 vazamentos)
```

### 7.1 Gestão Contínua de Dependências (Dependabot em 6 Ecossistemas)

O arquivo [`.github/dependabot.yml`](.github/dependabot.yml) executa varreduras semanais automatizadas cobrindo **6 ecossistemas/alvos**:

| # | Ecossistema / Alvo | Diretório | Finalidade e Escopo |
|:---:|---|---|---|
| **1** | `docker-compose` | `/` | Imagens da stack (`prom/prometheus:v3.16.0`, `grafana/loki:3.4.2`, `grafana/alloy:v1.7.1`, `prom/alertmanager:v0.34.2`, `prom/node-exporter:v1.9.0`, `grafana/grafana:11.5.2`) |
| **2** | `docker` | `/app` | Imagem base `python:3.12-slim-bookworm` do contêiner da API monitorada |
| **3** | `docker` | `/webhook-receiver` | Imagem base `python:3.12-slim-bookworm` do contêiner desacoplado do receptor de alertas |
| **4** | `pip` | `/app` | Dependências Python de produção e desenvolvimento da API (`fastapi`, `uvicorn`, `pydantic`, `prometheus-client`, `pytest`, `ruff`) |
| **5** | `pip` | `/webhook-receiver` | Dependências Python do receptor de webhooks (`fastapi`, `uvicorn`, `pydantic`, `prometheus-client`, `pytest`) |
| **6** | `github-actions` | `/` | Actions do pipeline CI fixadas por commit SHA (`actions/checkout`) |

* **Evidência do CI (GitHub Actions):**
  [Run #40609511664 no GitHub Actions](https://github.com/Gabriel-V-Mendes/Observabilidade/actions/runs/40609511664) (todos os jobs `security-and-policy`, `lint-and-validate` e `e2e-observability` aprovados).

---

## 8. Decisões e Trade-offs

| Decisão | Alternativa avaliada | Por quê / Trade-off |
|---|---|---|
| **Grafana Alloy no lugar do Promtail** | Promtail, Fluent Bit, Vector | O Promtail foi oficialmente depreciado pela Grafana Labs em favor do **Grafana Alloy** ([fonte oficial: Grafana Docs](https://grafana.com/docs/loki/latest/send-data/promtail/)). O Alloy unifica coleta de logs, métricas e traces (OpenTelemetry) com UI de depuração (`:12345`) e pipeline declarativo River |
| **Loki com TSDB Schema v13** | Elasticsearch / OpenSearch | O Loki indexa apenas labels de baixa cardinalidade (`container`, `service_name`, `level`, `endpoint`) e comprime o corpo do log em chunks, consumindo ~10x menos RAM que o Elasticsearch |
| **Receptor de Webhooks Desacoplado (`webhook-receiver`)** | Endpoint `/webhook/alerts` dentro da API monitorada | Se a API monitorada cair (`TargetDown`), o receptor cairia junto e o alerta não seria entregue. Com o contêiner dedicado (`webhook-receiver:8081`), o Alertmanager entrega a notificação e o TTD medido reflete uma entrega real |
| **Alertas baseados em Burn Rate do Error Budget** (`14.4x` e `2.0x`) | Apenas limiar fixo de erro instantâneo | Alertar pela velocidade de consumo do orçamento (`0.5%`) evita falsos positivos em micro-oscilações e avisa imediatamente quando um incidente coloca a meta mensal (`99.5%`) em risco |
| **Janelas de Burn Rate de 1m e 5m no Lab** | Janelas de produção de 1h/5m e 24h/2h | Janelas curtas de 1m/5m com `scrape_interval: 5s` permitem testar cenários de queima e queda de componente no CI e em Game Days medindo TTD em menos de 40 segundos. Em produção 24x7, aplicam-se janelas Multi-Window (1h/5m para 14.4x) |
| **Normalização de `endpoint` no middleware da API** | Usar `request.url.path` bruto como label | Impede ataque/acidente de explosão de cardinalidade no Prometheus quando clientes requisitam URLs dinâmicas inexistentes (`/item/12345` vira `/items/{id}` ou `/unknown`) |

---

## 9. Custo Estimado

Valores de referência em **outubro/2026** (sem impostos):

| Cenário | Infraestrutura | Custo Mensal Estimado | Observação |
|---|---|---|---|
| **1. Execução Local (`docker compose`)** | 8 containers locais (FastAPI App, Webhook Receiver, Prometheus, Node Exporter, Loki, Alloy, Alertmanager, Grafana) com limites de recursos | **US$ 0,00 / mês** | Custo zero para desenvolvimento, estudo e validação de incidentes/Game Days |
| **2. CI/CD (GitHub Actions em repo público)** | Jobs `security-and-policy`, `lint-and-validate` e `e2e-observability` | **US$ 0,00 / mês** | Runners Ubuntu gratuitos para repositórios públicos |
| **3. VPS Dedicada de Monitoramento (Hetzner CX23 / 4 GB RAM)** | 2 vCPU, 4 GB RAM, 40 GB NVMe rodando toda a stack Docker Compose com retenção de 7–15 dias | **≈ € 5,99 / mês (~US$ 6,50)** | Suficiente para monitorar dezenas de serviços pequenos sem custo por GB ingerido |
| **4. Grafana Cloud (Free Tier vs Pro)** | Até 10k séries Prometheus + 50 GB de logs Loki + 3 usuários | **US$ 0,00 / mês** (Free Tier) | Acima da franquia: ~US$ 0,50/GB de logs ingeridos e ~US$ 8 por 1k séries ativas |

---

## 10. O que eu faria diferente

1. **Rastreamento Distribuído (Distributed Tracing) com Grafana Tempo + OpenTelemetry SDK:** hoje correlacionamos métricas (Prometheus) e logs estruturados (Loki) via `request_id`. Como o **Grafana Alloy** já é nativamente compatível com OTLP (`otelcol.receiver.otlp`), o próximo passo natural seria instrumentar a FastAPI com `opentelemetry-instrumentation-fastapi` enviando spans para o **Grafana Tempo**, habilitando *Exemplars* (clicar num ponto de latência p99 no gráfico e abrir o trace exato).
2. **Armazenamento de Objetos (S3 / MinIO) para Loki e Thanos/Mimir no Prometheus:** no Compose local usamos volumes de disco com retenção de 7 dias. Em produção, apontaria o Loki e o Prometheus (via Thanos ou Grafana Mimir) para buckets S3 com política de lifecycle para retenção de longo prazo (90–365 dias) a baixo custo.
3. **Multi-Window Multi-Burn-Rate Completo (1h/5m e 6h/30m):** reduzimos as janelas para `1m` e `5m` para permitir demonstração e medição prática de confiabilidade em segundos durante o `make gameday`. Em produção real com tráfego 24/7, utilizaria os pares canônicos do livro *Google SRE Workbook* (`1h + 5m` para `14.4x` e `6h + 30m` para `6x`) para evitar notificações por picos de menos de 2 minutos.
4. **Autenticação OAuth2 / OIDC no Grafana e TLS reverso:** substituir a credencial local (`admin`/`admin`) por SSO corporativo (GitHub/Google OAuth) e expor apenas o Grafana via proxy TLS.
5. **Testes Contínuos de Sintéticos (Blackbox Exporter):** adicionar o `prometheus/blackbox_exporter` testando a API de fora para dentro (HTTP/TLS/DNS) para medir disponibilidade na perspectiva externa mesmo quando a API inteira trava.

---

## 11. Série Completa do Portfólio DevOps & SRE (5 Projetos Conectados)

| # | Projeto | Repositório Oficial | CI Status |
|:---:|---|---|---|
| **1** | **Containerização & Pipeline CI/CD (DevSecOps)** | [`Gabriel-V-Mendes/ContainerizacaoPipelineCICD`](https://github.com/Gabriel-V-Mendes/ContainerizacaoPipelineCICD) | [![CI/CD](https://github.com/Gabriel-V-Mendes/ContainerizacaoPipelineCICD/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/Gabriel-V-Mendes/ContainerizacaoPipelineCICD/actions/workflows/ci.yml) |
| **2** | **Infraestrutura AWS com OpenTofu & Floci (FinOps + OIDC)** | [`Gabriel-V-Mendes/infraestrutura-aws-opentofu-floci`](https://github.com/Gabriel-V-Mendes/infraestrutura-aws-opentofu-floci) | [![Infra CI/CD](https://github.com/Gabriel-V-Mendes/infraestrutura-aws-opentofu-floci/actions/workflows/infra-ci.yml/badge.svg?branch=main)](https://github.com/Gabriel-V-Mendes/infraestrutura-aws-opentofu-floci/actions/workflows/infra-ci.yml) |
| **3** | **GitOps & Kubernetes (ArgoCD + Helm + Gateway API + SOPS/ESO)** | [`Gabriel-V-Mendes/GitOps_Kubernetes`](https://github.com/Gabriel-V-Mendes/GitOps_Kubernetes) | [![Validate Manifests & Security](https://github.com/Gabriel-V-Mendes/GitOps_Kubernetes/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/Gabriel-V-Mendes/GitOps_Kubernetes/actions/workflows/ci.yml) |
| **4** | **Observabilidade & SRE (Prometheus + Grafana Alloy + Loki + Alertmanager)** *(este repo)* | [`Gabriel-V-Mendes/Observabilidade`](https://github.com/Gabriel-V-Mendes/Observabilidade) | [![Observability & SLO CI](https://github.com/Gabriel-V-Mendes/Observabilidade/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/Gabriel-V-Mendes/Observabilidade/actions/workflows/ci.yml) |
| **5** | **Platform Engineering & Golden Path (IDP + Reusable Workflows + TF Modules)** | [`Gabriel-V-Mendes/platform-engineering`](https://github.com/Gabriel-V-Mendes/platform-engineering) | [![Platform CI](https://github.com/Gabriel-V-Mendes/platform-engineering/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/Gabriel-V-Mendes/platform-engineering/actions/workflows/ci.yml) |

