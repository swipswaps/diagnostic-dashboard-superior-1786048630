#!/usr/bin/env bash
# ============================================================================
# fix_templates_and_restart.sh – Fix "TemplateNotFound" and restart Flask.
# ============================================================================

set -o pipefail

echo "=== FIX TEMPLATES AND RESTART ==="
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
# 1. Stop any existing Flask process on port 5000
# ----------------------------------------------------------------------
echo "Stopping any Flask process on port 5000..."
PID=$(lsof -t -i :5000 2>/dev/null)
if [ -n "$PID" ]; then
    echo "Killing PID $PID..."
    kill -9 "$PID" 2>/dev/null && log_result "stop_flask" "true" "Killed PID $PID"
else
    log_result "stop_flask" "info" "No Flask process found on port 5000."
fi

# ----------------------------------------------------------------------
# 2. Ensure templates/ directory exists and copy index.html
# ----------------------------------------------------------------------
mkdir -p templates
if [ -f docs/index.html ]; then
    cp docs/index.html templates/index.html
    log_result "copy_index" "true" "Copied docs/index.html to templates/index.html"
else
    log_result "copy_index" "false" "docs/index.html not found."
    exit 1
fi

# ----------------------------------------------------------------------
# 3. Ensure static/ directory exists and copy static files
# ----------------------------------------------------------------------
if [ -d docs/static ]; then
    mkdir -p static
    cp -r docs/static/* static/ 2>/dev/null
    log_result "copy_static" "true" "Copied docs/static/ to static/"
else
    log_result "copy_static" "warning" "docs/static not found – using existing static/ if present."
fi

# ----------------------------------------------------------------------
# 4. Ensure the database exists
# ----------------------------------------------------------------------
export DB_PATH="${DB_PATH:-./diagnostics.db}"
if [ ! -f "$DB_PATH" ]; then
    echo "Creating database at $DB_PATH..."
    python3 -c "import sqlite3; conn = sqlite3.connect('$DB_PATH'); conn.execute('CREATE TABLE IF NOT EXISTS diagnostics (id INTEGER PRIMARY KEY AUTOINCREMENT, run_id TEXT, component TEXT, status TEXT, line_number INTEGER, line_text TEXT, logged_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)'); conn.execute('CREATE TABLE IF NOT EXISTS rule_compliance (id INTEGER PRIMARY KEY AUTOINCREMENT, script_name TEXT, rule_id TEXT, passed INTEGER, evidence TEXT, created_ts TIMESTAMP DEFAULT CURRENT_TIMESTAMP)'); conn.commit(); conn.close()" || {
        log_result "db_init" "false" "Failed to create database."
        exit 1
    }
    log_result "db_init" "true" "Database created."
fi

# ----------------------------------------------------------------------
# 5. Commit and push changes (templates/ and static/)
# ----------------------------------------------------------------------
git add templates/ static/
git commit -m "Add templates and static folders for Flask" || log_result "git_commit" "info" "No changes to commit."
git push origin main || log_result "git_push" "warning" "Push failed (maybe no changes)."

# ----------------------------------------------------------------------
# 6. Restart Flask server
# ----------------------------------------------------------------------
echo
echo "=== RESTARTING FLASK BACKEND ==="
echo "Flask will now serve from templates/ and static/."
echo "Visit http://localhost:5000 to see the dashboard."
echo "Press Ctrl+C to stop."

exec python3 app.py
