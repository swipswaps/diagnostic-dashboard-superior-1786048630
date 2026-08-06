#!/usr/bin/env bash
# ============================================================================
# fix_push_and_pages.sh – Fix push and enable Pages.
# ============================================================================

set -o pipefail

OWNER="swipswaps"
REPO="diagnostic-dashboard-1786040134"
PAGES_URL="https://$OWNER.github.io/$REPO"

echo "=== FIX PUSH AND PAGES ==="
echo "Working directory: $(pwd)"

# ----------------------------------------------------------------------
# 1. Fix push: if local branch is master, push to origin main.
# ----------------------------------------------------------------------
CURRENT_BRANCH=$(git branch --show-current 2>/dev/null)
if [ "$CURRENT_BRANCH" = "master" ]; then
    echo "Local branch is 'master'. Pushing to 'main'..."
    git push -u origin master:main || {
        echo "❌ Push failed. Check remote and permissions."
        exit 1
    }
    # Set upstream to origin/main.
    git branch --set-upstream-to=origin/main master || echo "Upstream set."
elif [ "$CURRENT_BRANCH" = "main" ]; then
    echo "Local branch is 'main'. Pushing normally..."
    git push -u origin main || {
        echo "❌ Push failed."
        exit 1
    }
else
    echo "⚠️  Unknown branch: $CURRENT_BRANCH. Attempting to push anyway..."
    git push -u origin HEAD:main || {
        echo "❌ Push failed."
        exit 1
    }
fi

# ----------------------------------------------------------------------
# 2. Ensure Pages is enabled with legacy build type.
# ----------------------------------------------------------------------
echo "Enabling Pages with legacy build type..."
gh api -X POST "repos/$OWNER/$REPO/pages" \
    --input - <<< '{"source":{"branch":"main","path":"/docs"},"build_type":"legacy"}' 2>&1 | jq '.' || echo "Pages may already be enabled."

# ----------------------------------------------------------------------
# 3. Trigger a build and monitor.
# ----------------------------------------------------------------------
echo "Triggering build..."
gh api -X POST "repos/$OWNER/$REPO/pages/builds" 2>&1 | jq '.'

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
# 4. Fetch build logs.
# ----------------------------------------------------------------------
echo "Fetching Pages build logs..."
gh api "repos/$OWNER/$REPO/pages/builds" | jq '.'

# ----------------------------------------------------------------------
# 5. Save diagnostics and push.
# ----------------------------------------------------------------------
mkdir -p diagnostics
LOG_FILE="diagnostics/fix_$(date -u +%Y%m%d%H%M%S).txt"
gh api "repos/$OWNER/$REPO/pages" > "$LOG_FILE"
git add "$LOG_FILE"
git commit -m "Add Pages diagnostics" || echo "No changes"
git push origin master:main || echo "Push failed (maybe no changes)."

RAW_LINK="https://raw.githubusercontent.com/$OWNER/$REPO/main/$LOG_FILE"
echo
echo "=== RAW LOG LINK ==="
echo "$RAW_LINK"

# ----------------------------------------------------------------------
# 6. Final status.
# ----------------------------------------------------------------------
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$PAGES_URL")
echo "Pages status: $BUILD_STATUS"
echo "HTTP: $HTTP_CODE"
if [ "$BUILD_STATUS" = "built" ] && [ "$HTTP_CODE" = "200" ]; then
    echo "✅ Site is live!"
    xdg-open "$PAGES_URL" 2>/dev/null
else
    echo "❌ Site not live. Check the logs above."
fi

echo "=== FIX PUSH AND PAGES COMPLETE ==="
