#!/usr/bin/env bash
# ============================================================================
# start_and_push.sh – Start Flask backend, push confirmation log, print raw link.
# ============================================================================

set -o pipefail

echo "=== START FLASK AND PUSH LOG ==="
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" || exit 1
echo "Working directory: $(pwd)"

# ----------------------------------------------------------------------
# Rule #8: Logging function
# ----------------------------------------------------------------------
log_result() {
    local operation="$1" success="$2" detail="$3"
    local ts status
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    if [ "$success" = "true" ]; then status="SUCCESS"; else status="FAILURE"; fi
    echo "[$ts] [$status] $operation: $detail" >&2
}

# ----------------------------------------------------------------------
# Rule #50: Environment variable export gate
# ----------------------------------------------------------------------
export DB_PATH="${DB_PATH:-./diagnostics.db}"
echo "DB_PATH=$DB_PATH"

# Ensure the directory for the database exists.
DB_DIR=$(dirname "$DB_PATH")
if [ ! -d "$DB_DIR" ] && [ "$DB_DIR" != "." ]; then
    echo "Creating directory: $DB_DIR"
    mkdir -p "$DB_DIR" || {
        log_result "mkdir" "false" "Failed to create $DB_DIR"
        exit 1
    }
fi

# Ensure the database file is writable (create if missing).
if [ ! -f "$DB_PATH" ]; then
    echo "Creating database at $DB_PATH..."
    python3 -c "
import sqlite3
conn = sqlite3.connect('$DB_PATH')
conn.execute('CREATE TABLE IF NOT EXISTS diagnostics (id INTEGER PRIMARY KEY AUTOINCREMENT, run_id TEXT, component TEXT, status TEXT, line_number INTEGER, line_text TEXT, logged_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)')
conn.execute('CREATE TABLE IF NOT EXISTS rule_compliance (id INTEGER PRIMARY KEY AUTOINCREMENT, script_name TEXT, rule_id TEXT, passed INTEGER, evidence TEXT, created_ts TIMESTAMP DEFAULT CURRENT_TIMESTAMP)')
conn.commit()
conn.close()
print('Database created.')
" || {
        log_result "db_init" "false" "Failed to create database."
        exit 1
    }
fi
log_result "db_init" "true" "Database ready at $DB_PATH"

# ----------------------------------------------------------------------
# Ensure templates/ exists (for Flask).
# ----------------------------------------------------------------------
if [ ! -d "templates" ]; then
    mkdir -p templates
    if [ -f docs/index.html ]; then
        cp docs/index.html templates/index.html
        log_result "templates" "true" "Copied index.html to templates/"
    else
        log_result "templates" "false" "docs/index.html not found – creating a simple index.html"
        cat > templates/index.html <<'HTMLEOF'
<!DOCTYPE html>
<html>
<head><title>Diagnostic Dashboard</title></head>
<body>
    <h1>Diagnostic Dashboard</h1>
    <div id="content"><p>Loading data...</p></div>
    <script>
        fetch('/api/diagnostics')
            .then(r => r.json())
            .then(data => {
                let html = '<table><tr><th>ID</th><th>Run</th><th>Component</th><th>Status</th><th>Line</th><th>Logged</th></tr>';
                data.forEach(row => {
                    html += `<tr><td>${row.id}</td><td>${row.run_id}</td><td>${row.component}</td><td>${row.status}</td><td>${row.line_number}</td><td>${row.logged_at}</td></tr>`;
                });
                html += '</table>';
                document.getElementById('content').innerHTML = html;
            })
            .catch(err => document.getElementById('content').innerHTML = '<p style="color:red;">Error: ' + err + '</p>');
    </script>
</body>
</html>
HTMLEOF
    fi
fi

# ----------------------------------------------------------------------
# Start Flask in the background.
# ----------------------------------------------------------------------
echo "Starting Flask server on port 5000..."
python3 app.py > flask.log 2>&1 &
FLASK_PID=$!
echo "Flask PID: $FLASK_PID"

# Wait a moment for the server to start.
sleep 3

# Check if it's running.
if ! kill -0 $FLASK_PID 2>/dev/null; then
    echo "❌ Flask failed to start. Check flask.log:"
    cat flask.log
    exit 1
fi
log_result "flask_start" "true" "Flask started (PID $FLASK_PID) on port 5000"

# ----------------------------------------------------------------------
# Push a confirmation log and print raw link.
# ----------------------------------------------------------------------
LOG_FILE="diagnostics/flask_start_$(date -u +%Y%m%d%H%M%S).txt"
{
    echo "Flask started at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "DB_PATH=$DB_PATH"
    echo "PID=$FLASK_PID"
    echo "URL: http://localhost:5000"
    echo
    echo "=== flask.log (first 50 lines) ==="
    head -50 flask.log
} > "$LOG_FILE"

git add "$LOG_FILE"
git commit -m "Add Flask startup log" || log_result "git_commit" "info" "No changes"
git push origin main || log_result "git_push" "warning" "Push failed (maybe no changes)."

RAW_LINK="https://raw.githubusercontent.com/swipswaps/diagnostic-dashboard-1786040134/main/$LOG_FILE"
echo
echo "=== RAW LOG LINK ==="
echo "$RAW_LINK"
log_result "raw_link" "true" "Log pushed: $RAW_LINK"

# ----------------------------------------------------------------------
# Open the browser.
# ----------------------------------------------------------------------
echo
echo "Flask is running at http://localhost:5000"
if command -v xdg-open >/dev/null 2>&1; then
    xdg-open http://localhost:5000
elif command -v open >/dev/null 2>&1; then
    open http://localhost:5000
fi

echo "To stop Flask: kill $FLASK_PID"
echo "=== START AND PUSH COMPLETE ==="
