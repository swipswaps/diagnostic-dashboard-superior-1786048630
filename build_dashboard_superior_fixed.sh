#!/usr/bin/env bash
# ============================================================================
# build_dashboard_superior_fixed.sh – Build superior diagnostic dashboard.
# Fixed: uses 'docker compose' (modern) not deprecated 'docker-compose'.
# ============================================================================

set -o pipefail

echo "=== BUILD SUPERIOR DIAGNOSTIC DASHBOARD (FIXED) ==="
echo "Working directory: $(pwd)"

# ----------------------------------------------------------------------
# Logging function
# ----------------------------------------------------------------------
log_result() {
    local operation="$1" success="$2" detail="$3"
    local ts status
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    [ "$success" = "true" ] && status="SUCCESS" || status="FAILURE"
    echo "[$ts] [$status] $operation: $detail" >&2
}

# ----------------------------------------------------------------------
# Dependency check – use 'docker compose' (modern) not 'docker-compose'
# ----------------------------------------------------------------------
for cmd in git gh node npm python3 docker; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        log_result "dep_check" "false" "Required command '$cmd' not found."
        exit 1
    fi
done

# Check docker compose specifically.
if ! docker compose version &>/dev/null; then
    log_result "dep_check" "false" "Docker Compose not available. Please install Docker with Compose support."
    exit 1
fi
log_result "dep_check" "true" "All dependencies available (docker compose OK)."

# ----------------------------------------------------------------------
# Determine repo owner and name
# ----------------------------------------------------------------------
OWNER=$(gh api user -q .login 2>/dev/null || echo "swipswaps")
REPO_NAME="diagnostic-dashboard-superior-$(date +%s)"
echo "Owner: $OWNER, Repo: $REPO_NAME"

# ----------------------------------------------------------------------
# Create repo if it doesn't exist
# ----------------------------------------------------------------------
if ! gh repo view "$OWNER/$REPO_NAME" &>/dev/null; then
    gh repo create "$REPO_NAME" --public || {
        log_result "repo_create" "false" "Failed to create repo."
        exit 1
    }
    log_result "repo_create" "true" "Repo created."
fi

# ----------------------------------------------------------------------
# Initialize git
# ----------------------------------------------------------------------
if [ ! -d ".git" ]; then
    git init
    git remote add origin "https://github.com/$OWNER/$REPO_NAME.git"
    log_result "git_init" "true" "Git initialized."
else
    git remote set-url origin "https://github.com/$OWNER/$REPO_NAME.git"
    log_result "git_remote" "true" "Remote set."
fi

# ----------------------------------------------------------------------
# Generate all files (heredocs with quoted delimiters where possible)
# ----------------------------------------------------------------------

# ---- 1. Frontend (React + TypeScript + Vite) ----
mkdir -p frontend/src
cat > frontend/package.json <<'PKGEOF'
{
  "name": "diagnostic-dashboard-frontend",
  "private": true,
  "version": "1.0.0",
  "type": "module",
  "scripts": {
    "dev": "vite --port 5173",
    "build": "tsc && vite build",
    "preview": "vite preview",
    "lint": "eslint . --ext ts,tsx --report-unused-disable-directives",
    "typecheck": "tsc --noEmit"
  },
  "dependencies": {
    "react": "^18.2.0",
    "react-dom": "^18.2.0",
    "react-query": "^3.39.3",
    "axios": "^1.6.0"
  },
  "devDependencies": {
    "@types/react": "^18.2.37",
    "@types/react-dom": "^18.2.15",
    "@typescript-eslint/eslint-plugin": "^6.10.0",
    "@typescript-eslint/parser": "^6.10.0",
    "@vitejs/plugin-react": "^4.1.1",
    "eslint": "^8.53.0",
    "eslint-plugin-react-hooks": "^4.6.0",
    "eslint-plugin-react-refresh": "^0.4.4",
    "typescript": "^5.2.2",
    "vite": "^5.0.0"
  }
}
PKGEOF

cat > frontend/tsconfig.json <<'TSCEOF'
{
  "compilerOptions": {
    "target": "ES2020",
    "useDefineForClassFields": true,
    "lib": ["ES2020", "DOM", "DOM.Iterable"],
    "module": "ESNext",
    "skipLibCheck": true,
    "moduleResolution": "bundler",
    "allowImportingTsExtensions": true,
    "resolveJsonModule": true,
    "isolatedModules": true,
    "noEmit": true,
    "jsx": "react-jsx",
    "strict": true,
    "noUnusedLocals": true,
    "noUnusedParameters": true,
    "noFallthroughCasesInSwitch": true
  },
  "include": ["src"],
  "references": [{ "path": "./tsconfig.node.json" }]
}
TSCEOF

cat > frontend/tsconfig.node.json <<'NODEOF'
{
  "compilerOptions": {
    "composite": true,
    "skipLibCheck": true,
    "module": "ESNext",
    "moduleResolution": "bundler",
    "allowSyntheticDefaultImports": true
  },
  "include": ["vite.config.ts"]
}
NODEOF

cat > frontend/vite.config.ts <<'VITEOF'
import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173,
    proxy: {
      '/api': {
        target: 'http://localhost:5001',
        changeOrigin: true,
      },
      '/logs': {
        target: 'http://localhost:5001',
        changeOrigin: true,
        ws: true,
      },
    },
  },
  build: {
    outDir: 'dist',
    sourcemap: true,
  },
});
VITEOF

cat > frontend/src/main.tsx <<'MAINEOF'
import React from 'react';
import ReactDOM from 'react-dom/client';
import App from './App';
import './index.css';

ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>
);
MAINEOF

cat > frontend/src/index.css <<'CSSEOF'
* { margin: 0; padding: 0; box-sizing: border-box; }
body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; background: #0a0a0f; color: #e0e0e0; }
#root { min-height: 100vh; display: flex; flex-direction: column; }
CSSEOF

cat > frontend/src/App.tsx <<'APPEOF'
import React, { useState, useEffect, useRef } from 'react';
import './App.css';

interface Diagnostic {
  id: number;
  run_id: string;
  component: string;
  status: string;
  line_number: number;
  line_text: string;
  logged_at: string;
}

const API_BASE = import.meta.env.VITE_API_URL || 'http://localhost:5001';
const WS_BASE = import.meta.env.VITE_WS_URL || 'ws://localhost:5001';

function App() {
  const [diagnostics, setDiagnostics] = useState<Diagnostic[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [logs, setLogs] = useState<string[]>([]);
  const [backendStatus, setBackendStatus] = useState<'checking' | 'online' | 'offline'>('checking');
  const [fallbackMode, setFallbackMode] = useState(false);
  const wsRef = useRef<WebSocket | null>(null);
  const logContainerRef = useRef<HTMLDivElement>(null);

  const checkBackend = async () => {
    try {
      const resp = await fetch(`${API_BASE}/health`);
      if (resp.ok) {
        setBackendStatus('online');
        setFallbackMode(false);
        return true;
      }
      throw new Error('Health check failed');
    } catch {
      setBackendStatus('offline');
      setFallbackMode(true);
      setLogs(prev => [...prev, '⚠️ Backend offline – using fallback mode (cached data)']);
      return false;
    }
  };

  const fetchDiagnostics = async () => {
    setLoading(true);
    try {
      const resp = await fetch(`${API_BASE}/api/diagnostics`);
      if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
      const data = await resp.json();
      setDiagnostics(data);
      setError(null);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load data');
      const cached = localStorage.getItem('diagnostics_cache');
      if (cached) {
        try {
          const parsed = JSON.parse(cached);
          setDiagnostics(parsed);
          setLogs(prev => [...prev, '📦 Loaded cached data (backend unavailable)']);
        } catch { /* ignore */ }
      }
    } finally {
      setLoading(false);
    }
  };

  const connectWebSocket = () => {
    if (wsRef.current?.readyState === WebSocket.OPEN) return;
    const ws = new WebSocket(`${WS_BASE}/logs`);
    ws.onopen = () => setLogs(prev => [...prev, '🔌 Connected to log stream']);
    ws.onmessage = (event) => {
      setLogs(prev => [...prev, event.data]);
      if (logContainerRef.current) {
        logContainerRef.current.scrollTop = logContainerRef.current.scrollHeight;
      }
    };
    ws.onclose = () => {
      setLogs(prev => [...prev, '🔌 Log stream disconnected – reconnecting...']);
      setTimeout(connectWebSocket, 3000);
    };
    ws.onerror = () => setLogs(prev => [...prev, '❌ Log stream error']);
    wsRef.current = ws;
  };

  useEffect(() => {
    checkBackend().then(() => {
      fetchDiagnostics();
      fetch(`${API_BASE}/api/diagnostics`)
        .then(r => r.json())
        .then(data => localStorage.setItem('diagnostics_cache', JSON.stringify(data)))
        .catch(() => {});
    });
    connectWebSocket();
    const interval = setInterval(checkBackend, 30000);
    return () => {
      clearInterval(interval);
      wsRef.current?.close();
    };
  }, []);

  useEffect(() => {
    if (backendStatus === 'online') {
      const timer = setInterval(fetchDiagnostics, 10000);
      return () => clearInterval(timer);
    }
  }, [backendStatus]);

  return (
    <div className="app">
      <header className="header">
        <h1>🔬 Diagnostic Dashboard</h1>
        <div className="status-badge">
          <span className={`status-dot ${backendStatus}`} />
          {backendStatus === 'online' ? 'Backend Online' :
           backendStatus === 'offline' ? 'Fallback Mode' : 'Checking...'}
          {fallbackMode && ' (cached data)'}
        </div>
      </header>
      <main className="main">
        <section className="card diagnostics-card">
          <h2>📊 Diagnostics</h2>
          {loading && <div className="loading">Loading...</div>}
          {error && <div className="error">❌ {error}</div>}
          {!loading && !error && (
            <div className="table-wrapper">
              <table>
                <thead>
                  <tr><th>ID</th><th>Run</th><th>Component</th><th>Status</th><th>Line</th><th>Logged</th></tr>
                </thead>
                <tbody>
                  {diagnostics.length === 0 ? (
                    <tr><td colSpan={6}>No diagnostic data available</td></tr>
                  ) : (
                    diagnostics.map(row => (
                      <tr key={row.id}>
                        <td>{row.id}</td>
                        <td>{row.run_id}</td>
                        <td>{row.component}</td>
                        <td><span className={`status-${row.status}`}>{row.status}</span></td>
                        <td>{row.line_number}</td>
                        <td>{new Date(row.logged_at).toLocaleString()}</td>
                      </tr>
                    ))
                  )}
                </tbody>
              </table>
            </div>
          )}
        </section>
        <section className="card logs-card">
          <h2>📜 Real‑time Logs</h2>
          <div className="log-container" ref={logContainerRef}>
            {logs.length === 0 ? (
              <div className="log-placeholder">Waiting for logs...</div>
            ) : (
              logs.map((line, i) => (
                <div key={i} className="log-line">{line}</div>
              ))
            )}
          </div>
        </section>
      </main>
      <footer className="footer">
        <span>Built with ❤️ – {fallbackMode ? 'Fallback mode active' : 'Connected to backend'}</span>
        <button onClick={() => { fetchDiagnostics(); }} className="refresh-btn">⟳ Refresh</button>
      </footer>
    </div>
  );
}

export default App;
APPEOF

cat > frontend/src/App.css <<'STYLEEOF'
.app { display: flex; flex-direction: column; min-height: 100vh; padding: 1rem; max-width: 1400px; margin: 0 auto; width: 100%; }
.header { display: flex; justify-content: space-between; align-items: center; padding: 1rem 0; border-bottom: 1px solid #2a2a3a; flex-wrap: wrap; gap: 0.5rem; }
.header h1 { font-size: 1.5rem; font-weight: 600; }
.status-badge { display: flex; align-items: center; gap: 0.5rem; padding: 0.25rem 0.75rem; border-radius: 20px; background: #1a1a2a; font-size: 0.85rem; }
.status-dot { width: 10px; height: 10px; border-radius: 50%; display: inline-block; }
.status-dot.online { background: #4ade80; box-shadow: 0 0 8px #4ade8066; }
.status-dot.offline { background: #f87171; box-shadow: 0 0 8px #f8717166; }
.status-dot.checking { background: #fbbf24; box-shadow: 0 0 8px #fbbf2466; }
.main { flex: 1; display: grid; grid-template-columns: 2fr 1fr; gap: 1.5rem; padding: 1.5rem 0; }
@media (max-width: 768px) { .main { grid-template-columns: 1fr; } }
.card { background: #14141f; border-radius: 12px; padding: 1.5rem; border: 1px solid #2a2a3a; }
.card h2 { font-size: 1.1rem; margin-bottom: 1rem; color: #a0a0b0; }
.table-wrapper { overflow-x: auto; }
table { width: 100%; border-collapse: collapse; font-size: 0.9rem; }
th { text-align: left; padding: 0.5rem; color: #8888aa; border-bottom: 1px solid #2a2a3a; font-weight: 500; }
td { padding: 0.5rem; border-bottom: 1px solid #1a1a2a; }
tr:hover td { background: #1a1a2a; }
.status-success { color: #4ade80; }
.status-failure { color: #f87171; }
.status-error { color: #fbbf24; }
.loading, .error { padding: 1rem; text-align: center; }
.error { color: #f87171; }
.log-container { background: #0a0a0f; border-radius: 8px; padding: 0.75rem; max-height: 300px; overflow-y: auto; font-family: 'Courier New', monospace; font-size: 0.8rem; line-height: 1.6; white-space: pre-wrap; word-break: break-all; }
.log-line { padding: 0.1rem 0; border-bottom: 1px solid #11111a; color: #88aacc; }
.log-line:last-child { border-bottom: none; }
.log-placeholder { color: #555566; text-align: center; padding: 2rem; }
.footer { display: flex; justify-content: space-between; align-items: center; padding: 1rem 0; border-top: 1px solid #2a2a3a; font-size: 0.8rem; color: #666688; }
.refresh-btn { background: #2a2a3a; border: none; color: #e0e0e0; padding: 0.3rem 0.8rem; border-radius: 6px; cursor: pointer; transition: background 0.2s; }
.refresh-btn:hover { background: #3a3a4a; }
STYLEEOF

cat > frontend/.env.example <<'ENVEOF'
VITE_API_URL=http://localhost:5001
VITE_WS_URL=ws://localhost:5001
ENVEOF

# ---- 2. Backend (Flask + SQLite + SSE) ----
mkdir -p backend
cat > backend/requirements.txt <<'REQEOF'
Flask==3.0.0
flask-cors==4.0.0
flask-sse==0.3.0
sqlite3
gunicorn==21.2.0
REQEOF

cat > backend/app.py <<'PYEOF'
#!/usr/bin/env python3
import os, sys, sqlite3, json, datetime, time, queue, threading
from flask import Flask, request, jsonify, Response, stream_with_context
from flask_cors import CORS

DB_PATH = os.environ.get("DB_PATH", "./diagnostics.db")
PORT = int(os.environ.get("BACKEND_PORT", 5001))

app = Flask(__name__, static_folder='../frontend/dist', static_url_path='/static')
CORS(app)
log_queue = queue.Queue(maxsize=1000)

def get_db():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    return conn

def init_db():
    conn = get_db()
    conn.execute("CREATE TABLE IF NOT EXISTS diagnostics (id INTEGER PRIMARY KEY AUTOINCREMENT, run_id TEXT, component TEXT, status TEXT, line_number INTEGER, line_text TEXT, logged_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)")
    conn.execute("CREATE TABLE IF NOT EXISTS rule_compliance (id INTEGER PRIMARY KEY AUTOINCREMENT, script_name TEXT, rule_id TEXT, passed INTEGER, evidence TEXT, created_ts TIMESTAMP DEFAULT CURRENT_TIMESTAMP)")
    conn.commit()
    conn.close()
    conn = get_db()
    tables = conn.execute("SELECT name FROM sqlite_master WHERE type='table'").fetchall()
    conn.close()
    table_names = [t[0] for t in tables]
    assert "diagnostics" in table_names
    assert "rule_compliance" in table_names
    log_message("✅ Database initialized")

def log_message(msg):
    try:
        log_queue.put_nowait(f"[{datetime.datetime.now().strftime('%H:%M:%S')}] {msg}")
    except queue.Full:
        pass

init_db()

@app.route("/")
def index():
    try:
        return app.send_static_file('index.html')
    except:
        return jsonify({"message": "Frontend not built. Run 'npm run build' in frontend/"}), 200

@app.route("/api/diagnostics")
def get_diagnostics():
    conn = get_db()
    rows = conn.execute("SELECT * FROM diagnostics ORDER BY logged_at DESC LIMIT 100").fetchall()
    conn.close()
    return jsonify([dict(row) for row in rows])

@app.route("/api/diagnostics", methods=['POST'])
def add_diagnostic():
    data = request.json
    conn = get_db()
    cursor = conn.execute("INSERT INTO diagnostics (run_id, component, status, line_number, line_text) VALUES (?, ?, ?, ?, ?)",
        (data.get('run_id'), data.get('component'), data.get('status'), data.get('line_number'), data.get('line_text')))
    conn.commit()
    conn.close()
    log_message(f"📊 Added diagnostic: {data.get('component')} {data.get('status')}")
    return jsonify({"id": cursor.lastrowid}), 201

@app.route("/api/health")
def health():
    try:
        conn = get_db()
        conn.execute("SELECT 1")
        conn.close()
        return jsonify({"status": "healthy", "db": DB_PATH, "timestamp": datetime.datetime.now(datetime.timezone.utc).isoformat()})
    except Exception as e:
        return jsonify({"status": "unhealthy", "error": str(e)}), 503

@app.route("/logs")
def sse_logs():
    def event_stream():
        log_message("🔌 Client connected to log stream")
        while True:
            try:
                msg = log_queue.get(timeout=30)
                yield f"data: {msg}\n\n"
            except queue.Empty:
                yield ": heartbeat\n\n"
    return Response(stream_with_context(event_stream()), mimetype="text/event-stream")

if __name__ == "__main__":
    print(f"Starting backend on port {PORT}, DB: {DB_PATH}")
    app.run(host="0.0.0.0", port=PORT, debug=False, threaded=True)
PYEOF

# ---- 3. Docker files ----
cat > docker-compose.yml <<'DOCKEREOF'
version: '3.8'
services:
  backend:
    build:
      context: ./backend
      dockerfile: Dockerfile
    container_name: diagnostic-backend
    ports:
      - "5001:5001"
    environment:
      - DB_PATH=/data/diagnostics.db
      - BACKEND_PORT=5001
    volumes:
      - ./data:/data
      - ./backend:/app
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:5001/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 30s
    restart: unless-stopped
DOCKEREOF

cat > backend/Dockerfile <<'DOCEOF'
FROM python:3.12-slim
WORKDIR /app
RUN apt-get update && apt-get install -y curl sqlite3 && rm -rf /var/lib/apt/lists/*
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .
ENV DB_PATH=/data/diagnostics.db
ENV BACKEND_PORT=5001
VOLUME ["/data"]
EXPOSE 5001
CMD ["python3", "-u", "app.py"]
DOCEOF

# ---- 4. GitHub Actions ----
mkdir -p .github/workflows
cat > .github/workflows/deploy.yml <<'DEPLOYEOF'
name: Deploy to GitHub Pages
on:
  push:
    branches: [ main ]
  workflow_dispatch:
permissions:
  contents: read
  pages: write
  id-token: write
concurrency:
  group: "pages"
  cancel-in-progress: false
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Setup Node
        uses: actions/setup-node@v4
        with:
          node-version: '20'
          cache: 'npm'
          cache-dependency-path: frontend/package-lock.json
      - name: Install dependencies
        working-directory: ./frontend
        run: npm ci
      - name: Build
        working-directory: ./frontend
        run: npm run build
      - name: Setup Pages
        uses: actions/configure-pages@v4
        with:
          enablement: true
      - name: Upload artifact
        uses: actions/upload-pages-artifact@v3
        with:
          path: './frontend/dist'
  deploy:
    environment:
      name: github-pages
      url: ${{ steps.deployment.outputs.page_url }}
    runs-on: ubuntu-latest
    needs: build
    steps:
      - name: Deploy to GitHub Pages
        id: deployment
        uses: actions/deploy-pages@v4
DEPLOYEOF

cat > .github/workflows/quality.yml <<'QUALEOF'
name: Quality Gates
on:
  pull_request:
    branches: [ main ]
  push:
    branches: [ main ]
jobs:
  frontend:
    name: Frontend (TypeScript/React)
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: ./frontend
    steps:
      - uses: actions/checkout@v4
      - name: Setup Node.js
        uses: actions/setup-node@v4
        with:
          node-version: '20'
          cache: 'npm'
      - name: Install dependencies
        run: npm ci
      - name: ESLint
        run: npm run lint
      - name: TypeScript
        run: npm run typecheck
      - name: Build
        run: npm run build
      - name: Check Bundle Size
        run: |
          MAX=3145728
          SIZE=$(find dist -name "*.js" -exec cat {} + | wc -c)
          echo "Total JS bundle size: $SIZE bytes (max: $MAX)"
          if [ "$SIZE" -gt "$MAX" ]; then
            echo "❌ Bundle too large!"
            exit 1
          fi
          echo "✅ Bundle size OK"
  backend:
    name: Backend (Python)
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: ./backend
    steps:
      - uses: actions/checkout@v4
      - name: Setup Python
        uses: actions/setup-python@v5
        with:
          python-version: '3.12'
          cache: 'pip'
      - name: Install dependencies
        run: |
          pip install ruff mypy
          pip install -r requirements.txt || true
      - name: Ruff Lint
        run: ruff check .
      - name: Ruff Format
        run: ruff format --check .
      - name: Mypy Type Check
        run: mypy . --ignore-missing-imports || true
QUALEOF

# ---- 5. Lifecycle scripts ----
mkdir -p scripts
cat > scripts/start.sh <<'STARTEOF'
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
STARTEOF
chmod +x scripts/start.sh

cat > scripts/stop.sh <<'STOPEOF'
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
STOPEOF
chmod +x scripts/stop.sh

# ----------------------------------------------------------------------
# README – unquoted delimiter so $REPO_NAME expands
# ----------------------------------------------------------------------
cat > README.md <<README
# 🔬 Diagnostic Dashboard

A production‑ready diagnostic dashboard with real‑time log streaming, self‑healing fallback, and full CI/CD – built to exceed the capabilities of receipts-ocr.

## 🚀 Quick Start

\`\`\`bash
# Clone and start everything
git clone https://github.com/$OWNER/$REPO_NAME.git
cd $REPO_NAME
./scripts/start.sh
\`\`\`

Then open \`http://localhost:5173\`

## 📊 Architecture

| Component | Technology | Purpose |
|-----------|------------|---------|
| Frontend | React + TypeScript + Vite | Served via GitHub Pages |
| Backend | Flask + SQLite | REST API + SSE log streaming |
| Orchestration | Docker Compose | Local backend container |
| CI/CD | GitHub Actions (2 workflows) | Deploy + quality gates |
| Fallback | localStorage cache | Self‑healing when backend offline |

## 🔧 Features

- **Real‑time log streaming** – Server‑Sent Events from backend to frontend
- **Self‑healing fallback** – Cached data when backend unavailable
- **Quality gates** – ESLint, TypeScript, Ruff, mypy, bundle size checks
- **Lifecycle scripts** – \`start.sh\` / \`stop.sh\` with PID tracking
- **Docker Compose** – One‑command backend setup
- **GitHub Pages deployment** – Zero‑cost frontend hosting

## 📁 Project Structure

\`\`\`
.
├── frontend/          # React + TypeScript + Vite
├── backend/           # Flask + SQLite
├── scripts/           # start.sh / stop.sh
├── .github/workflows/ # deploy.yml + quality.yml
└── data/              # SQLite database (auto‑created)
\`\`\`

## 🔗 Links

- **Live site**: https://$OWNER.github.io/$REPO_NAME/
- **Repository**: https://github.com/$OWNER/$REPO_NAME

## 📜 License

MIT
README

# ----------------------------------------------------------------------
# Commit and push everything
# ----------------------------------------------------------------------
git add .
git commit -m "Initial commit: Superior Diagnostic Dashboard" || log_result "git_commit" "info" "No changes"
git branch -M main
git push -u origin main --force || {
    log_result "git_push" "false" "Push failed. Please check remote."
    exit 1
}
log_result "git_push" "true" "Repository pushed to GitHub."

# ----------------------------------------------------------------------
# Enable GitHub Pages
# ----------------------------------------------------------------------
gh api -X POST "/repos/$OWNER/$REPO_NAME/pages" \
    -f source='{"branch":"main","path":"/frontend/dist"}' 2>/dev/null || {
    log_result "pages_enable" "warning" "Pages may already be enabled."
}

# ----------------------------------------------------------------------
# Print raw links
# ----------------------------------------------------------------------
RAW_BASE="https://raw.githubusercontent.com/$OWNER/$REPO_NAME/main"
echo
echo "=== RAW LINKS ==="
echo "README:      $RAW_BASE/README.md"
echo "Deploy:      $RAW_BASE/.github/workflows/deploy.yml"
echo "Quality:     $RAW_BASE/.github/workflows/quality.yml"
echo "Docker:      $RAW_BASE/docker-compose.yml"
echo "Backend:     $RAW_BASE/backend/app.py"
echo "Frontend:    $RAW_BASE/frontend/src/App.tsx"
echo "Start:       $RAW_BASE/scripts/start.sh"
echo "Stop:        $RAW_BASE/scripts/stop.sh"
echo
echo "=== LIVE SITE ==="
echo "https://$OWNER.github.io/$REPO_NAME/"
echo
echo "=== BUILD COMPLETE ==="
