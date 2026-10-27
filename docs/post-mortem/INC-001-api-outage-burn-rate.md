# Post-Mortem: INC-001 — Esgotamento Rápido de Error Budget e Queda do Serviço `fastapi-app`

- **Data do Incidente:** 26 de outubro de 2026
- **Severidade:** `SEV-1 (Crítica)`
- **Serviço Afetado:** `observability-api` (`fastapi-app` — porta `8000`)
- **SLOs Impactados:**
  - Disponibilidade (`>= 99.5%`) — Violado durante a janela do incidente
  - Latência `p95 < 300ms` e `p99 < 500ms` — Violados durante a Fase 1
- **Autor / Comandante do Incidente:** Gabriel V. Mendes (Engenharia SRE)
- **Status:** Resolvido (Ações corretivas concluídas)

---

## 1. Resumo Executivo

Durante o exercício controlado de Engenharia de Confiabilidade (Chaos / Fault Injection), ocorreram dois eventos encadeados no serviço `observability-api`:
1. **Fase 1 (Degradação Severa e Queima de Error Budget):** uma rajada de falhas (`HTTP 500` com timeout simulado de banco `DB_TIMEOUT` entre `350ms` e `650ms`) elevou a taxa de erro acima de `7.2%`, disparando o alerta **`SLOErrorBudgetBurnFast`** (Burn Rate `> 14.4x` sobre o orçamento de `0.5%`), além de **`HighErrorRate`**, **`HighLatencyP95`** e **`HighLatencyP99`**.
2. **Fase 2 (Queda Total do Componente):** o container `fastapi-app` foi interrompido propositalmente (`docker compose stop app`), levando a métrica `up{job="fastapi-app"}` para `0`. O Prometheus detectou a falha de scrape em **5 segundos** (`Pending`) e disparou o alerta crítico **`TargetDown`** (`Firing`) após a janela de confirmação de `10s` (**Tempo Total de Detecção / TTD = 15 segundos**). O componente foi restaurado via runbook (`docker compose start app`) com **Tempo de Recuperação (TTR) = 6 segundos**.

---

## 2. Impacto no Usuário e no Error Budget

| Métrica de Confiabilidade | Valor Medido | Limite do SLO / Meta |
|---|---|---|
| **Tempo até Detecção de Queima de Budget (`SLOErrorBudgetBurnFast`)** | **32 segundos** (rajada de erros -> Burn Rate 172x -> `Firing`) | `< 60 segundos` |
| **Tempo até Detecção de Queda na Coleta (`up == 0` -> `Pending`)** | **9 segundos** | `< 15 segundos` |
| **Tempo até Disparo do Alerta Crítico (`TargetDown` -> `Firing` / TTD)** | **19 segundos** | `< 30 segundos` |
| **Tempo de Recuperação após Intervenção (`TTR`)** | **8 segundos** | `< 60 segundos` |
| **Pico de Burn Rate (1m)** | **`172.4x`** (100% de falha na rajada) | `<= 1.0x` nominal (`14.4x` crítico) |
| **Consumo do Error Budget Mensal (`216 min` totais em 30 dias)** | **`~0,7 min` (`0,32%` do budget mensal)** | Dentro da margem segura (restando `99,68%` do orçamento de 30 dias) |

---

## 3. Linha do Tempo Detalhada (UTC-3)

| Horário / Offset | Evento | Como foi observado |
|---|---|---|
| **`T+00s`** | Início da Fase 1: rajada de 25 requisições contra `/error` simulando timeout de banco (`DB_TIMEOUT`, `HTTP 500`, latência `350–650ms`). | Logs JSON estruturados capturados pelo **Grafana Alloy** e enviados ao **Loki** (`level="ERROR"`, `error_code="DB_TIMEOUT"`). |
| **`T+05s`** | Primeiro ciclo de scrape/avaliação do Prometheus (`5s`): `job:slo_error_burn_rate:ratio_rate1m` salta acima de `14.4x`; alertas `SLOErrorBudgetBurnFast`, `HighErrorRate`, `HighLatencyP95` e `HighLatencyP99` entram em **`Pending`**. | Painel *Error Budget Burn Rate* no Grafana cruza a linha vermelha (`14.4x`). |
| **`T+16s`** | Alerta **`SLOErrorBudgetBurnFast`** completa a janela `for: 15s` e entra em **`Firing`**. O **Alertmanager** agrupa e despacha a notificação contendo o link do [Runbook `error-budget-burn.md`](../runbooks/error-budget-burn.md). | Webhook recebido e auditado em `GET /webhook/alerts`. |
| **`T+20s`** | Início da Fase 2: interrupção proposital do container da aplicação (`docker compose stop app`). | Container `fastapi-app` recebe `SIGTERM` e encerra (`Exited (0)`). |
| **`T+25s` (`+5s` da queda)** | Próximo scrape do Prometheus falha (`connection refused` em `app:8000/metrics`). A série `up{job="fastapi-app"}` passa para **`0`** e o alerta **`TargetDown`** entra em **`Pending`**. | Métrica `up == 0` no Prometheus. |
| **`T+35s` (`+15s` da queda)** | **`TargetDown`** completa `for: 10s` e entra em **`Firing`** (**TTD = 15s**). A regra de inibição (`inhibit_rules`) do Alertmanager suprime alertas de severidade `warning` redundantes. | Alerta crítico no Alertmanager apontando para o [Runbook `target-down.md`](../runbooks/target-down.md). |
| **`T+36s`** | Plantonista executa o procedimento do Runbook `target-down.md`: `docker compose start app`. | Container `fastapi-app` reiniciado. |
| **`T+42s` (`+6s` da ação)** | Endpoint `/health` responde `200 OK`, Prometheus raspa `up{job="fastapi-app"} == 1` e o alerta `TargetDown` transiciona para **`Resolved`** (**TTR = 6s**). | Dashboard Grafana volta ao verde (`Disponibilidade 100%` na janela recente). |

---

## 4. Análise de Causa Raiz (5 Porquês)

1. **Por que os usuários receberam erro e indisponibilidade?**
   Porque a API sofreu primeiro uma falha de timeout na rota crítica (`/error`) retornando `HTTP 500` e, em seguida, o processo do container `fastapi-app` foi interrompido.
2. **Por que a falha inicial consumiu rapidamente o Error Budget?**
   Porque 100% das requisições da rajada retornaram `500` com latência acima de `500ms`, gerando uma taxa de queima (`Burn Rate`) de `200x` sobre o orçamento de `0.5%`.
3. **Por que a queda do container causou indisponibilidade imediata?**
   Porque o ambiente local rodava com réplica única (`1 container`) sem outra instância saudável atrás de um balanceador.
4. **Por que o tempo de detecção da queda levou 15 segundos (e não 0s)?**
   Porque o ciclo de detecção soma o intervalo de coleta (`scrape_interval: 5s`) com o tempo de confirmação (`for: 10s` na regra `TargetDown`), calibrado para evitar falsos positivos em micro-oscilações de rede.
5. **Como os logs ajudaram a isolar a causa em menos de 1 minuto?**
   O **Grafana Alloy** extraiu os campos JSON (`level="ERROR"`, `status_code=500`, `duration_ms`, `request_id`) diretamente da `stdout` do container e indexou no **Loki**, permitindo correlacionar imediatamente o pico no gráfico do Prometheus com a mensagem `error_code="DB_TIMEOUT"` no painel de logs do Grafana.

---

## 5. O Que Funcionou Bem vs O Que Pode Melhorar

### O que funcionou bem
- **Substituição do Promtail pelo Grafana Alloy:** nenhum log foi perdido durante o `stop`/`start` do container e os campos JSON (`level`, `endpoint`, `method`) já vieram rotulados no Loki.
- **Alertas de Multi-Window Burn Rate:** o alerta `SLOErrorBudgetBurnFast` disparou em `16s`, muito antes que o orçamento mensal sofresse dano significativo.
- **Inibição no Alertmanager (`inhibit_rules`):** quando `TargetDown` disparou, alertas secundários de `warning` foram inibidos, evitando fadiga de alerta.
- **Runbooks vinculados em 100% dos alertas:** o link direto na notificação eliminou adivinhação durante a resposta ao incidente.

### O que pode melhorar
- Réplica única da API significa que a parada do container causa indisponibilidade imediata até o restart.
- Falta de circuit breaker / retry com backoff para falhas transitórias de banco (`DB_TIMEOUT`).

---

## 6. Plano de Ação (Action Items)

| ID | Ação Corretiva / Preventiva | Tipo | Responsável | Status |
|---|---|---|---|---|
| **AI-01** | Reduzir `scrape_interval` e `evaluation_interval` do Prometheus de `15s` para **`5s`**, reduzindo o TTD de `~75s` para **`15s`**. | Detecção | SRE | ✅ Concluído |
| **AI-02** | Vincular `runbook_url` obrigatório em todas as 8 regras de alerta e validar a existência do arquivo no pipeline de CI (`.github/workflows/ci.yml`). | Governança | SRE | ✅ Concluído |
| **AI-03** | Migrar coletor de logs de Promtail (depreciado) para **Grafana Alloy** com parse de logs JSON estruturados. | Observabilidade | Plataforma | ✅ Concluído |
| **AI-04** | Em ambiente Kubernetes (Projeto 3), manter no mínimo `replicaCount: 2` com `PodDisruptionBudget` e `readinessProbe` (`/health/ready`). | Mitigação | Plataforma | ✅ Documentado |
