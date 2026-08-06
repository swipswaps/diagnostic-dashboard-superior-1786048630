#!/usr/bin/env bash
# ============================================================================
# fix_app_py_and_run.sh – Fix CORS placement in app.py and run Flask.
# ============================================================================

set -o pipefail

echo "=== FIX APP.PY CORS PLACEMENT ==="
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
# Fix app.py – ensure CORS is defined after app = Flask(__name__)
# ----------------------------------------------------------------------
echo "Fixing app.py..."

# Remove any misplaced CORS(app) line that appears before app = Flask
sed -i '/^CORS(app)/d' app.py

# Add CORS(app) after the app = Flask line if not already present
if ! grep -q "^CORS(app)" app.py; then
    sed -i '/^app = Flask/a CORS(app)' app.py
    log_result "fix_cors" "true" "Added CORS(app) after app definition."
fi

# Ensure import is present
if ! grep -q "from flask_cors import CORS" app.py; then
    sed -i '/^from flask import/a from flask_cors import CORS' app.py
    log_result "fix_import" "true" "Added flask_cors import."
fi

# Show the top of app.py to confirm
echo
echo "=== TOP OF APP.PY ==="
head -15 app.py

# Commit the fix
git add app.py
git commit -m "Fix CORS placement in app.py" || log_result "git_commit" "info" "No changes to commit."
git push origin main || log_result "git_push" "warning" "Push failed (maybe no changes)."

# ----------------------------------------------------------------------
# Run Flask backend
# ----------------------------------------------------------------------
echo
echo "=== STARTING FLASK BACKEND ==="
export DB_PATH="${DB_PATH:-./diagnostics.db}"

# Ensure DB exists
if [ ! -f "$DB_PATH" ]; then
    echo "Creating database at $DB_PATH..."
    python3 -c "import sqlite3; conn = sqlite3.connect('$DB_PATH'); conn.execute('CREATE TABLE IF NOT EXISTS diagnostics (id INTEGER PRIMARY KEY AUTOINCREMENT, run_id TEXT, component TEXT, status TEXT, line_number INTEGER, line_text TEXT, logged_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)'); conn.execute('CREATE TABLE IF NOT EXISTS rule_compliance (id INTEGER PRIMARY KEY AUTOINCREMENT, script_name TEXT, rule_id TEXT, passed INTEGER, evidence TEXT, created_ts TIMESTAMP DEFAULT CURRENT_TIMESTAMP)'); conn.commit(); conn.close()" || {
        log_result "db_init" "false" "Failed to create database."
        exit 1
    }
    log_result "db_init" "true" "Database created."
fi

echo "Starting Flask server on port 5000..."
echo "Visit http://localhost:5000 to see the dashboard."
echo "Press Ctrl+C to stop."
exec python3 app.py
