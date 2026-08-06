#!/usr/bin/env bash
# ============================================================================
# get_workflow_logs.sh – Trigger the Pages workflow and fetch its logs.
# ============================================================================

OWNER="swipswaps"
REPO="diagnostic-dashboard-1786040134"
PAGES_URL="https://$OWNER.github.io/$REPO"

echo "=== GET WORKFLOW LOGS ==="

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
# 1. Ensure workflow file exists and is correct.
# ----------------------------------------------------------------------
mkdir -p .github/workflows
cat > .github/workflows/pages.yml <<'YAMLEOF'
name: Deploy Pages

on:
  push:
    branches: [ main ]
  workflow_dispatch:

permissions:
  pages: write
  id-token: write

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Setup Pages
        uses: actions/configure-pages@v4
      - name: Upload artifact
        uses: actions/upload-pages-artifact@v3
        with:
          path: './docs'
      - name: Deploy to GitHub Pages
        id: deployment
        uses: actions/deploy-pages@v4
YAMLEOF

git add .github/workflows/pages.yml
git commit -m "Update workflow with workflow_dispatch" || echo "No changes"
git push origin main

# ----------------------------------------------------------------------
# 2. Trigger the workflow via workflow_dispatch.
# ----------------------------------------------------------------------
echo "Triggering workflow via workflow_dispatch..."
gh workflow run pages.yml --repo "$OWNER/$REPO" --ref main 2>&1 || {
    echo "⚠️  workflow_dispatch failed. Falling back to push trigger..."
    # Push a dummy commit to trigger.
    touch trigger_$(date +%s).txt
    git add .
    git commit -m "Trigger workflow via push"
    git push origin main
}

# ----------------------------------------------------------------------
# 3. Wait for the workflow run and fetch logs.
# ----------------------------------------------------------------------
echo "Waiting for workflow run to start..."
MAX_ATTEMPTS=20
ATTEMPT=0
RUN_ID=""
while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
    ATTEMPT=$((ATTEMPT + 1))
    RUN_ID=$(gh run list --repo "$OWNER/$REPO" --workflow "pages.yml" --limit 1 --json databaseId,status,conclusion -q '.[0].databaseId' 2>/dev/null)
    if [ -n "$RUN_ID" ]; then
        echo "[$(date -u +%H:%M:%S)] Found run: $RUN_ID"
        break
    fi
    echo "[$(date -u +%H:%M:%S)] No run yet (attempt $ATTEMPT)"
    sleep 10
done

if [ -z "$RUN_ID" ]; then
    echo "❌ No workflow run found after $MAX_ATTEMPTS attempts."
    echo "Check Actions tab manually: https://github.com/$OWNER/$REPO/actions"
    exit 1
fi

# ----------------------------------------------------------------------
# 4. Fetch and print the full workflow logs.
# ----------------------------------------------------------------------
echo
echo "=== FULL WORKFLOW LOGS (run $RUN_ID) ==="
gh run view "$RUN_ID" --repo "$OWNER/$REPO" --log

# ----------------------------------------------------------------------
# 5. Also check the run status.
# ----------------------------------------------------------------------
RUN_STATUS=$(gh run view "$RUN_ID" --repo "$OWNER/$REPO" --json status,conclusion -q '.status + " / " + .conclusion')
echo
echo "Run status: $RUN_STATUS"

# ----------------------------------------------------------------------
# 6. Save logs to file and push.
# ----------------------------------------------------------------------
LOG_FILE="diagnostics/workflow_$(date -u +%Y%m%d%H%M%S).txt"
gh run view "$RUN_ID" --repo "$OWNER/$REPO" --log > "$LOG_FILE"
git add "$LOG_FILE"
git commit -m "Add workflow logs"
git push origin main

RAW_LINK="https://raw.githubusercontent.com/$OWNER/$REPO/main/$LOG_FILE"
echo
echo "=== RAW LOG LINK ==="
echo "$RAW_LINK"

# ----------------------------------------------------------------------
# 7. Final Pages status.
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

echo "=== GET WORKFLOW LOGS COMPLETE ==="
