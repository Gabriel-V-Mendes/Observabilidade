# Especificação de SLIs, SLOs, Janelas de Burn Rate (Lab vs. Produção) e Política de Error Budget

Este documento formaliza os **Service Level Indicators (SLIs)**, os **Service Level Objectives (SLOs)**, a **calibração de janelas de Burn Rate (Laboratório vs. Produção)** e a **Política de Error Budget** da API monitorada neste projeto.

---

## 1. Resumo dos SLIs e SLOs

| Dimensão | SLI (Indicador Medido no Prometheus) | SLO (Objetivo) | Janela de Conformidade | Error Budget (Orçamento de Falha) |
|---|---|---|---|---|
| **Disponibilidade** | Proporção de requisições HTTP que **não** retornam status `5xx`: `(1 - sum(rate(app_requests_total{http_status=~"5.."}[W])) / sum(rate(app_requests_total[W]))) * 100` | **`>= 99.5%`** | 30 dias corridos | **`0.5%`** das requisições (~`216 minutos` de indisponibilidade total equivalente em 30 dias) |
| **Latência (p95)** | Percentil 95 do histograma `app_request_duration_seconds_bucket` | **`< 300 ms` (`0.300s`)** | 30 dias corridos | 5% das requisições podem exceder `300 ms` |
| **Latência (p99)** | Percentil 99 do histograma `app_request_duration_seconds_bucket` | **`< 500 ms` (`0.500s`)** | 30 dias corridos | 1% das requisições podem exceder `500 ms` |

---

## 2. Matemática do Error Budget e Burn Rate

Com um **SLO de Disponibilidade de `99.5%`**, a fração máxima permitida de erros é:

$$\text{Error Budget} = 1 - 0.995 = 0.005 \text{ (ou } 0.5\%)$$

O **Burn Rate (Taxa de Queima)** mede quantas vezes mais rápido estamos consumindo esse orçamento em relação à taxa sustentável (`1.0x`):

$$\text{Burn Rate} = \frac{\text{Taxa de Erro Atual}}{\text{Error Budget}} = \frac{\text{error\_ratio}}{0.005}$$

| Burn Rate | Taxa de Erro 5xx Real | Tempo até zerar o Budget de 30 dias | Alerta Configurado | Severidade / Ação |
|---|---|---|---|---|
| **`1.0x`** | `0.5%` | 30 dias (720h) | Nenhum (consumo nominal) | Operação normal |
| **`2.0x`** | `1.0%` | 15 dias (360h) | `SLOErrorBudgetBurnSlow` | `warning` — Investigar no próximo turno ([Runbook](runbooks/error-budget-burn.md)) |
| **`14.4x`** | `7.2%` | ~50 horas (consome 2% em 1h) | `SLOErrorBudgetBurnFast` | `critical` — Ação imediata de plantão ([Runbook](runbooks/error-budget-burn.md)) |
| **`200.0x`** | `100.0%` (Outage total) | **3,6 horas (216 minutos)** | `SLOErrorBudgetBurnFast` + `TargetDown` | `critical` — Resposta imediata |

---

## 3. Janelas de Avaliação de Burn Rate: Tempos de Laboratório vs. Produção Real

Em [`monitoring/prometheus/recording_rules.yml`](../monitoring/prometheus/recording_rules.yml) e [`monitoring/prometheus/alerts.yml`](../monitoring/prometheus/alerts.yml), utilizamos janelas de **`1m` (Fast Burn)** e **`5m` (Slow Burn)** combinadas com `scrape_interval: 5s` e `for: 15s`.

**Por que `1m` e `5m` no laboratório?**
Para que o pipeline de CI (`.github/workflows/ci.yml`) e o exercício automatizado de **Game Day** (`make gameday` / `make incident`) possam provocar a queima de orçamento, disparar o alerta no Prometheus, entregar a notificação via Alertmanager no contêiner `webhook-receiver` e medir o **TTD real em menos de 30 segundos**.

**Quais janelas seriam usadas em produção real?**
Em produção 24x7, janelas de `1m` causariam falsos positivos em micro-oscilações de rede e teriam reset lento sem uma janela curta de confirmação. O padrão de produção segue a arquitetura **Multi-Window, Multi-Burn-Rate** do [*Google SRE Workbook* (Capítulo 5 — *Alerting on SLOs*)](https://sre.google/workbook/alerting-on-slos/):

| Regra de Alerta | Severidade | Burn Rate | Orçamento Mensal Consumido | Janela neste Laboratório (`recording_rules.yml`) | Janelas em Produção (Long Window + Short Window) |
|---|---|---|---|---|---|
| **Fast Burn (Page Crítico)** | `critical` (Page) | **`14.4x`** (erro `> 7.2%` p/ SLO 99,5%) | **2%** do budget de 30 dias em 1 hora | `rate[1m]` (`for: 15s`) | **Longa: `1h` E Curta: `5m`** (`ratio_rate1h > 14.4 and ratio_rate5m > 14.4`) |
| **Medium Burn (Page Urgente)** | `critical` (Page) | **`6.0x`** (erro `> 3.0%` p/ SLO 99,5%) | **5%** do budget de 30 dias em 6 horas | *(representado pelo `1m`/`5m` no lab)* | **Longa: `6h` E Curta: `30m`** (`ratio_rate6h > 6.0 and ratio_rate30m > 6.0`) |
| **Slow Burn (Ticket)** | `warning` (Ticket) | **`1.0x` – `3.0x`** (erro `> 0.5%`–`1.5%`) | **10%** do budget de 30 dias em 1 a 3 dias | `rate[5m]` (`for: 1m`, limiar `> 2.0x`) | **Longa: `1d` (24h) E Curta: `2h`** (para `3.0x`) ou **Longa: `3d` (72h) E Curta: `6h`** (para `1.0x`) |

---

## 4. Política de Governança do Error Budget

1. **Error Budget > 25%:** Deploys de novas features e experimentos seguem no ritmo normal da engenharia.
2. **Error Budget entre 1% e 25%:** Todo PR exige revisão adicional de confiabilidade e validação em staging.
3. **Error Budget esgotado (0%):** **Feature Freeze automático.** Nenhum deploy de funcionalidade nova é aprovado até que os itens de ação dos relatórios de incidente/Game Day abertos sejam concluídos e o orçamento volte ao positivo.
