# ===========================================
# WAHA (WhatsApp HTTP API) - Dockerfile para Render
# ===========================================
FROM node:22-bookworm-slim

# Evitar prompts interactivos
ENV DEBIAN_FRONTEND=noninteractive

# Crear directorio de la app
WORKDIR /app

# Instalar dependencias necesarias del sistema
RUN apt-get update && apt-get install -y \
  git \
  unzip \
  tini \
  && rm -rf /var/lib/apt/lists/*

# Copiar archivos base
COPY package.json yarn.lock ./

# Usar Yarn preinstalado (Render ya trae Yarn)
RUN yarn install --network-timeout 100000 || npm install

# Copiar el resto del código
COPY . .

# Asegurar permisos del entrypoint original
RUN chmod +x /entrypoint.sh || true

# ================================
# Configuración específica de Render
# ================================
ENV CHOKIDAR_USEPOLLING=1
ENV CHOKIDAR_INTERVAL=5000
ENV WAHA_ZIPPER=ZIPUNZIP
ENV WAHA_HTTP_NO_AUTH=true
ENV WAHA_LOG_LEVEL=info

# Render asigna el puerto dinámicamente
ENV WAHA_HTTP_PORT=${PORT}

# Crear un entrypoint especial para Render
RUN echo '#!/bin/sh' > /render-entrypoint.sh && \
    echo 'export WAHA_HTTP_NO_AUTH=true' >> /render-entrypoint.sh && \
    echo 'export WAHA_HTTP_PORT=${PORT}' >> /render-entrypoint.sh && \
    echo 'export WAHA_LOG_LEVEL=info' >> /render-entrypoint.sh && \
    echo 'echo "🚀 WAHA_HTTP_NO_AUTH=$WAHA_HTTP_NO_AUTH, WAHA_HTTP_PORT=$WAHA_HTTP_PORT"' >> /render-entrypoint.sh && \
    echo 'exec /entrypoint.sh "$@"' >> /render-entrypoint.sh && \
    chmod +x /render-entrypoint.sh

EXPOSE 3000

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/render-entrypoint.sh"]
