FROM ubuntu:20.04 AS builder

ARG DEBIAN_FRONTEND=noninteractive

WORKDIR /app

# Instala Python 3.9, pip e virtualenv
RUN apt-get update && apt-get install --no-install-recommends -y \
    python3.9 \
    python3.9-dev \
    python3-pip \
    python3.9-venv \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Cria o virtual environment em /opt/venv
RUN python3.9 -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

FROM ubuntu:20.04 AS runner-image

ARG DEBIAN_FRONTEND=noninteractive

WORKDIR /app

# Instala apenas o python3.9 no runtime (sem pip e dev-dependencies desnecessárias)
RUN apt-get update && apt-get install --no-install-recommends -y \
    python3.9 \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Copia a pasta do ambiente virtual e o código da aplicação
COPY --from=builder /opt/venv /opt/venv
COPY . .

# Ativa o virtualenv na imagem final
ENV PATH="/opt/venv/bin:$PATH"
ENV PORT=8003

CMD ["gunicorn", "--bind", "0.0.0.0:8003", "app:app"]