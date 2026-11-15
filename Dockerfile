# =============================================================================
# Manhwa Recap Studio — Docker image for Hugging Face Spaces
# Runs the entire app (Next.js + Python pipeline + socket.io + Caddy) in one
# container. Free 16 GB RAM, 50 GB storage, 24/7 online.
# =============================================================================

FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# ---- System dependencies ----------------------------------------------------
# Caddy is not in the default Ubuntu 22.04 repos; add the official Caddy apt repo.
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl ca-certificates gnupg debian-keyring debian-archive-keyring apt-transport-https \
    && curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg \
    && curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list \
    && chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg \
    && chmod o+r /etc/apt/sources.list.d/caddy-stable.list \
    && apt-get update && apt-get install -y --no-install-recommends \
    python3 python3-pip python3-venv \
    ffmpeg \
    caddy \
    git \
    unzip \
    libgl1 libglib2.0-0 \
    && rm -rf /var/lib/apt/lists/*

# ---- Bun (JavaScript runtime) ----------------------------------------------
RUN curl -fsSL https://bun.sh/install | bash
ENV BUN_INSTALL="/root/.bun"
ENV PATH="${BUN_INSTALL}/bin:${PATH}"

# ---- Python dependencies (Python 3.10.4 target; local-first production TTS) ------
RUN python3 -m venv /opt/venv
ENV PATH="/opt/venv/bin:${PATH}"
WORKDIR /app

# Copy package files first (better Docker layer caching)
COPY package.json bun.lock ./
COPY prisma ./prisma
COPY mini-services/pipeline-service/package.json mini-services/pipeline-service/bun.lock ./mini-services/pipeline-service/
COPY mini-services/pipeline-service/prisma ./mini-services/pipeline-service/prisma
COPY mini-services/paddleocr-service/requirements.txt ./mini-services/paddleocr-service/
COPY pipeline/requirements.txt ./pipeline/requirements.txt

RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir -r pipeline/requirements.txt && \
    pip install --no-cache-dir -r mini-services/paddleocr-service/requirements.txt && \
    pip install --no-cache-dir --no-deps rapidocr==3.9.2

RUN bun install
RUN cd mini-services/pipeline-service && bun install

# Copy source code
COPY . .

# Build Next.js for production (standalone output)
RUN bun run build

# ---- Runtime config ---------------------------------------------------------
# Persistent storage on HF Spaces: /data survives container restarts
ENV DATA_DIR=/data/manhwa-data
ENV DATABASE_URL=file:/data/db/custom.db
ENV PROJECT_ROOT=/app
ENV PYTHON_BIN=/opt/venv/bin/python3
ENV NODE_ENV=production
ENV HOSTNAME=0.0.0.0
ENV PORT=3000
# Shared secret for the all-in-one container (Next.js <-> pipeline-service/socket.io).
# Baked into the client bundle at build time; can be overridden at runtime via env.
ENV PIPELINE_SECRET=docker-container-secret
ENV NEXT_PUBLIC_PIPELINE_SECRET=docker-container-secret

RUN mkdir -p /data/db /data/manhwa-data /data/cache

# HF Spaces expects the app on port 7860 (Caddy listens here, proxies to 3000/3001)
EXPOSE 7860

# Start script launches: pipeline-service (3001) + Next.js (3000) + Caddy (7860)
CMD ["bash", "start-hf.sh"]
