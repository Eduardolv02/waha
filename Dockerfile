ARG NODE_IMAGE_TAG=22.16-bookworm-slim
ARG GOLANG_IMAGE_TAG=1.23-bookworm

#
# === BUILD STAGE ===
#
FROM node:${NODE_IMAGE_TAG} AS build
ENV PUPPETEER_SKIP_DOWNLOAD=True
WORKDIR /app

# 1️⃣ Copiar dependencias
COPY package.json yarn.lock ./

# 2️⃣ Instalar herramientas necesarias
RUN apt-get update && apt-get install -y git && rm -rf /var/lib/apt/lists/*
RUN npm install -g corepack && corepack enable && yarn set version 3.6.3
RUN rm -f .yarnrc.yml

# 3️⃣ Instalar dependencias (seguro y compatible con Render)
RUN yarn install --network-timeout 100000 || npm install

# 4️⃣ Copiar el resto del proyecto
COPY . .

# 5️⃣ Compilar la app
RUN yarn build || (npm run build || echo "build skipped")
RUN find ./dist -name "*.d.ts" -delete || true

#
# === DASHBOARD STAGE ===
#
FROM node:${NODE_IMAGE_TAG} AS dashboard
RUN apt-get update && apt-get install -y jq wget unzip && rm -rf /var/lib/apt/lists/*
COPY waha.config.json /tmp/waha.config.json

RUN WAHA_DASHBOARD_GITHUB_REPO=$(jq -r '.waha.dashboard.repo' /tmp/waha.config.json) && \
    WAHA_DASHBOARD_SHA=$(jq -r '.waha.dashboard.ref' /tmp/waha.config.json) && \
    wget https://github.com/${WAHA_DASHBOARD_GITHUB_REPO}/archive/${WAHA_DASHBOARD_SHA}.zip && \
    unzip ${WAHA_DASHBOARD_SHA}.zip -d /tmp/dashboard && \
    mkdir -p /dashboard && \
    mv /tmp/dashboard/dashboard-${WAHA_DASHBOARD_SHA}/* /dashboard/ && \
    rm -rf ${WAHA_DASHBOARD_SHA}.zip /tmp/dashboard

#
# === GOWS STAGE ===
#
FROM golang:${GOLANG_IMAGE_TAG} AS gows
RUN apt-get update && apt-get install -y jq protobuf-compiler libvips-dev && rm -rf /var/lib/apt/lists/*
COPY waha.config.json /tmp/waha.config.json
WORKDIR /go/gows

RUN GOWS_GITHUB_REPO=$(jq -r '.waha.gows.repo' /tmp/waha.config.json) && \
    GOWS_SHA=$(jq -r '.waha.gows.ref' /tmp/waha.config.json) && \
    ARCH=$(uname -m) && \
    if [ "$ARCH" = "x86_64" ]; then ARCH="amd64"; elif [ "$ARCH" = "aarch64" ]; then ARCH="arm64"; else echo "Unsupported architecture: $ARCH" && exit 1; fi && \
    mkdir -p /go/gows/bin && \
    wget -O /go/gows/bin/gows https://github.com/${GOWS_GITHUB_REPO}/releases/download/${GOWS_SHA}/gows-${ARCH} && \
    chmod +x /go/gows/bin/gows

#
# === FINAL STAGE ===
#
FROM node:${NODE_IMAGE_TAG} AS release
ENV PUPPETEER_SKIP_DOWNLOAD=True
ENV NODE_OPTIONS="--max-old-space-size=16384"
ARG USE_BROWSER=chromium
ARG WHATSAPP_DEFAULT_ENGINE
RUN echo "USE_BROWSER=$USE_BROWSER"

RUN apt-get update && apt-get install -y ffmpeg libvips zip unzip wget curl libc6 tini && rm -rf /var/lib/apt/lists/*

RUN if [ "$USE_BROWSER" = "chromium" ] || [ "$USE_BROWSER" = "chrome" ]; then \
    apt-get update && apt-get install -y \
        fontconfig fonts-noto-color-emoji fonts-liberation xvfb xauth libnss3 libxss1 \
        libasound2 libatk-bridge2.0-0 libgtk-3-0 libdrm2 ca-certificates && rm -rf /var/lib/apt/lists/*; \
    fi

RUN if [ "$USE_BROWSER" = "chromium" ]; then \
    apt-get update && apt-get install -y chromium && rm -rf /var/lib/apt/lists/*; \
    fi

WORKDIR /app

COPY --from=build /app/dist ./dist
COPY --from=build /app/node_modules ./node_modules
COPY --from=dashboard /dashboard ./dist/dashboard
COPY --from=gows /go/gows/bin/gows /app/gows
COPY package.json ./
COPY .env.example ./.env.example
COPY scripts/init-waha.js ./scripts/init-waha.js
COPY entrypoint.sh /entrypoint.sh

RUN chmod +x ./scripts/init-waha.js && \
    printf '%s\n' '#!/bin/sh' 'exec node /app/scripts/init-waha.js "$@"' > /usr/local/bin/init-waha && \
    chmod +x /usr/local/bin/init-waha

EXPOSE 3000
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/entrypoint.sh"]
