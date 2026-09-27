FROM --platform=$BUILDPLATFORM golang:1.22-bookworm AS builder

ENV GOTOOLCHAIN=auto

WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY ./ /app

ARG TARGETARCH
ARG TARGETOS
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH \
    go build -trimpath -ldflags "-w -s" -o /app/bin/main .

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl python3 python3-pip \
    && rm -rf /var/lib/apt/lists/*

ENV NVM_DIR=/usr/local/nvm
ENV NVM_NO_PROGRESS=1
RUN mkdir -p "$NVM_DIR" \
    && curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash \
    && . "$NVM_DIR/nvm.sh" \
    && for v in 16 18 20 22 24; do nvm install "$v"; done \
    && nvm alias default 22 \
    && nvm cache clear

ENV UV_INSTALL_DIR=/usr/local/bin
RUN curl -LsSf https://astral.sh/uv/install.sh | sh

COPY --from=builder /app/bin/main /usr/local/bin/mcp-auth-proxy
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

ENV DATA_PATH=/data
ENV NODE_VERSION=22

ENTRYPOINT [ "/usr/local/bin/docker-entrypoint.sh" ]
