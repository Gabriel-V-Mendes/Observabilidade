# 🔭 Laboratório de Observabilidade e SRE

Fala, pessoal! Esse repositório é o resultado do meu estudo sobre **Observabilidade Cloud-Native** e cultura **SRE (Site Reliability Engineering)**. 

A ideia aqui foi construir do zero um ambiente real de monitoramento, aprender como as ferramentas se conectam e como a gente sai do "achismo" pra ter dados matemáticos sobre a saúde de uma aplicação.

---

## 📚 O que eu aprendi e fiz nesse projeto?

1. **Instrumentação de Código:** Criei uma API em Python (FastAPI) e ensinei ela a expor suas próprias métricas (quantos acessos teve, quanto tempo demorou pra responder).
2. **Coleta de Métricas (Scraping):** Subi um **Prometheus** pra bater na porta da minha API a cada 15 segundos e guardar o histórico desses números.
3. **Monitoramento do Servidor:** Usei o **Node Exporter** pra saber se a máquina (host) estava sofrendo com falta de CPU, RAM ou disco cheio.
4. **Agregação de Logs:** Configurei o **Promtail** pra ler os logs perdidos nos containers Docker e mandar tudo organizadinho pro **Loki** (que indexa logs igual o Prometheus indexa métricas).
5. **Cultura SRE (Error Budget):** Aprendi que tentar ter 100% de disponibilidade é ilusão. Criei painéis no **Grafana** definindo um SLO de 99.5%. Se a barrinha do erro passar de 0.5% (meu Error Budget), a tela fica vermelha.
6. **Alertas Inteligentes:** Escrevi regras matemáticas (PromQL). Se a API ficar mais de 1 minuto inteira quebrada, o **Alertmanager** agrupa tudo e me manda uma notificação lá no canal do Slack.

---

## 🏗️ Como as peças se encaixam?

A arquitetura ficou dividida assim:

```
┌──────────────┐                 ┌──────────────┐                 ┌──────────────┐
│  FastAPI App │  ◄── raspa ───  │  Prometheus  │  ── avisa ──►   │ Alertmanager │ ──► Slack
│  (Gera dados)│                 │ (Motor / DB) │                 │  (Carteiro)  │
└──────┬───────┘                 └──────┬───────┘                 └──────────────┘
       │                                │
      logs                           consulta
       ▼                                ▼
┌──────────────┐                 ┌──────────────┐
│  Promtail    │  ── envia ──►   │   Grafana    │
│  (Coletor)   │      pro Loki   │ (Televisão)  │
└──────────────┘                 └──────────────┘
```

Tudo subindo no **Docker Compose**. Ah, e fiz tudo com **Provisioning (IaC)**: quando o Grafana sobe, ele já lê meus arquivos YAML e JSON. Eu não preciso dar um único clique na interface pra configurar banco de dados ou criar dashboard. Tudo automático.

---


## 📁 Estrutura de Pastas

Ficou organizadinho assim:
* `/app`: Meu código Python e as métricas.
* `/monitoring/prometheus`: Onde moram as regras de alarme.
* `/monitoring/grafana`: Onde moram os dashboards em JSON.
* `/monitoring/alertmanager`: Quem decide pra qual chat do Slack o alarme vai.
* `/monitoring/loki` e `/promtail`: A dupla dinâmica que cuida dos logs.

---
*Estudo feito para entender na prática como monitorar sistemas
