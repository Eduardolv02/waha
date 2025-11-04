# ===== Build Stage =====
FROM node:22.16-bookworm-slim AS build
ENV PUPPETEER_SKIP_DOWNLOAD=True

WORKDIR /git

# Copiar package.json y yarn.lock
COPY package.json yarn.lock ./

# Instalar dependencias (Yarn ya preinstalado)
RUN yarn install --immutable --network-timeout 100000

# Copiar código
COPY . .

# Build de la app
RUN yarn build && find ./dist -name "*.d.ts" -delete

# ===== Dashboard Stage =====
FROM node:22.16-bookworm-slim AS dashboard
RUN apt-get update && apt-get install -y jq wget unzip && rm -rf /var/lib/apt/lists/*

COPY waha.config.json /tmp/waha.config.json
RUN \
  WAHA_DASHBOARD_GITHUB_REPO=$(jq -r '.waha.dashboard.repo' /tmp/waha.config.json) && \
  WAHA_DASHBOARD_SHA=$(jq -r '.waha.dashboard.ref' /tmp/waha.config.json) && \
  wget https://github.com/${WAHA_DASHBOARD_GITHUB_REPO}/archive/${WAHA_DASHBOARD_SHA}.zip && \
  unzip ${WAHA_DASHBOARD_SHA}.zip -d /tmp/dashboard && \
  mkdir -p /dashboard && \
  mv /tmp/dashboard/dashboard-${WAHA_DASHBOARD_SHA}/* /dashboard/ && \
  rm -rf ${WAHA_DASHBOARD_SHA}.zip /tmp/dashboard/dashboard-${WAHA_DASHBOARD_SHA}

# ===== GOWS Stage =====
FROM golang:1.23-bookworm AS gows
RUN apt-get update && apt-get install -y jq protobuf-compiler libvips-dev && rm -rf /var/lib/apt/lists/*

COPY waha.config.json /tmp/waha.config.json
WORKDIR /go/gows
RUN \
  GOWS_GITHUB_REPO=$(jq -r '.waha.gows.repo' /tmp/waha.config.json) && \
  GOWS_SHA=$(jq -r '.waha.gows.ref' /tmp/waha.config.json) && \
  ARCH=$(uname -m) && \
  if [ "$ARCH" = "x86_64" ]; then ARCH="amd64"; elif [ "$ARCH" = "aarch64" ]; then ARCH="arm64"; else echo "Unsupported arch"; exit 1; fi && \
  mkdir -p /go/gows/bin && \
  wget -O /go/gows/bin/gows https://github.com/${GOWS_GITHUB_REPO}/releases/download/${GOWS_SHA}/gows-${ARCH} && chmod +x /go/gows/bin/gows

# ===== Release Stage =====
FROM node:22.16-bookworm-slim AS release
ENV PUPPETEER_SKIP_DOWNLOAD=True
ENV NODE_OPTIONS="--max-old-space-size=16384"

# Variables Waha
ENV WAHA_HTTP_NO_AUTH=true
ENV WAHA_LOG_LEVEL=info
ENV WAHA_ZIPPER=ZIPUNZIP
ENV CHOKIDAR_USEPOLLING=1
ENV CHOKIDAR_INTERVAL=5000
ENV WAHA_HTTP_PORT=${PORT}

WORKDIR /app

# Copiar build
COPY --from=build /git/dist ./dist
COPY --from=build /git/node_modules ./node_modules
COPY --from=dashboard /dashboard ./dist/dashboard
COPY --from=gows /go/gows/bin/gows /app/gows
COPY entrypoint.sh /entrypoint.sh
COPY scripts/init-waha.js ./scripts/init-waha.js
COPY .env.example ./.env.example

RUN chmod +x /entrypoint.sh ./scripts/init-waha.js \
  && printf '%s\n' '#!/bin/sh' 'exec node /app/scripts/init-waha.js "$@"' > /usr/local/bin/init-waha \
  && chmod +x /usr/local/bin/init-waha

EXPOSE 3000
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/entrypoint.sh"]
