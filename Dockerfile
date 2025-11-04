# ===============================
# WAHA - WhatsApp HTTP API
# Optimized Dockerfile for Render
# Auth disabled, Yarn 1.x compatible
# ===============================

ARG NODE_IMAGE_TAG=22.16-bookworm-slim
ARG GOLANG_IMAGE_TAG=1.23-bookworm

#
# Build
#
FROM node:${NODE_IMAGE_TAG} AS build
ENV PUPPETEER_SKIP_DOWNLOAD=True

# npm packages
WORKDIR /git
COPY package.json .
COPY yarn.lock .
ENV YARN_CHECKSUM_BEHAVIOR=update

# git
RUN apt-get update && apt-get install -y git

# Install Yarn classic and dependencies
RUN npm install -g yarn
RUN yarn install --network-timeout 100000

# App
WORKDIR /git
ADD . /git
RUN yarn install --network-timeout 100000
RUN yarn build && find ./dist -name "*.d.ts" -delete

#
# Dashboard
#
FROM node:${NODE_IMAGE_TAG} AS dashboard

RUN apt-get update && apt-get install -y jq wget unzip && rm -rf /var/lib/apt/lists/*

COPY waha.config.json /tmp/waha.config.json
RUN \
    WAHA_DASHBOARD_GITHUB_REPO=$(jq -r '.waha.dashboard.repo' /tmp/waha.config.json) && \
    WAHA_DASHBOARD_SHA=$(jq -r '.waha.dashboard.ref' /tmp/waha.config.json) && \
    wget https://github.com/${WAHA_DASHBOARD_GITHUB_REPO}/archive/${WAHA_DASHBOARD_SHA}.zip \
    && unzip ${WAHA_DASHBOARD_SHA}.zip -d /tmp/dashboard \
    && mkdir -p /dashboard \
    && mv /tmp/dashboard/dashboard-${WAHA_DASHBOARD_SHA}/* /dashboard/ \
    && rm -rf ${WAHA_DASHBOARD_SHA}.zip /tmp/dashboard/dashboard-${WAHA_DASHBOARD_SHA}

#
# GOWS
#
FROM golang:${GOLANG_IMAGE_TAG} AS gows
RUN apt-get update && apt-get install -y jq protobuf-compiler libvips-dev wget && rm -rf /var/lib/apt/lists/*
COPY waha.config.json /tmp/waha.config.json
WORKDIR /go/gows
RUN \
    GOWS_GITHUB_REPO=$(jq -r '.waha.gows.repo' /tmp/waha.config.json) && \
    GOWS_SHA=$(jq -r '.waha.gows.ref' /tmp/waha.config.json) && \
    ARCH=$(uname -m) && \
    if [ "$ARCH" = "x86_64" ]; then ARCH="amd64"; \
    elif [ "$ARCH" = "aarch64" ]; then ARCH="arm64"; \
    else echo "Unsupported architecture: $ARCH" && exit 1; fi && \
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

# Chrome/Chromium & Dependencies
RUN apt-get update && apt-get install -y \
    ffmpeg libvips tini zip unzip wget curl libc6 git jq fontconfig \
    fonts-noto-color-emoji fonts-liberation fonts-roboto fonts-noto-cjk \
    xvfb xauth libnss3 libxss1 libasound2 libatk-bridge2.0-0 libgtk-3-0 libdrm2 \
    ca-certificates --no-install-recommends && rm -rf /var/lib/apt/lists/*

# Set working dir
WORKDIR /app
COPY package.json ./
COPY --from=build /git/node_modules ./node_modules
COPY --from=build /git/dist ./dist
COPY --from=dashboard /dashboard ./dist/dashboard
COPY --from=gows /go/gows/bin/gows /app/gows
COPY .env.example ./.env.example
COPY scripts/init-waha.js ./scripts/init-waha.js
COPY entrypoint.sh /entrypoint.sh

RUN chmod +x ./scripts/init-waha.js /entrypoint.sh && \
    printf '%s\n' '#!/bin/sh' 'exec node /app/scripts/init-waha.js "$@"' > /usr/local/bin/init-waha && \
    chmod +x /usr/local/bin/init-waha

ENV WAHA_GOWS_PATH=/app/gows
ENV WAHA_GOWS_SOCKET=/tmp/gows.sock

# Chokidar options
ENV CHOKIDAR_USEPOLLING=1
ENV CHOKIDAR_INTERVAL=5000

# WAHA variables
ENV WAHA_ZIPPER=ZIPUNZIP

# For Render - disable auth and set dynamic port
ENV WAHA_HTTP_NO_AUTH=true
ENV WAHA_HTTP_PORT=${PORT}
ENV WAHA_LOG_LEVEL=info

# Replace entrypoint to ensure envs load before init
RUN echo '#!/bin/sh' > /render-entrypoint.sh && \
    echo 'export WAHA_HTTP_NO_AUTH=true' >> /render-entrypoint.sh && \
    echo 'export WAHA_HTTP_PORT=${PORT}' >> /render-entrypoint.sh && \
    echo 'export WAHA_LOG_LEVEL=info' >> /render-entrypoint.sh && \
    echo 'echo "WAHA_HTTP_NO_AUTH=$WAHA_HTTP_NO_AUTH, WAHA_HTTP_PORT=$WAHA_HTTP_PORT"' >> /render-entrypoint.sh && \
    echo 'exec /entrypoint.sh "$@"' >> /render-entrypoint.sh && \
    chmod +x /render-entrypoint.sh

EXPOSE 3000
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/render-entrypoint.sh"]
