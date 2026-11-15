#!/bin/bash
# =============================================================================
# start-hf.sh — Entry point for the Hugging Face Spaces Docker container.
# Launches all three services and keeps the container alive.
# =============================================================================

set -e

# Graceful shutdown: kill all child processes when the container stops.
cleanup() {
    echo "[start-hf] Shutting down services..."
    kill "$OCR_PID" "$PIPELINE_PID" "$NEXT_PID" "$CADDY_PID" 2>/dev/null || true
    wait 2>/dev/null || true
    exit 0
}
trap cleanup SIGTERM SIGINT

cd /app

# ---- 0. Shared pipeline secret ---------------------------------------------
# Keep Next.js server-side calls and pipeline-service/internal auth aligned in
# this single-container deployment. The browser bundle uses the build-time value
# (NEXT_PUBLIC_PIPELINE_SECRET) for socket.io auth.
: "${PIPELINE_SECRET:=${NEXT_PUBLIC_PIPELINE_SECRET:-docker-container-secret}}"
export PIPELINE_SECRET
echo "$PIPELINE_SECRET" > /app/.pipeline-secret
chmod 600 /app/.pipeline-secret 2>/dev/null || true

# ---- 1. Database persistence self-check ------------------------------------
# A `file:` SQLite database is only durable when it sits on a MOUNTED volume.
# On a plain container (Render/Railway/HF without a disk) the filesystem is
# wiped on every restart, redeploy and free-tier spin-down — so job rows vanish
# and every job looks "gone" after a browser refresh. Say that once, loudly, at
# boot instead of letting it look like a frontend bug.
DB_FILE="${DATABASE_URL#file:}"
DB_DIR=""
if [ "$DB_FILE" != "${DATABASE_URL:-}" ] && [ -n "$DB_FILE" ]; then
    DB_DIR="$(dirname "$DB_FILE")"
    mkdir -p "$DB_DIR" 2>/dev/null || true
    if [ ! -d "$DB_DIR" ] || [ ! -w "$DB_DIR" ]; then
        echo "[start-hf] ERROR: database directory $DB_DIR is not writable — jobs cannot be saved."
    else
        _probe="$DB_DIR"
        _persistent="no"
        while [ -n "$_probe" ] && [ "$_probe" != "/" ]; do
            if mountpoint -q "$_probe" 2>/dev/null; then _persistent="yes ($_probe)"; break; fi
            _probe="$(dirname "$_probe")"
        done
        if [ "$_persistent" = "no" ]; then
            echo "[start-hf] ============================================================"
            echo "[start-hf] WARNING: $DB_FILE is NOT on a mounted volume."
            echo "[start-hf] Jobs, history and settings will be LOST on every restart,"
            echo "[start-hf] redeploy or free-tier spin-down — which looks like 'the job"
            echo "[start-hf] disappeared after I refreshed'."
            echo "[start-hf] Fix EITHER: mount a persistent disk at ${DB_FILE%%/db/*} and keep"
            echo "[start-hf]   DATABASE_URL=file:$DB_FILE, OR point DATABASE_URL at a hosted"
            echo "[start-hf]   libSQL/Turso database (libsql://... plus DATABASE_AUTH_TOKEN) —"
            echo "[start-hf]   this app supports both."
            echo "[start-hf] ============================================================"
        else
            echo "[start-hf] Database $DB_FILE is on mounted volume $_persistent ✓"
        fi
    fi
fi

# ---- 2. Initialize database (creates tables if they don't exist) -----------
echo "[start-hf] Initializing database..."
if ! bun run db:push 2>&1; then
    echo "[start-hf] db:push failed — retrying once in 3s..."
    sleep 3
    if ! bun run db:push 2>&1; then
        echo "[start-hf] ERROR: db:push failed twice. Without tables every API route"
        echo "[start-hf] returns errors and no job can be saved. Check DATABASE_URL above."
    fi
fi

# ---- 3. Start PaddleOCR service (port 3002, PP-OCRv4) --------------------
echo "[start-hf] Starting PaddleOCR service on port 3002..."
(cd mini-services/paddleocr-service && python3 main.py) &
OCR_PID=$!

# ---- 4. Start pipeline-service (port 3001, Python + socket.io) -------------
echo "[start-hf] Starting pipeline-service on port 3001..."
(cd mini-services/pipeline-service && bun run start) &
PIPELINE_PID=$!

# ---- 5. Start Next.js production server (port 3000) ------------------------
echo "[start-hf] Starting Next.js on port 3000..."
# Render sets PORT for the public web service; Next.js must stay on 3000 so
# Caddy can bind the public PORT and proxy to 3000/3001/3002.
PORT=3000 HOSTNAME=0.0.0.0 bun .next/standalone/server.js &
NEXT_PID=$!

# ---- 6. Wait for services to be ready --------------------------------------
echo "[start-hf] Waiting for services to initialize..."
sleep 5

# Quick health check
if curl -s -o /dev/null -w "" "http://localhost:3000/" 2>/dev/null; then
    echo "[start-hf] Next.js is responding on port 3000 ✓"
else
    echo "[start-hf] WARNING: Next.js not yet responding (may still be starting)"
fi

# ---- 7. Start Caddy reverse proxy (main process) ---------------------------
# Render/other platforms set PORT for the public listener; HF Spaces uses 7860.
# Next.js stays on internal port 3000 (ENV PORT=3000 in Dockerfile).
CADDY_PORT="${CADDY_PORT:-${PORT:-7860}}"
export CADDY_PORT
echo "[start-hf] Starting Caddy on port $CADDY_PORT (main process)..."
echo "[start-hf] App will be available at the service URL."
caddy run --config Caddyfile.docker --adapter caddyfile &
CADDY_PID=$!

# ---- 8. Keep the container alive -------------------------------------------
# If any service crashes, the container stops and the platform restarts it.
echo "[start-hf] All services started. Container is live."
echo "  - PaddleOCR:       PID $OCR_PID (port 3002)"
echo "  - Pipeline-service: PID $PIPELINE_PID (port 3001)"
echo "  - Next.js:        PID $NEXT_PID (port 3000)"
echo "  - Caddy:          PID $CADDY_PID (port $CADDY_PORT)"

wait
