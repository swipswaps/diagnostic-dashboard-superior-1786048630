#!/usr/bin/env bash
# ============================================================================
# run_flask_local.sh – Set DB_PATH and run Flask backend locally.
# ============================================================================

set -o pipefail

echo "=== RUN FLASK LOCAL ==="
cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" || exit 1
echo "Working directory: $(pwd)"

# ----------------------------------------------------------------------
# Rule #50: Environment variable export gate
# ----------------------------------------------------------------------
export DB_PATH="${DB_PATH:-./diagnostics.db}"
echo "DB_PATH=$DB_PATH"

# Ensure the directory for the database exists.
DB_DIR=$(dirname "$DB_PATH")
if [ ! -d "$DB_DIR" ]; then
    echo "Creating directory: $DB_DIR"
    mkdir -p "$DB_DIR" || {
        echo "❌ Failed to create $DB_DIR"
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
        echo "❌ Failed to create database."
        exit 1
    }
fi

# ----------------------------------------------------------------------
# Run Flask
# ----------------------------------------------------------------------
echo
echo "Starting Flask server on port 5000..."
echo "Visit http://localhost:5000 to see the dashboard."
echo "Press Ctrl+C to stop."
exec python3 app.py
