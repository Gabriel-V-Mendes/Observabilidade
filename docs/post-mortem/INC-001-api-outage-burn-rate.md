# Relatório de Game Day: GD-001 — Simulação Controlada de Queima Rápida de Error Budget e Queda do Serviço `fastapi-app`

- **Data do Exercício:** 6 de novembro de 2026 (15:08:22Z a 15:09:25Z)
- **Tipo de Exercício:** Game Day de Engenharia de Confiabilidade (Chaos / Fault Injection)
- **Ambiente:** Laboratório de Homologação / Staging
- **Componentes Testados:** `observability-api` (`fastapi-app` — porta `8000`) e `webhook-receiver` (porta `8081`)
- **SLOs Avaliados:**
  - Disponibilidade (`>= 99.5%` de requisições sem erro `5xx`)
  - Latência `p95 < 300ms` e `p99 < 500ms`
- **Facilitador do Game Day:** Gabriel V. Mendes (Engenharia SRE)
- **Status:** Concluído com sucesso (Todas as hipóteses de observabilidade e alertas validadas)

---

## 1. Resumo Executivo

Durante o exercício de **Game Day** de Engenharia de Confiabilidade (Chaos / Fault Injection), foram executadas três fases cronometradas em uma única sessão ponta a ponta:

1. **Fase 1 (Injeção de Falhas e Queima de Error Budget):** uma rajada de falhas contínuas (`HTTP 500` em `/items`) elevou o **Pico de Burn Rate (1m)** para **`175.2x`** sobre o orçamento de `0.5%`. O alerta **`SLOErrorBudgetBurnFast`** entrou em `firing` no Prometheus em **32 segundos** e a notificação foi entregue ao receptor externo dedicado (`webhook-receiver`) em um **Tempo Total de Detecção (TTD) de 33 segundos**.
2. **Fase 2 (Queda Proposital do Componente):** o contêiner `fastapi-app` foi interrompido propositalmente (`docker compose stop app`), levando a série `up{job="fastapi-app"}` para `0`. O Prometheus detectou a falha de scrape em **11 segundos** (`Pending`) e transitou o alerta crítico **`TargetDown`** para `Firing` aos **22 segundos**. A notificação crítica foi entregue no receptor externo dedicado (`webhook-receiver`) em um **Tempo Total de Detecção (TTD) de 23 segundos**, comprovando a eficácia do desacoplamento do receptor de notificações da aplicação monitorada.
3. **Fase 3 (Recuperação do Componente e Medição de TTR):** a aplicação foi reiniciada via runbook (`docker compose start app`). O Prometheus raspou o endpoint `/metrics`, reportou `up == 1` e transicionou o status para recuperado em um **Tempo de Recuperação (TTR) de 7 segundos**.

---

## 2. Impacto no Serviço e no Error Budget

| Métrica do Exercício de Game Day | Valor Medido na Execução Única | Limite do SLO / Meta |
|---|---|---|
| **Pico de Burn Rate (1m) na Fase 1** | **`175.2x`** | `<= 1.0x` nominal (`> 14.4x` crítico) |
| **Tempo até Firing da Queima de Budget no Prometheus (`SLOErrorBudgetBurnFast`)** | **`32 segundos`** | `< 60 segundos` |
| **Tempo Total de Detecção (TTD) da Queima de Budget (Notificação Entregue)** | **`33 segundos`** | `< 60 segundos` |
| **Detecção de Queda na Coleta do Prometheus (`up == 0` -> `Pending`)** | **`11 segundos`** | `< 15 segundos` |
| **Tempo até Firing da Queda no Prometheus (`TargetDown`)** | **`22 segundos`** | `< 30 segundos` |
| **Tempo Total de Detecção (TTD) da Queda (Notificação Entregue no Webhook Externo)** | **`23 segundos`** | `< 30 segundos` |
| **Tempo de Recuperação do Componente (`TTR` até `up == 1` no Prometheus)** | **`7 segundos`** | `< 60 segundos` |
| **Consumo do Error Budget Mensal (`216 min` totais em 30 dias)** | **`~0,7 min` (`0,32%` do budget mensal)** | Dentro da margem segura (`99,68%` do orçamento intacto) |

---

## 3. Linha do Tempo Detalhada (UTC)

| Horário (UTC) / Offset | Evento do Game Day | Como foi observado / Validado |
|---|---|---|
| **`T+00s`** (15:08:22Z) | Início da Fase 1: injeção de falhas contínuas `HTTP 500` em `/items` simulando instabilidade severa. | Logs estruturados em formato JSON capturados pelo **Grafana Alloy** e enviados ao **Loki** (`level="ERROR"`). |
| **`T+12s`** | Taxa de erro instantânea salta; Burn Rate (1m) cruza o limiar crítico de `14.4x`, alcançando `141.5x`. | Métrica `job:slo_error_burn_rate:ratio_rate1m` calculada pela Recording Rule no Prometheus. |
| **`T+16s`** | Alerta **`SLOErrorBudgetBurnFast`** entra em estado **`Pending`** no Prometheus. | Painel *Error Budget Burn Rate* no Grafana e endpoint `/api/v1/alerts` do Prometheus. |
| **`T+32s`** | **`SLOErrorBudgetBurnFast`** atinge o pico de **`175.2x`** e entra em **`Firing`** no Prometheus após cumprir a janela `for: 15s`. | Prometheus marca o alerta como disparado (`firing`). |
| **`T+33s`** (15:08:54Z) | Notificação do **Alertmanager** entregue com sucesso ao contêiner isolado `webhook-receiver` com **TTD de 33 segundos** (acompanhada de `HighErrorRate` com 87.58% de erro 5xx). | Auditado com sucesso via payload JSON em `GET http://127.0.0.1:8081/webhook/alerts`. |
| **`T+33s`** (15:08:55Z) | Início da Fase 2: interrupção proposital do contêiner da aplicação (`docker compose stop app`). | Contêiner `fastapi-app` recebe `SIGTERM` e encerra (`Exited (0)`). |
| **`T+44s`** (`+11s` da queda) | Coleta periódica do Prometheus detecta falha na raspagem (`connection refused`). A série `up{job="fastapi-app"}` passa a `0` e o alerta **`TargetDown`** entra em **`Pending`** em **11s**. | Métrica `up == 0` registrada na TSDB do Prometheus. |
| **`T+55s`** (`+22s` da queda) | **`TargetDown`** completa a tolerância de confirmação de 10s (`for: 10s`) e entra em **`Firing`** no Prometheus em **22s**. | Alerta ativado; regra de inibição (`inhibit_rules`) do Alertmanager suprime notificações secundárias de warning. |
| **`T+56s`** (`+23s` da queda, 15:09:18Z) | Notificação de **`TargetDown`** entregue no contêiner externo `webhook-receiver` com **TTD de 23 segundos**. | Payload JSON auditado em `GET http://127.0.0.1:8081/webhook/alerts` apontando para o runbook `target-down.md`. |
| **`T+56s`** (15:09:18Z) | Início da Fase 3: restauração do contêiner da aplicação (`docker compose start app`). | Contêiner `fastapi-app` sobe e inicia o runtime FastAPI em 0.3s. |
| **`T+63s`** (`+7s` do início da recuperação) | Endpoint `/health` responde `200 OK` e Prometheus registra `up{job="fastapi-app"} == 1`, marcando **TTR de 7 segundos**. | Dashboard Grafana volta a reportar disponibilidade em 100% e alerta transiciona para `Resolved`. |

---

## 4. Análise de Causa Raiz (5 Porquês)

1. **Por que o teste de resiliência registrou falhas e indisponibilidade no serviço?**
   Porque a simulação do Game Day injetou falhas `HTTP 500` contínuas na rota crítica `/items` e, em seguida, interrompeu propositalmente o contêiner `fastapi-app` para testar os mecanismos de alerta e resposta.
2. **Por que a injeção inicial consumiu o Error Budget em velocidade crítica?**
   Porque a taxa contínua de respostas `500` elevou o **Burn Rate (1m)** para o pico de **`175.2x`** (ultrapassando o limiar crítico de `14.4x`), sendo detectado pelo Prometheus em 32 segundos e entregue ao receptor de webhook em um **Tempo Total de Detecção (TTD) de 33 segundos**.
3. **Por que a queda do contêiner não impediu o recebimento da notificação de indisponibilidade?**
   Porque o receptor de webhooks do Alertmanager foi desacoplado em um contêiner independente (`webhook-receiver`), assegurando a entrega do alerta crítico `TargetDown` com **Tempo Total de Detecção (TTD) de 23 segundos** mesmo com a API monitorada offline.
4. **Por que o Tempo Total de Detecção (TTD) da queda levou 23 segundos?**
   Porque a detecção somou o ciclo de scrape do Prometheus (5s) que identificou a falha em 11s (`pending`), a janela de tolerância de 10s (`for: 10s`) que disparou o alerta em 22s (`firing`), e o despacho imediato pelo Alertmanager entregando a notificação ao webhook aos 23s (**TTD de 23 segundos**).
5. **Por que a recuperação do serviço foi confirmada com TTR de 7 segundos?**
   Porque o procedimento do runbook executou `docker compose start app`, e logo no ciclo de raspagem subsequente o Prometheus registrou `up == 1` (**TTR de 7 segundos**), restabelecendo os indicadores de disponibilidade.

---

## 5. O Que Funcionou Bem vs O Que Pode Melhorar

### O que funcionou bem
- **Receptor de Webhooks em Contêiner Isolado (`webhook-receiver`):** o desacoplamento garantiu a entrega da notificação de `TargetDown` mesmo durante a queda total da API monitorada, permitindo a medição precisa do TTD de ponta a ponta.
- **Substituição do Promtail pelo Grafana Alloy:** nenhum log foi perdido durante o ciclo `stop`/`start` do contêiner e os campos estruturados em JSON (`level`, `endpoint`, `method`) foram indexados diretamente no Loki.
- **Alertas de Multi-Window Burn Rate:** o alerta `SLOErrorBudgetBurnFast` disparou e notificou com TTD de 33 segundos, muito antes que o orçamento de erro sofresse dano mensal mensurável.
- **Inibição no Alertmanager (`inhibit_rules`):** com o disparo de `TargetDown`, alertas secundários de warning foram inibidos, prevenindo tempestade de alertas para o operador.
- **Runbooks vinculados em 100% dos alertas:** a notificação recebida no webhook continha o link direto para a documentação operacional (`runbook_url`), agilizando o diagnóstico e a mitigação.

### O que pode melhorar
- Topologia de contêiner único local acarreta indisponibilidade no endpoint durante manutenções ou quedas; em Kubernetes (Projeto 3), deve-se adotar `replicaCount: 2` com `PodDisruptionBudget` e HPA.
- Adicionar política de retry com backoff exponencial e circuit breaker para serviços externos.

---

## 6. Plano de Ação (Action Items)

| ID | Ação Corretiva / Preventiva | Tipo | Responsável | Status |
|---|---|---|---|---|
| **AI-01** | Reduzir `scrape_interval` e `evaluation_interval` do Prometheus para **`5s`**, atingindo TTD de **`23s`** para queda total. | Detecção | SRE | ✅ Concluído |
| **AI-02** | Desacoplar o receptor de webhook do Alertmanager em contêiner independente (`webhook-receiver`), medindo o TTD da notificação entregue. | Arquitetura | SRE | ✅ Concluído |
| **AI-03** | Vincular `runbook_url` obrigatório em todas as 8 regras de alerta e validar a integridade dos links no pipeline de CI. | Governança | SRE | ✅ Concluído |
| **AI-04** | Migrar agente de logs do Promtail para o **Grafana Alloy** com pipeline declarativo River e Docker discovery. | Observabilidade | Plataforma | ✅ Concluído |
| **AI-05** | Em ambiente de orquestração Kubernetes (Projeto 3), assegurar réplicas mínimas (`>= 2`), PDB e probes `/health/ready`. | Resiliência | Plataforma | ✅ Documentado |
