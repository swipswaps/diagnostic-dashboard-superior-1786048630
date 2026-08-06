#!/usr/bin/env bash
set -o pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT" || exit 1

BACKEND_PORT=${BACKEND_PORT:-5001}
FRONTEND_PORT=${FRONTEND_PORT:-5173}
LOG_DIR="$PROJECT_ROOT/logs"
mkdir -p "$LOG_DIR"

echo "=== Starting Diagnostic Dashboard ==="

check_port() {
    if lsof -i :$1 >/dev/null 2>&1; then
        echo "⚠️  Port $1 is in use. Attempting to free..."
        lsof -ti :$1 | xargs kill -9 2>/dev/null || true
        sleep 1
    fi
}
check_port $BACKEND_PORT
check_port $FRONTEND_PORT

echo "Starting backend on port $BACKEND_PORT..."
export DB_PATH="$PROJECT_ROOT/data/diagnostics.db"
mkdir -p "$(dirname "$DB_PATH")"
python3 backend/app.py > "$LOG_DIR/backend.log" 2>&1 &
BACKEND_PID=$!
echo $BACKEND_PID > "$LOG_DIR/backend.pid"
echo "✅ Backend started (PID: $BACKEND_PID)"

echo "Starting frontend dev server on port $FRONTEND_PORT..."
cd frontend || exit 1
npm run dev -- --port $FRONTEND_PORT > "$LOG_DIR/frontend.log" 2>&1 &
FRONTEND_PID=$!
echo $FRONTEND_PID > "$LOG_DIR/frontend.pid"
echo "✅ Frontend started (PID: $FRONTEND_PID)"

echo
echo "=== Services running ==="
echo "Backend:  http://localhost:$BACKEND_PORT"
echo "Frontend: http://localhost:$FRONTEND_PORT"
echo "Logs:     $LOG_DIR/"
echo
echo "To stop: ./scripts/stop.sh"
