FROM ubuntu:20.04 as builder
ARG DEBIAN_FRONTEND=noninteractive
WORKDIR /app
RUN apt-get update && apt-get install --no-install-recommends -y \
    python3.9 \
    python3.9-dev \
    python3-pip \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN python3.9 -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

COPY requirements.txt .
RUN pip3 install --no-cache-dir -r requirements.txt


FROM ubuntu:20.04 AS runner-image

ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install --no-install-recommends -y python3.9 python3-venv && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

COPY --from=builder-image /opt/venv /opt/venv

# activate virtual environment
ENV VIRTUAL_ENV=/opt/venv
ENV PATH="/opt/venv/bin:$PATH"

EXPOSE 8005

CMD ["python"]