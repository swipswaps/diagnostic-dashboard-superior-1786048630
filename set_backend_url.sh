#!/usr/bin/env bash
# ============================================================================
# set_backend_url.sh – Update docs/index.html to point to a backend URL.
# ============================================================================

if [ -z "$1" ]; then
    echo "Usage: ./set_backend_url.sh <BACKEND_URL>"
    echo "Example: ./set_backend_url.sh https://diagnostic-dashboard.onrender.com"
    exit 1
fi

BACKEND_URL="$1"
echo "Setting backend URL to: $BACKEND_URL"

# Update the API_BASE in docs/index.html
sed -i "s|const API_BASE = .*|const API_BASE = '$BACKEND_URL';|" docs/index.html

git add docs/index.html
git commit -m "Update backend URL to $BACKEND_URL"
git push origin main

echo "✅ Updated. GitHub Pages will redeploy shortly."
echo "Check it at: https://swipswaps.github.io/diagnostic-dashboard-1786040134/"
