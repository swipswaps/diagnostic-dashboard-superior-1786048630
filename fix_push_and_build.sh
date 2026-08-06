#!/usr/bin/env bash
# ============================================================================
# fix_push_and_build.sh – Fix branch mismatch, force push, then configure Pages.
# ============================================================================

set -o pipefail

OWNER="swipswaps"
REPO="diagnostic-dashboard-1786040134"
PAGES_URL="https://$OWNER.github.io/$REPO"

echo "=== FIX PUSH AND BUILD ==="
echo "Working directory: $(pwd)"

# ----------------------------------------------------------------------
# 1. Fix branch: rename local 'master' to 'main' and force push.
# ----------------------------------------------------------------------
if git branch --show-current | grep -q "master"; then
    echo "Local branch is 'master'. Renaming to 'main'..."
    git branch -m master main || { echo "❌ Rename failed."; exit 1; }
    echo "✅ Renamed to 'main'."
fi

# Force push (overwrite remote main with our local main).
echo "Force pushing to remote main..."
git push -f origin main || { echo "❌ Force push failed. Check remote and permissions."; exit 1; }
echo "✅ Force push succeeded."

# ----------------------------------------------------------------------
# 2. Ensure Pages is enabled and set to legacy build type.
# ----------------------------------------------------------------------
echo "Checking Pages status..."
if ! gh api "repos/$OWNER/$REPO/pages" &>/dev/null; then
    echo "Pages not enabled. Creating..."
    gh api -X POST "repos/$OWNER/$REPO/pages" \
        --input - <<< '{"source":{"branch":"main","path":"/docs"},"build_type":"legacy"}' | jq '.'
fi

# Force legacy build type (most reliable for static sites).
echo "Setting Pages to legacy build type..."
gh api -X PUT "repos/$OWNER/$REPO/pages" \
    --input - <<< '{"source":{"branch":"main","path":"/docs"},"build_type":"legacy"}' | jq '.'

# ----------------------------------------------------------------------
# 3. Verify configuration.
# ----------------------------------------------------------------------
CONFIG=$(gh api "repos/$OWNER/$REPO/pages" | jq '{source: .source, build_type: .build_type}')
echo "Config: $CONFIG"
if echo "$CONFIG" | grep -q '"build_type": "legacy"'; then
    echo "✅ Build type is legacy."
else
    echo "⚠️  Build type not legacy – continuing anyway."
fi

# ----------------------------------------------------------------------
# 4. Trigger a build and monitor.
# ----------------------------------------------------------------------
echo "Triggering build via API..."
gh api -X POST "repos/$OWNER/$REPO/pages/builds" | jq '.'

echo "Monitoring build status (checking every 10s)..."
MAX_ATTEMPTS=30
ATTEMPT=0
BUILD_STATUS=""
while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
    ATTEMPT=$((ATTEMPT + 1))
    BUILD_STATUS=$(gh api "repos/$OWNER/$REPO/pages" | jq -r '.status // "unknown"')
    echo "[$(date -u +%H:%M:%S)] Attempt $ATTEMPT – Status: $BUILD_STATUS"
    if [ "$BUILD_STATUS" = "built" ]; then
        echo "✅ Build succeeded!"
        break
    elif [ "$BUILD_STATUS" = "errored" ]; then
        echo "❌ Build failed. Fetching error..."
        gh api "repos/$OWNER/$REPO/pages/builds" | jq '.[0].error'
        break
    fi
    sleep 10
done

# ----------------------------------------------------------------------
# 5. Fetch the build logs (if any).
# ----------------------------------------------------------------------
echo
echo "=== PAGES BUILDS ==="
gh api "repos/$OWNER/$REPO/pages/builds" | jq '.'

# ----------------------------------------------------------------------
# 6. Save diagnostics and push.
# ----------------------------------------------------------------------
LOG_FILE="diagnostics/build_$(date -u +%Y%m%d%H%M%S).txt"
gh api "repos/$OWNER/$REPO/pages" > "$LOG_FILE"
git add "$LOG_FILE"
git commit -m "Add build diagnostics" || echo "No changes"
git push origin main

RAW_LINK="https://raw.githubusercontent.com/$OWNER/$REPO/main/$LOG_FILE"
echo
echo "=== RAW LOG LINK ==="
echo "$RAW_LINK"

# ----------------------------------------------------------------------
# 7. Final status.
# ----------------------------------------------------------------------
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$PAGES_URL")
echo
echo "=== FINAL STATUS ==="
echo "Pages status: $BUILD_STATUS"
echo "HTTP: $HTTP_CODE"
if [ "$BUILD_STATUS" = "built" ] && [ "$HTTP_CODE" = "200" ]; then
    echo "✅ Site is live!"
    xdg-open "$PAGES_URL" 2>/dev/null
else
    echo "❌ Site not live. Check the logs above."
    echo "The raw log link contains the Pages API response."
fi

echo "=== FIX PUSH AND BUILD COMPLETE ==="
