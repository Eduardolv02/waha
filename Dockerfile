ARG NODE_IMAGE_TAG=22.16-bookworm-slim
ARG GOLANG_IMAGE_TAG=1.23-bookworm

#
# Build
#
FROM node:${NODE_IMAGE_TAG} AS build
ENV PUPPETEER_SKIP_DOWNLOAD=True

WORKDIR /git

# Copiar solo lo necesario para instalar deps
COPY package.json yarn.lock ./

# Instalar git y Corepack
RUN apt-get update && apt-get install -y git && rm -rf /var/lib/apt/lists/*
RUN npm install -g corepack && corepack enable
RUN yarn set version 3.6.3

# Ignorar yarn-path local que pueda romper el build
RUN rm -f .yarnrc.yml

# Instalar dependencias
RUN yarn install --immutable --network-timeout 100000

# Copiar el resto del código
COPY . .

# Build de la app
RUN yarn build && find ./dist -name "*.d.ts" -delete

#
# Dashboard
#
FROM node:${NODE_IMAGE_TAG} AS dashboard

# Herramientas necesarias
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
# GOWS
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
# Final
#
FROM node:${NODE_IMAGE_TAG} AS release
ENV PUPPETEER_SKIP_DOWNLOAD=True
ENV NODE_OPTIONS="--max-old-space-size=16384"
ARG USE_BROWSER=chromium
ARG WHATSAPP_DEFAULT_ENGINE

RUN echo "USE_BROWSER=$USE_BROWSER"

# Dependencias básicas
RUN apt-get update && apt-get install -y ffmpeg libvips zip unzip wget curl libc6 tini && rm -rf /var/lib/apt/lists/*

# Dependencias para navegadores
RUN if [ "$USE_BROWSER" = "chromium" ] || [ "$USE_BROWSER" = "chrome" ]; then \
    apt-get update && apt-get install -y \
        fontconfig fonts-freefont-ttf fonts-gfs-neohellenic fonts-indic fonts-ipafont-gothic \
        fonts-kacst fonts-liberation fonts-noto-cjk fonts-noto-color-emoji fonts-roboto \
        fonts-thai-tlwg fonts-wqy-zenhei fonts-open-sans xvfb xauth libnss3 libxss1 \
        libasound2 libatk-bridge2.0-0 libgtk-3-0 libdrm2 ca-certificates && rm -rf /var/lib/apt/lists/*; \
    fi

# Chromium
RUN if [ "$USE_BROWSER" = "chromium" ]; then \
    apt-get update && apt-get install -y chromium && rm -rf /var/lib/apt/lists/*; \
    fi

# Chrome
ARG CHROME_VERSION="140.0.7339.80-1"
RUN if [ "$USE_BROWSER" = "chrome" ]; then \
    wget --no-verbose -O /tmp/chrome.deb https://dl.google.com/linux/chrome/deb/pool/main/g/google-chrome-stable/google-chrome-stable_${CHROME_VERSION}_amd64.deb && \
    apt install -y /tmp/chrome.deb && rm /tmp/chrome.deb; \
    fi

# Variables WAHA
ENV WHATSAPP_DEFAULT_ENGINE=$WHATSAPP_DEFAULT_ENGINE
ENV WAHA_GOWS_PATH=/app/gows
ENV WAHA_GOWS_SOCKET=/tmp/gows.sock
ENV WAHA_ZIPPER=ZIPUNZIP
ENV CHOKIDAR_USEPOLLING=1
ENV CHOKIDAR_INTERVAL=5000

WORKDIR /app
COPY package.json ./ 
COPY --from=build /git/node_modules ./node_modules
COPY --from=build /git/dist ./dist
COPY --from=dashboard /dashboard ./dist/dashboard
COPY --from=gows /go/gows/bin/gows /app/gows
COPY .env.example ./.env.example
COPY scripts/init-waha.js ./scripts/init-waha.js

RUN chmod +x ./scripts/init-waha.js && \
    printf '%s\n' '#!/bin/sh' 'exec node /app/scripts/init-waha.js "$@"' > /usr/local/bin/init-waha && \
    chmod +x /usr/local/bin/init-waha

COPY entrypoint.sh /entrypoint.sh

EXPOSE 3000
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/entrypoint.sh"]

