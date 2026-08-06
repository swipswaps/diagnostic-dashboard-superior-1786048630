#!/usr/bin/env bash
# ============================================================================
# fetch_completed_logs.sh – Wait for workflow run 31126645316, then fetch logs.
# ============================================================================

OWNER="swipswaps"
REPO="diagnostic-dashboard-1786040134"
RUN_ID="31126645316"
PAGES_URL="https://$OWNER.github.io/$REPO"

echo "=== FETCH COMPLETED WORKFLOW LOGS ==="
echo "Run: $RUN_ID"

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
# 1. Wait for the workflow run to complete.
# ----------------------------------------------------------------------
echo "Waiting for run $RUN_ID to complete..."
MAX_ATTEMPTS=30
ATTEMPT=0
while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
    ATTEMPT=$((ATTEMPT + 1))
    STATUS=$(gh run view "$RUN_ID" --repo "$OWNER/$REPO" --json status -q '.status' 2>/dev/null)
    if [ "$STATUS" = "completed" ]; then
        echo "[$(date -u +%H:%M:%S)] Run completed!"
        break
    elif [ "$STATUS" = "queued" ] || [ "$STATUS" = "in_progress" ]; then
        echo "[$(date -u +%H:%M:%S)] Run still $STATUS (attempt $ATTEMPT)"
    else
        echo "[$(date -u +%H:%M:%S)] Run status: $STATUS"
    fi
    sleep 10
done

if [ "$STATUS" != "completed" ]; then
    echo "❌ Run did not complete within $MAX_ATTEMPTS attempts."
    echo "Check manually: https://github.com/$OWNER/$REPO/actions/runs/$RUN_ID"
    exit 1
fi

# ----------------------------------------------------------------------
# 2. Fetch the conclusion and logs.
# ----------------------------------------------------------------------
CONCLUSION=$(gh run view "$RUN_ID" --repo "$OWNER/$REPO" --json conclusion -q '.conclusion')
echo "Run conclusion: $CONCLUSION"

echo
echo "=== FULL WORKFLOW LOGS ==="
gh run view "$RUN_ID" --repo "$OWNER/$REPO" --log

# ----------------------------------------------------------------------
# 3. Save logs to file and push.
# ----------------------------------------------------------------------
LOG_FILE="diagnostics/workflow_${RUN_ID}_$(date -u +%Y%m%d%H%M%S).txt"
gh run view "$RUN_ID" --repo "$OWNER/$REPO" --log > "$LOG_FILE"
git add "$LOG_FILE"
git commit -m "Add workflow logs for run $RUN_ID"
git push origin main

RAW_LINK="https://raw.githubusercontent.com/$OWNER/$REPO/main/$LOG_FILE"
echo
echo "=== RAW LOG LINK ==="
echo "$RAW_LINK"

# ----------------------------------------------------------------------
# 4. Final Pages status.
# ----------------------------------------------------------------------
PAGES_STATUS=$(gh api "repos/$OWNER/$REPO/pages" | jq -r '.status')
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "$PAGES_URL")
echo
echo "=== FINAL STATUS ==="
echo "Pages status: $PAGES_STATUS"
echo "HTTP: $HTTP_CODE"
if [ "$PAGES_STATUS" = "built" ] && [ "$HTTP_CODE" = "200" ]; then
    echo "✅ Site is live!"
    xdg-open "$PAGES_URL" 2>/dev/null
else
    echo "❌ Site not live. Check the logs above for the error."
fi

echo "=== FETCH COMPLETED LOGS COMPLETE ==="
