import time
import random
from fastapi import FastAPI, Request, Response
from prometheus_client import Counter, Histogram, generate_latest, CONTENT_TYPE_LATEST

app = FastAPI()

# --- Métricas que o Prometheus vai coletar ---

# Contador: conta quantas requisições a API recebeu, separado por método, rota e status HTTP.
# Esse cara só sobe, nunca desce. Ideal pra saber o volume de tráfego e taxa de erros.
REQUESTS_TOTAL = Counter(
    "app_requests_total",
    "Total de requisições recebidas pela API",
    ["method", "endpoint", "http_status"]
)

# Histograma: mede quanto tempo cada requisição demorou pra responder.
# Com ele a gente consegue calcular os percentis (p95, p99) pra saber se tá lento.
REQUEST_DURATION = Histogram(
    "app_request_duration_seconds",
    "Latência das requisições em segundos",
    ["method", "endpoint"]
)

# --- Middleware: intercepta TODA requisição que entra na API ---

@app.middleware("http")
async def monitor_requests(request: Request, call_next):
    # Pula a rota /metrics, senão o próprio scrape do Prometheus polui os números
    if request.url.path == "/metrics":
        return await call_next(request)

    start_time = time.time()
    
    try:
        response = await call_next(request)
        status_code = response.status_code
    except Exception as e:
        status_code = 500  # Se explodir, marca como erro 500
        raise e
    finally:
        # Calcula quanto tempo levou e registra nos dois instrumentos
        duration = time.time() - start_time
        
        REQUEST_DURATION.labels(
            method=request.method, 
            endpoint=request.url.path
        ).observe(duration)  # Joga a latência no histograma
        
        REQUESTS_TOTAL.labels(
            method=request.method, 
            endpoint=request.url.path, 
            http_status=status_code
        ).inc()  # Soma +1 no contador

    return response

# --- Rotas da API ---

@app.get("/metrics")
def metrics():
    """Endpoint que o Prometheus raspa a cada 15s pra puxar as métricas."""
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)

@app.get("/items")
def read_items():
    """Rota normal — simula uma resposta saudável com latência entre 100-400ms."""
    time.sleep(random.uniform(0.1, 0.4))
    return {"message": "Sucesso!"}

@app.get("/error")
def trigger_error():
    """Rota propositalmente quebrada — serve pra testar se os alertas disparam."""
    time.sleep(random.uniform(0.5, 1.2))  # Latência alta de propósito (viola o SLO)
    return Response(status_code=500, content="Erro interno simulado!")