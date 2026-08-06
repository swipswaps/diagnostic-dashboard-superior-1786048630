#!/usr/bin/env bash
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT" || exit 1
LOG_DIR="$PROJECT_ROOT/logs"

echo "=== Stopping Diagnostic Dashboard ==="

stop_service() {
    local name="$1"
    local pid_file="$LOG_DIR/$name.pid"
    if [ -f "$pid_file" ]; then
        PID=$(cat "$pid_file")
        if kill -0 "$PID" 2>/dev/null; then
            echo "Stopping $name (PID: $PID)..."
            kill "$PID" 2>/dev/null || true
            sleep 1
            kill -9 "$PID" 2>/dev/null || true
            rm -f "$pid_file"
            echo "✅ $name stopped"
        else
            echo "⚠️  $name not running (stale PID file)"
            rm -f "$pid_file"
        fi
    else
        echo "⚠️  No PID file for $name"
    fi
}

stop_service "backend"
stop_service "frontend"

for port in 5001 5173; do
    if lsof -i :$port >/dev/null 2>&1; then
        echo "Cleaning up stray process on port $port..."
        lsof -ti :$port | xargs kill -9 2>/dev/null || true
    fi
done

echo "=== All services stopped ==="
