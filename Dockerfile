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
    ca-certificates curl python3 python3-pip git nodejs npm \
    && rm -rf /var/lib/apt/lists/* \
    curl -LsSf https://astral.sh/uv/install.sh | sh

# nvm lets NODE_VERSION select a Node.js version at container startup.
# Left unset, the apt-installed nodejs/npm above are used (legacy/bundled behavior).
ENV NVM_DIR=/usr/local/nvm
RUN mkdir -p "$NVM_DIR" && \
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash

COPY --from=builder /app/bin/main /usr/local/bin/mcp-auth-proxy
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh
ENV DATA_PATH=/data

ENTRYPOINT [ "/usr/local/bin/docker-entrypoint.sh" ]
