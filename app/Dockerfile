# Imagem leve do Python — a versão slim corta o peso da imagem pela metade
FROM python:3.11-slim

WORKDIR /app

# Boa prática: nunca rodar container como root em produção
RUN addgroup --system appgroup && adduser --system --group appuser

# Instala dependências primeiro (aproveita o cache de camadas do Docker)
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Agora sim copia o código da app
COPY src/ /app/src/

# A partir daqui, tudo roda como usuário sem privilégios
USER appuser

EXPOSE 8000

# Sobe o Uvicorn servindo nossa app FastAPI
CMD ["uvicorn", "src.main:app", "--host", "0.0.0.0", "--port", "8000"]