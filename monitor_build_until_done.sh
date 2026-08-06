#!/usr/bin/env bash
# ============================================================================
# monitor_build_until_done.sh – Continue monitoring the latest Pages build.
# ============================================================================

OWNER="swipswaps"
REPO="diagnostic-dashboard-1786040134"
PAGES_URL="https://$OWNER.github.io/$REPO"

echo "=== MONITOR BUILD UNTIL DONE ==="

# Ensure we are in the repo.
if [ ! -d ".git" ] || ! git remote get-url origin | grep -q "$REPO"; then
    echo "⚠️  Not in the repo. Entering subdirectory..."
    cd "$REPO" 2>/dev/null || {
        echo "❌ Repo not found. Please run from the repo root."
        exit 1
    }
fi
echo "Working directory: $(pwd)"

# ----------------------------------------------------------------------
# 1. Ensure .nojekyll is in the root as well.
# ----------------------------------------------------------------------
touch .nojekyll
git add .nojekyll
git commit -m "Add .nojekyll to root" || echo "No changes"
git push origin main

# ----------------------------------------------------------------------
# 2. Monitor the latest build.
# ----------------------------------------------------------------------
echo "Fetching latest build status..."
MAX_ATTEMPTS=30
ATTEMPT=0
BUILD_STATUS="unknown"
while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
    ATTEMPT=$((ATTEMPT + 1))
    BUILD_RESPONSE=$(gh api "repos/$OWNER/$REPO/pages/builds" 2>/dev/null)
    BUILD_STATUS=$(echo "$BUILD_RESPONSE" | jq -r '.[0].status // "unknown"')
    BUILD_ERROR=$(echo "$BUILD_RESPONSE" | jq -r '.[0].error.message // "none"')
    echo "[$(date -u +%H:%M:%S)] Attempt $ATTEMPT – Status: $BUILD_STATUS, Error: $BUILD_ERROR"
    
    if [ "$BUILD_STATUS" = "built" ]; then
        echo "✅ Build succeeded!"
        break
    elif [ "$BUILD_STATUS" = "errored" ]; then
        echo "❌ Build failed with error: $BUILD_ERROR"
        echo "Fetching full build details..."
        echo "$BUILD_RESPONSE" | jq '.[0]'
        break
    fi
    sleep 10
done

# ----------------------------------------------------------------------
# 3. If still building after max attempts, show the status.
# ----------------------------------------------------------------------
if [ "$BUILD_STATUS" != "built" ] && [ "$BUILD_STATUS" != "errored" ]; then
    echo "⏳ Build still in progress after $MAX_ATTEMPTS attempts."
    echo "You can check the status manually at:"
    echo "https://github.com/$OWNER/$REPO/settings/pages"
fi

# ----------------------------------------------------------------------
# 4. Final HTTP check.
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
    echo "❌ Site not live. Check the Pages settings for the error:"
    echo "https://github.com/$OWNER/$REPO/settings/pages"
fi
