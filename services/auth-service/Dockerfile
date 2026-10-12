FROM golang:1.21-alpine3.17 AS builder

WORKDIR /app

# 1. Configura o proxy oficial do Go (evita falhas de rede/timeout no Docker)
ENV GOPROXY=https://proxy.golang.org,direct

# O fallback direto do Go usa git para buscar os módulos.
RUN apk add --no-cache ca-certificates git

# 2. Copia todos os arquivos do projeto primeiro
COPY . .

# 3. Executa o tidy e o download com os arquivos já no lugar
RUN go mod tidy
RUN go mod download

# 4. Compila o binário de forma estática (Garante portabilidade e que funcione em distroless)
RUN CGO_ENABLED=0 GOOS=linux go build -o auth-service .

FROM gcr.io/distroless/static-debian11 AS build-release-stage

WORKDIR /

# Copia o binário compilado no estágio builder para a raiz da imagem de release
COPY --from=builder /app/auth-service /auth-service

EXPOSE 8001

USER nonroot:nonroot

ENTRYPOINT ["/auth-service"]