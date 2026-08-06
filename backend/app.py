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
