#!/usr/bin/env bash
# ============================================================================
# fix_dependencies_and_run.sh – Install dependencies, fix CORS, run Flask.
# Complies with userPreferences rules #1, #8, #28, #30, #38, #50, #52.
# ============================================================================

set -o pipefail

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

echo "=== FIX DEPENDENCIES AND RUN FLASK ==="
echo "Working directory: $(pwd)"

# ----------------------------------------------------------------------
# Rule #28: Dependency Management – check Python and pip
# ----------------------------------------------------------------------
log_result "dep_check" "info" "Checking Python and pip..."

if ! command -v python3 >/dev/null 2>&1; then
    log_result "dep_check" "false" "Python3 not found. Please install Python 3."
    exit 1
fi
PYTHON_VERSION=$(python3 --version 2>&1 | cut -d' ' -f2)
log_result "python_version" "true" "Python version: $PYTHON_VERSION"

if ! command -v pip3 >/dev/null 2>&1 && ! command -v pip >/dev/null 2>&1; then
    log_result "dep_check" "false" "pip not found. Please install pip."
    echo "On Fedora: sudo dnf install python3-pip"
    exit 1
fi
PIP_CMD=$(command -v pip3 2>/dev/null || command -v pip 2>/dev/null)
log_result "pip_found" "true" "Using pip: $PIP_CMD"

# ----------------------------------------------------------------------
# Rule #28: Install flask-cors (with error handling)
# ----------------------------------------------------------------------
log_result "install_cors" "info" "Installing flask-cors..."

# Try with --user (if not in virtualenv)
if ! $PIP_CMD show flask-cors >/dev/null 2>&1; then
    echo "Installing flask-cors (--user)..."
    $PIP_CMD install --user flask-cors 2>&1 || {
        echo "Installing with --user failed. Trying without --user (may require sudo)..."
        sudo $PIP_CMD install flask-cors 2>&1 || {
            log_result "install_cors" "false" "Failed to install flask-cors. Please install manually: $PIP_CMD install flask-cors"
            exit 1
        }
    }
else
    log_result "install_cors" "info" "flask-cors already installed."
fi

# Verify import works
echo "Verifying flask-cors import..."
python3 -c "import flask_cors" 2>/dev/null || {
    log_result "install_cors" "false" "flask-cors installed but import failed. Try reinstall: $PIP_CMD install --force-reinstall flask-cors"
    exit 1
}
log_result "install_cors" "true" "flask-cors installed and importable."

# ----------------------------------------------------------------------
# Rule #1: Update app.py with CORS support
# ----------------------------------------------------------------------
echo "Updating app.py with CORS support..."

if ! grep -q "flask_cors" app.py; then
    # Insert CORS lines after Flask import
    sed -i '/from flask import/a from flask_cors import CORS\nCORS(app)' app.py
    log_result "update_app" "true" "Added CORS support to app.py."
else
    log_result "update_app" "info" "CORS already in app.py."
fi

# ----------------------------------------------------------------------
# Rule #1: Ensure docs/index.html points to localhost:5000
# ----------------------------------------------------------------------
if ! grep -q "localhost:5000" docs/index.html; then
    echo "Updating docs/index.html to point to localhost:5000..."
    sed -i "s|const API_BASE = .*|const API_BASE = 'http://localhost:5000';|" docs/index.html
    log_result "update_index" "true" "Updated API_BASE in index.html."
else
    log_result "update_index" "info" "API_BASE already set to localhost:5000."
fi

# ----------------------------------------------------------------------
# Commit and push changes
# ----------------------------------------------------------------------
git add app.py docs/index.html
git commit -m "Add CORS and update frontend API endpoint" || log_result "git_commit" "info" "No changes to commit."
git push origin main || {
    log_result "git_push" "false" "Push failed. Please check your remote."
    exit 1
}
log_result "git_push" "true" "Changes pushed to GitHub."

# ----------------------------------------------------------------------
# Run Flask backend
# ----------------------------------------------------------------------
echo
echo "=== STARTING FLASK BACKEND ==="
echo "Make sure you have a database file at /data/diagnostics.db or set DB_PATH."
echo "Press Ctrl+C to stop the server."

# Set DB_PATH to a local file if not set.
export DB_PATH="${DB_PATH:-./diagnostics.db}"

# Ensure the database file exists (sqlite3 will create it if needed).
if [ ! -f "$DB_PATH" ]; then
    echo "Creating database at $DB_PATH..."
    python3 -c "import sqlite3; conn = sqlite3.connect('$DB_PATH'); conn.execute('CREATE TABLE IF NOT EXISTS diagnostics (id INTEGER PRIMARY KEY AUTOINCREMENT, run_id TEXT, component TEXT, status TEXT, line_number INTEGER, line_text TEXT, logged_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP)'); conn.execute('CREATE TABLE IF NOT EXISTS rule_compliance (id INTEGER PRIMARY KEY AUTOINCREMENT, script_name TEXT, rule_id TEXT, passed INTEGER, evidence TEXT, created_ts TIMESTAMP DEFAULT CURRENT_TIMESTAMP)'); conn.commit(); conn.close()" || {
        log_result "db_init" "false" "Failed to create database. Check permissions."
        exit 1
    }
    log_result "db_init" "true" "Database created at $DB_PATH."
fi

echo "Starting Flask server on port 5000..."
exec python3 app.py
