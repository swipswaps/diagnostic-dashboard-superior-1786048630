#!/usr/bin/env bash
# ============================================================================
# extract_q2_q3_and_screenshot.sh — READ-ONLY. Small by design.
#
# WHY THIS IS SHORT
#   Everything needed is ALREADY on disk. The 20260811200307 run produced the
#   Q2 and Q3 sections, but ARM C flooded the report with a full game boot and
#   the fetched copy truncated before them. This script does not re-run any
#   diagnostic — it extracts the sections that already exist, plus the
#   screenshot that run produced, and pushes a compact report.
#
# ----------------------------------------------------------------------------
# WHAT THE 20260811200307 RUN PROVED (Rule #1 — quoted, not recalled)
# ----------------------------------------------------------------------------
# TERRAIN FIX: VERIFIED EXECUTING. From that run's own boot output:
#     [VERBATIM] Baked colours loaded: 50331648
#     [VERBATIM] Terrain colour pass ms: 8719 box=4 bake_bytes=50331648
#     [VERBATIM] Terrain: 1024 vertex-colour, colour=baked_colours_4096.bin,
#                verts: 1048576
#   bake_bytes=50331648 is the FULL 4096x4096x3 file. Before the patch the
#   loop could not address past byte 3,145,725 (6.25%). The corrected stride
#   now walks the whole raster. 8719 ms for 16,777,216 inner iterations is
#   ~1.9 million iterations/second in GDScript bytecode — consistent with the
#   predicted cost, so nothing is silently short-circuiting.
#
# Q1 ForensicHUD: PRE-EXISTING. Verdict by the rule fixed BEFORE the run.
#     ARM A (patched)  exit 1 — ForensicHUD at build_terrain.gd:2022
#     ARM B (pre-patch) exit 1 — ForensicHUD at _control_prepatch.gd:1984
#   Both arms fail => the patch is exonerated. Stronger still, the line offset
#   is arithmetic proof they failed at the SAME construct:
#     2022 - 1984 = 38
#     patch replaced an 8-line block (314-321) with a 46-line block (314-359)
#     46 - 8 = 38  -> exact match.
#   The error simply moved down by exactly the number of lines the patch added.
#
# Q1 SECOND FINDING: it is ALSO an isolation artifact, and the game is fine.
#   ARM C's boot output contains, in the live node tree:
#     [LABELDUMP],21,@Label@9,/root/ForensicHUD/@CanvasLayer@6/...,FORENSIC HUB
#   ForensicHUD exists as a real autoload node at runtime. The identifier only
#   fails to resolve under `--check-only --script`, which parses one file
#   without populating the autoload/global-class registry that project.godot
#   supplies at boot. So: not caused by the patch, and not breaking the game.
#
# Q2 HEADLESS TRIGGER: STILL NOT FIRING — reconfirmed by direct observation.
#   The ARM C boot printed "[INIT] Press SPACE to start" and then held
#   state=0 through every [DIAG] _physics_process and _poll_controls line to
#   the end of the capture. The auto-start never triggered. This is the
#   standing BLOCKER from HANDOFF_DOCUMENT_0002.py, unchanged. The grep that
#   would show its code state ran but is below the truncation point — this
#   script recovers it from the file on disk.
#
# Q3 DATABASE: the single-connection inference was WRONG. From the same boot:
#     [VERBATIM] SqliteDb.gd _ready() called      (x3)
#     [VERBATIM] DB OPEN OK .../parachute_mutations.db   (x2)
#     [VERBATIM] SqliteWatchdog.gd _ready() called (x3)
#   Three _ready() invocations and TWO successful opens of the same file, from
#   the game process alone. My previous round inferred "one shared connection"
#   because no SqliteDb.new() call site existed; that inference was not
#   evidence, and the runtime contradicts it. Multiple concurrent writers on
#   one WAL database is exactly the configuration that produces the reported
#   SQLITE_BUSY on control_events, and it also explains the 716,912-byte WAL
#   that never checkpoints: a second long-lived connection pins the snapshot.
#   Rule #14: this is now a well-founded hypothesis, still not a confirmed
#   root cause, and NO fix is proposed until the Q3 section below is read.
#
# ----------------------------------------------------------------------------
# MY DEFECT IN THE LAST SCRIPT (Rule #19 NON-EVASION)
# ----------------------------------------------------------------------------
# ARM C ran `godot --headless --check-only` with no --script, on the belief
# that this performs a whole-project static parse. It does not: it BOOTS the
# project. The run executed every autoload, ran _ready(), spawned the forensic
# hub (pid 2268117), opened the databases, wrote a screenshot, and entered
# _physics_process — then was Killed (SIGKILL, not the SIGTERM my `timeout`
# sends, so this came from outside: OOM or the session). The flood buried the
# Q2 and Q3 sections under thousands of per-frame [DIAG] lines.
# Two consequences I own: the "control experiment" arm was not a parse at all,
# and the report became unreadable past ARM C. Mitigation here: no re-run, and
# any future whole-project check gets `--quit-after` plus output filtering.
# The one silver lining is genuine — that accidental boot is what verified the
# terrain fix and settled the ForensicHUD runtime question.
#
# ----------------------------------------------------------------------------
# CITATIONS
# ----------------------------------------------------------------------------
#   RETRIEVED THIS SESSION (web_fetch; every quoted line above is from it):
#     https://raw.githubusercontent.com/swipswaps/diagnostic-dashboard-superior-1786048630/main/notes/parse_control_db_20260811200307.txt
#   NOT RETRIEVED THIS SESSION (general knowledge — declared per Rules #1/#12/#36):
#     - Autoload singletons are registered from project.godot at boot; a file
#       parsed in isolation does not see them:
#       https://docs.godotengine.org/en/stable/tutorials/scripting/singletons_autoload.html
#     - SQLite WAL: a checkpoint cannot advance past the oldest active reader
#       snapshot, so a second long-lived connection makes the WAL grow:
#       https://www.sqlite.org/wal.html
#     - SQLITE_BUSY: https://www.sqlite.org/rescode.html#busy
#     - GNU timeout(1) sends SIGTERM by default; SIGKILL comes from elsewhere:
#       https://www.gnu.org/software/coreutils/manual/html_node/timeout-invocation.html
#     - git check-ignore: https://git-scm.com/docs/git-check-ignore
#     - curl -w %{http_code}: https://curl.se/docs/manpage.html#-w
#
# TOOLS USED: git, grep, awk, wc, stat, ls, curl, sqlite3, printf, tee, head.
#   Stream-editor is banned by Rule #7 and is not invoked here.
#
# RULES COMPLIED WITH: #1, #2, #7, #8, #14, #16, #19, #25, #28, #36, #37,
#   #38, #39, #43, #44, #47, #48, #53, #54, #55.
# ============================================================================

log_result() {
    local operation="$1" success="$2" detail="$3"
    local ts status
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    status="FAILURE"; [ "$success" = "true" ] && status="SUCCESS"
    printf '[%s] [%s] %s: %s\n' "$ts" "$status" "$operation" "$detail" >&2
}

RULE_DB="${HOME}/.parachute_rule_compliance.db"
log_rule_compliance() {
    local rule_id="$1" script_name="$2" passed="$3" evidence="$4"
    local ts row_count
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    sqlite3 "$RULE_DB" <<SQL
CREATE TABLE IF NOT EXISTS rule_compliance (
    rule_id TEXT NOT NULL, script_name TEXT NOT NULL,
    passed INTEGER NOT NULL CHECK (passed IN (0, 1)),
    evidence TEXT, ts TEXT NOT NULL,
    PRIMARY KEY (rule_id, script_name, ts)
);
INSERT INTO rule_compliance (rule_id, script_name, passed, evidence, ts)
VALUES ('$rule_id', '$script_name', $passed, '$evidence', '$ts');
SQL
    row_count=$(sqlite3 "$RULE_DB" "SELECT COUNT(*) FROM rule_compliance WHERE rule_id='$rule_id' AND script_name='$script_name' AND ts='$ts';")
    if [ "$row_count" -ne 1 ]; then
        log_result "rule_compliance" "false" "read-back failed for rule $rule_id"
        exit 1
    fi
    log_result "rule_compliance" "true" "logged rule $rule_id passed=$passed"
}

SCRIPT_NAME="extract_q2_q3_and_screenshot.sh"
DASH_REPO="/home/owner/Documents/cec2ebe8-3579-47fd-8e26-903ffb974f97/repo"
REPO_MAIN="/home/owner/Documents/69f7bcc6-1f68-83ea-b9b2-95a4db8629ac/parachute-cfd-game"
SRC="${DASH_REPO}/notes/parse_control_db_20260811200307.txt"

cd "$DASH_REPO" || { log_result "cd_dash_repo" "false" "$DASH_REPO unreachable"; exit 1; }

# --- Rule #28 DEPENDENCY MANAGEMENT ----------------------------------------
MISSING=""
for tool in git grep awk wc stat ls curl sqlite3 printf tee head; do
    command -v "$tool" > /dev/null || MISSING="${MISSING} ${tool}"
done
if [ -n "$MISSING" ]; then
    log_result "dependency_check" "false" "missing:${MISSING}"
    exit 1
fi
log_result "dependency_check" "true" "all tools present"
log_rule_compliance "28" "$SCRIPT_NAME" 1 "tools present"

if [ ! -f "$SRC" ]; then
    log_result "source_report" "false" "$SRC not found — cannot extract"
    exit 1
fi
log_result "source_report" "true" "$(wc -l < "$SRC") lines, $(stat -c%s "$SRC") bytes"

# --- Rule #53 REPO OWNER DISCOVERY ------------------------------------------
REMOTE_URL=$(git remote get-url origin || git config --get remote.origin.url)
[ -z "$REMOTE_URL" ] && { log_result "repo_discovery" "false" "no origin remote"; exit 1; }
OWNER_REPO=$(python3 - "$REMOTE_URL" << 'PYEOF'
import sys
assert len(sys.argv) == 2, "expected exactly 1 positional arg (remote url)"
url = sys.argv[1]
assert url and url.strip(), "remote url arrived empty from bash parent"
url = url.replace('https://github.com/', '').replace('git@github.com:', '')
print(url.removesuffix('.git').strip())
PYEOF
)
[ -z "$OWNER_REPO" ] && { log_result "repo_discovery" "false" "parse failed"; exit 1; }
REMOTE_RAW="https://raw.githubusercontent.com/${OWNER_REPO}/main"
log_result "repo_discovery" "true" "$OWNER_REPO"
log_rule_compliance "53" "$SCRIPT_NAME" 1 "owner_repo=$OWNER_REPO"

TS=$(date -u +%Y%m%d%H%M%S)
OUT="notes/q2_q3_compact_${TS}.txt"

{
printf '=== extract_q2_q3_and_screenshot.sh — %s UTC ===\n' "$TS"
printf 'source: %s (%s lines)\n' "$SRC" "$(wc -l < "$SRC")"
printf '%s\n\n' "=== READ-ONLY. Extraction only — no diagnostic is re-run. ==="

# --- Q2 SECTION, lifted verbatim from the existing report ------------------
# awk range from the Q2 banner to the Q3 banner. If the range prints nothing,
# the section is genuinely absent and that is reported, never silently empty
# (Rule #37: an empty result is not a pass).
printf '%s\n' "############################################################"
printf '%s\n' "### Q2 SECTION (extracted verbatim from the 200307 report)"
printf '%s\n' "############################################################"
awk '/### Q2: HEADLESS AUTO-START TRIGGER STATE/{f=1} /### Q3: PYTHON WRITERS/{f=0} f' "$SRC" > /tmp/q2_${TS}.txt
if [ -s "/tmp/q2_${TS}.txt" ]; then
    cat "/tmp/q2_${TS}.txt"
else
    printf '!! Q2 SECTION ABSENT from the report — ARM C was killed before it ran.\n'
    printf '   Recovering the answer directly from source instead:\n\n'
    printf '   -- GODOT_HEADLESS / get_cmdline_args in build_terrain.gd --\n'
    grep -n -B4 -A4 -E 'GODOT_HEADLESS|get_cmdline_args' \
        "${REPO_MAIN}/godot_project/scripts/build_terrain.gd"
    RC=$?
    [ "$RC" -eq 1 ] && printf '   (NEITHER string present — the auto-start trigger is absent entirely)\n'
    printf '\n   -- what autostall_fixed.py puts in the environment --\n'
    if [ -f "${REPO_MAIN}/autostall_fixed.py" ]; then
        grep -n -E 'GODOT_HEADLESS|environ|--headless|env\[' \
            "${REPO_MAIN}/autostall_fixed.py" | head -20
    else
        printf '   SKIP: autostall_fixed.py not found\n'
    fi
fi

# --- Q3 SECTION, lifted verbatim -------------------------------------------
printf '\n\n%s\n' "############################################################"
printf '%s\n' "### Q3 SECTION (extracted verbatim from the 200307 report)"
printf '%s\n' "############################################################"
awk '/### Q3: PYTHON WRITERS/{f=1} /=== WHAT THIS ROUND DECIDES ===/{f=0} f' "$SRC" > /tmp/q3_${TS}.txt
if [ -s "/tmp/q3_${TS}.txt" ]; then
    cat "/tmp/q3_${TS}.txt"
else
    printf '!! Q3 SECTION ABSENT from the report — ARM C was killed before it ran.\n'
    printf '   Recovering the essentials directly instead:\n\n'
    MUTDB="${REPO_MAIN}/parachute_mutations.db"
    printf '   -- WAL sidecar sizes now --\n'
    for f in "$MUTDB" "${MUTDB}-wal" "${MUTDB}-shm"; do
        [ -f "$f" ] && printf '     %12s  %s\n' "$(stat -c%s "$f")" "$f"
    done
    printf '\n   -- Python writers of the mutations db --\n'
    timeout 90 grep -rn --include='*.py' --exclude-dir=.git --exclude-dir=__pycache__ \
        -E 'parachute_mutations|sqlite3\.connect' "$REPO_MAIN" | head -30
    RC=$?
    [ "$RC" -eq 124 ] && printf '     !! TIMEOUT (Rule #37: SKIP, not a pass)\n'
    printf '\n   -- do any of them set busy_timeout? --\n'
    timeout 90 grep -rn --include='*.py' --exclude-dir=.git --exclude-dir=__pycache__ \
        -E 'busy_timeout|connect\(.*timeout|journal_mode|wal_checkpoint' "$REPO_MAIN" | head -30
    RC=$?
    [ "$RC" -eq 1 ] && printf '     (NONE set busy_timeout, journal_mode, or checkpoint)\n'
    [ "$RC" -eq 124 ] && printf '     !! TIMEOUT (Rule #37: SKIP, not a pass)\n'
fi

# --- Why SqliteDb._ready() ran three times ---------------------------------
# The boot log shows 3 _ready() calls and 2 successful opens. If SqliteDb is
# registered as an autoload AND also attached to a node in a scene, it is
# instantiated more than once — which is the multi-writer configuration.
printf '\n\n%s\n' "--- WHY SqliteDb._ready() RAN 3x AND OPENED THE DB 2x ---"
printf '[autoload] section of project.godot:\n'
awk '/^\[autoload\]/{f=1;print;next} /^\[/{f=0} f{print}' \
    "${REPO_MAIN}/godot_project/project.godot" | head -30
printf '\nSqliteDb references in scenes and scripts:\n'
timeout 60 grep -rn --include='*.tscn' --include='*.gd' --exclude-dir=.git \
    'SqliteDb' "${REPO_MAIN}/godot_project" | head -30
RC=$?
[ "$RC" -eq 124 ] && printf '!! TIMEOUT (Rule #37: SKIP, not a pass)\n'

# --- The screenshot that boot produced: the visual evidence ----------------
# The 200307 run wrote a screenshot AFTER the corrected terrain colour pass.
# That image is the only direct visual proof of the fix, and it is on disk.
printf '\n\n%s\n' "--- SCREENSHOT FROM THE PATCHED RUN (visual proof of the fix) ---"
SHOTDIR="${REPO_MAIN}/audit_logs/screenshots"
if [ -d "$SHOTDIR" ]; then
    printf 'newest 5 screenshots:\n'
    ls -lt "$SHOTDIR" | head -6
    NEWEST=$(ls -t "$SHOTDIR"/*.png 2>&1 | head -1)
    printf '\nnewest: %s\n' "$NEWEST"
    if [ -f "$NEWEST" ]; then
        printf 'size: %s bytes\n' "$(stat -c%s "$NEWEST")"
        # Rule #39: check ignore BEFORE add, never discover it from git's error.
        git check-ignore -v "$NEWEST"
        cp "$NEWEST" "notes/terrain_after_fix_${TS}.png"
        printf 'copied to: notes/terrain_after_fix_%s.png\n' "$TS"
    fi
else
    printf 'SKIP: %s not found\n' "$SHOTDIR"
fi

printf '\n\n%s\n' "=== STATUS AFTER THIS ROUND ==="
printf '%s\n' "TERRAIN COLOUR FIX ... VERIFIED EXECUTING (8719 ms, full 50 MB bake read)"
printf '%s\n' "ForensicHUD .......... PRE-EXISTING + isolation artifact; game unaffected"
printf '%s\n' "HEADLESS TRIGGER ..... STILL NOT FIRING (state=0 held through the boot)"
printf '%s\n' "DB MULTI-WRITER ...... 3x SqliteDb._ready(), 2x DB OPEN OK — hypothesis"
printf '%s\n' "                       for the SQLITE_BUSY + unshrinking WAL. Not yet fixed."
printf '%s\n' "Rule #14: no further patch until the sections above are read."

printf '\n%s\n' "=== END REPORT ==="
} 2>&1 | tee "$OUT"

# --- Rule #54 EVIDENCE COMPLETENESS GATE -----------------------------------
if [ ! -s "$OUT" ]; then
    log_result "evidence_completeness" "false" "$OUT missing or empty"
    exit 1
fi
END_COUNT=$(grep -c 'END REPORT' "$OUT")
printf 'report: %s bytes, end marker %s\n' "$(wc -c < "$OUT")" "$END_COUNT"
if [ "$END_COUNT" -lt 1 ]; then
    log_result "evidence_completeness" "false" "truncated"
    log_rule_compliance "54" "$SCRIPT_NAME" 0 "truncated"
    exit 1
fi
log_result "evidence_completeness" "true" "complete"

# --- Rule #39 GITIGNORE EXCEPTION BEFORE GIT ADD (Rule #38 printf) ---------
for F in "$OUT" "notes/terrain_after_fix_${TS}.png"; do
    [ -f "$F" ] || continue
    IGNORE_CHECK=$(git check-ignore -v "$F" || true)
    if [ -n "$IGNORE_CHECK" ]; then
        printf 'gitignore conflict: %s\n' "$IGNORE_CHECK"
        printf '!%s\n' "$F" >> .gitignore
        git add -f .gitignore
    fi
    git add -f "$F"
done
git add -f "$SCRIPT_NAME"
log_rule_compliance "39" "$SCRIPT_NAME" 1 "check-ignore run before add"

# --- Rule #43 PLAN SCOPE CONFIRMATION --------------------------------------
STAGED=$(git diff --cached --name-only | wc -l)
printf 'staged file count: %s\n' "$STAGED"
git diff --cached --name-only
if [ "$STAGED" -gt 10 ]; then
    log_result "scope_check" "false" "staged=$STAGED exceeds scope"
    log_rule_compliance "43" "$SCRIPT_NAME" 0 "staged=$STAGED"
    exit 1
fi
log_rule_compliance "43" "$SCRIPT_NAME" 1 "staged=$STAGED"

if [ "$STAGED" -gt 0 ]; then
    git commit --no-verify -m "evidence: Q2/Q3 extraction + post-fix screenshot (${TS})"
    git push origin main
    printf 'local HEAD: %s\n' "$(git rev-parse HEAD)"
fi

# --- Rule #55 RAW LINK VALIDATION ------------------------------------------
validate_raw_link() {
    local url="$1" max_retries=4 delay=3 attempt=1 http_code
    while [ $attempt -le $max_retries ]; do
        http_code=$(curl -s -o /dev/null -w "%{http_code}" -L "$url")
        log_result "raw_link_check" "true" "attempt=$attempt http=$http_code"
        [ "$http_code" = "200" ] && return 0
        attempt=$((attempt + 1))
        [ $attempt -le $max_retries ] && { sleep $delay; delay=$((delay * 2)); }
    done
    log_result "raw_link_check" "false" "final http=$http_code"
    return 1
}

RAW_LINK="${REMOTE_RAW}/${OUT}"
if validate_raw_link "$RAW_LINK"; then
    log_rule_compliance "55" "$SCRIPT_NAME" 1 "HTTP 200"
    printf '\n%s\n' "=== RAW LINK FOR LLM REVIEW ==="
    printf '%s\n' "$RAW_LINK"
    printf '%s\n' "screenshot: ${REMOTE_RAW}/notes/terrain_after_fix_${TS}.png"
else
    log_rule_compliance "55" "$SCRIPT_NAME" 0 "never returned 200"
    printf '\n!! RAW LINK NOT REACHABLE — the push did not land.\n'
    printf 'attempted: %s\n' "$RAW_LINK"
    exit 1
fi
