# Especificação de SLIs, SLOs e Política de Error Budget

Este documento formaliza os **Service Level Indicators (SLIs)**, os **Service Level Objectives (SLOs)** e a **Política de Error Budget** da API monitorada neste projeto.

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
| **`200.0x`** | `100.0%` (Outage total) | **3,6 horas (216 minutos)** | `SLOErrorBudgetBurnFast` + `TargetDown` | `critical` — Incidente grave (P1) |

---

## 3. Política de Governança do Error Budget

1. **Error Budget > 25%:** Deploys de novas features e experimentos seguem no ritmo normal da engenharia.
2. **Error Budget entre 1% e 25%:** Todo PR exige revisão adicional de confiabilidade e validação em staging.
3. **Error Budget esgotado (0%):** **Feature Freeze automático.** Nenhum deploy de funcionalidade nova é aprovado até que os itens de ação dos post-mortems abertos sejam concluídos e o orçamento volte ao positivo.
