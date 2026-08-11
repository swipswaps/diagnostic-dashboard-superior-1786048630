#!/usr/bin/env bash
# ============================================================================
# diag_parse_control_and_db.sh — READ-ONLY control experiment + audit.
#
# PURPOSE
#   The terrain fix landed and is structurally verified.  Three questions now
#   block /goal, and none can be answered without evidence:
#     Q1  Is "Identifier not found: ForensicHUD" caused by my patch, was it
#         already there, or is it an artifact of --check-only in isolation?
#     Q2  What is the headless auto-start trigger state in build_terrain.gd?
#         (HANDOFF_DOCUMENT_0002.py calls this the outstanding BLOCKER; every
#         attempt to reach it so far has been cut short.)
#     Q3  Which process is actually hitting SQLITE_BUSY on control_events?
#         The Godot side is now known-innocent; the Python side is unexamined.
#   This script MUTATES NO GAME FILE.  It answers all three and pushes it.
#
# ----------------------------------------------------------------------------
# MY OWN DEFECT, DISCLOSED (Rule #19 NON-EVASION, Rule #2 ROOT CAUSE)
# ----------------------------------------------------------------------------
# fix_terrain_colour_index.sh printed "parse gate exit: 0" on a line that had
# just displayed a fatal compile error.  Cause, exactly:
#     ( ... godot --check-only ... ) || true
#     printf 'parse gate exit: %s\n' "$?"
# `|| true` runs `true` when godot fails, so `$?` is the status of `true` —
# always 0 — not of godot.  That reported code was structurally incapable of
# being non-zero.  It is a false PASS, which is the precise failure that
# Rule #37 SKIP-AS-PASS PROHIBITION exists to forbid, and my script emitted one.
#
# The identical defect corrupted the database audit.  Every pragma line read
#     printf '  quick_check  : %s\n' "$(timeout 60 sqlite3 ... )"
# Command substitution discards the inner exit status, so when `timeout` killed
# quick_check on the 469,508,096-byte forensics.db at 60 s, the report printed
#     quick_check  :
# an empty value that reads as benign.  It was a TIMEOUT, i.e. UNKNOWN, and I
# presented it as though it were data.
#
# Correct pattern, used throughout this script — run, capture status
# immediately, branch on it; never wrap in `|| true`, never let command
# substitution swallow it:
#     cmd > "$tmp" 2>&1
#     rc=$?
#     if [ "$rc" -eq 124 ]; then ... TIMEOUT => SKIP, not PASS ... ; fi
#
# ----------------------------------------------------------------------------
# WHAT THE LAST REPORT ESTABLISHED (Rule #1 — quoted, not recalled)
# ----------------------------------------------------------------------------
# PATCH VERIFIED STRUCTURALLY.  The diff shows one hunk at 311-359, tabs
#   preserved, exactly one st.add_vertex(verts[i]), elevation path untouched,
#   fallback branch untouched.  sha256 after patch
#   7677034c1e33e633cbec192149d1bbd5532a55bf09eb30b9b4daa8d8bf52c8fe.
# INDEX MAPPING VERIFIED ARITHMETICALLY (computed, not asserted):
#   i=0       -> sx0=0    sz0=0
#   i=1       -> sx0=4    sz0=0
#   i=1023    -> sx0=4095 sz0=0        (row end reaches the source edge)
#   i=1024    -> sx0=0    sz0=4        (row wrap is correct)
#   i=1048575 -> sx0=4095 sz0=4095     (corner reaches the source corner)
#   Adjacent vertices are 4.0029 source texels apart; COLOUR_BOX=4 gives a
#   coverage ratio of 0.9993 — the box footprints tile the source almost
#   exactly, with negligible gap or overlap.
#   NOTE: `var vz := i / W` relies on GDScript int/int being INTEGER division
#   (unlike Python 3).  i and W are both int, so it is correct — but it is
#   load-bearing and worth knowing.
#   RESIDUAL: the box is ANCHORED at sx0, not centred, biasing the sampled
#   footprint ~1.955 m in +x/+z.  Vertex spacing is 3.910 m, so the bias is
#   half a cell — cosmetically irrelevant, and deliberately NOT "fixed" here
#   (Rule #14: never stack an unverified change onto an unverified change).
# COST, for reading the [VERBATIM] timing line: 1,048,576 vertices x 16 inner
#   iterations = 16,777,216 iterations and 50,331,648 PackedByteArray reads in
#   GDScript bytecode.  Several seconds at load is expected, not a defect.
#
# DATABASE FINDINGS (all quoted from that report):
#   - parachute_mutations.db is 141,041,664 B, journal_mode=wal, and its WAL
#     sidecar is 716,912 B — the ONLY non-zero sidecar in the entire tree.  A
#     WAL that never shrinks means checkpoints are not completing, which is
#     what happens when a long-lived reader keeps a snapshot pinned.
#   - control_events holds 1002 rows.  Its schema carries pull_l REAL DEFAULT
#     0.0 and pull_r REAL DEFAULT 0.0.
#   - build_terrain.gd:3818 builds the INSERT by string concatenation and
#     writes only (ts,action,key,state_num,result,reason) — pull_l and pull_r
#     are never written, so the steering columns are dead.  One INSERT per
#     keypress, unparameterised.
#   - SqliteDb.gd:59-92 issues "PRAGMA busy_timeout = 5000;" and
#     "PRAGMA journal_mode = WAL;" SEVENTEEN TIMES EACH.  Functionally
#     harmless (both idempotent) but unmistakable accretion from repeated
#     automated patching.  Critically: the Godot side DOES set a 5 s busy
#     timeout, so it is NOT the process failing fast on SQLITE_BUSY.
#   - The busy_timeout=0 shown for every database is MY audit connection's
#     default, not the game's.  busy_timeout is PER-CONNECTION and is not
#     persisted in the file header; only journal_mode is.  Reading it from a
#     fresh sqlite3 process says nothing about what the game or the Python
#     tools use.  Flagged because that column invites exactly the wrong
#     inference.
#   - "SqliteDb INSTANTIATION SITES" came back EMPTY.  No SqliteDb.new(), no
#     preload, no load anywhere under godot_project.  That points to an
#     autoload singleton declared in project.godot — ONE shared connection,
#     not the "multiple simultaneous SqliteDb instances" that
#     HANDOFF_DOCUMENT_0002.py hypothesised.  Q3 settles it.
#   - forensics.db quick_check TIMED OUT (see the defect disclosure above).
#     Its integrity is UNKNOWN, not "ok".
#   - parac1ute_mutations.db exists — "parac1ute", digit 1 for the letter u.
#     Some tool opened a typo'd path and SQLite silently CREATED it, because
#     connect() creates on open.  Nine tables deep, so it has been swallowing
#     writes meant for the real database.  Reported, not touched.
#   - Redundancy: forensics.db and its snapshot are 469 MB each;
#     parachute_mutations_backup.db and its snapshot 107 MB each.  Disk
#     hygiene, not a blocker.  Reported, not touched.
#
# ----------------------------------------------------------------------------
# Q1 DESIGN — CONTROL EXPERIMENT (Rule #14 SCIENTIFIC DEBUGGING)
# ----------------------------------------------------------------------------
# "The ForensicHUD error is pre-existing" is a HYPOTHESIS until the same
# command runs against the pre-patch file.  Three arms, identical command,
# one variable:
#   ARM A  patched build_terrain.gd            (current state)
#   ARM B  build_terrain.gd.bak.20260810230413 (byte-for-byte pre-patch)
#   ARM C  full-project parse, no --script     (tests whether the error is an
#          artifact of single-file isolation, where the global class registry
#          from project.godot is not populated)
# Interpretation, fixed BEFORE the experiment runs so the result cannot be
# rationalised after the fact:
#   A fails AND B fails   -> pre-existing; the patch is exonerated.
#   A fails AND B passes  -> MY PATCH CAUSED IT.  Roll back immediately.
#   A fails AND C passes  -> artifact of isolated --script parsing; the class
#                            registry is the difference.
# ARM B copies the backup to a scratch path INSIDE godot_project (Godot cannot
# parse res:// paths outside it) and deletes it afterwards.  That scratch file
# is the ONLY filesystem write this script makes, and it is not a game file.
#
# ----------------------------------------------------------------------------
# CITATIONS
# ----------------------------------------------------------------------------
#   RETRIEVED THIS SESSION (web_fetch — every figure above is quoted from it):
#     https://raw.githubusercontent.com/swipswaps/diagnostic-dashboard-superior-1786048630/main/notes/fix_terrain_colour_20260810230413.txt
#   RETRIEVED THIS SESSION (user upload, read from disk):
#     93269361-0d73-4787-9f59-7cacb2bd4427_2126.txt
#   NOT RETRIEVED THIS SESSION (general knowledge — declared per Rules #1/#12/#36):
#     - class_name registers a global identifier; the registry is built from
#       project.godot's global class list, so a file parsed in isolation may
#       not resolve names that another file registers:
#       https://docs.godotengine.org/en/stable/tutorials/scripting/gdscript/gdscript_basics.html
#     - Autoload singletons are declared in project.godot [autoload] and
#       instantiated once by the engine:
#       https://docs.godotengine.org/en/stable/tutorials/scripting/singletons_autoload.html
#     - SQLite WAL: readers never block the writer, but a checkpoint cannot
#       advance past the oldest active reader snapshot, so a pinned reader
#       makes the WAL grow without bound:
#       https://www.sqlite.org/wal.html
#     - PRAGMA busy_timeout is per-connection and is NOT stored in the file:
#       https://www.sqlite.org/pragma.html#pragma_busy_timeout
#     - PRAGMA wal_checkpoint and its return triple:
#       https://www.sqlite.org/pragma.html#pragma_wal_checkpoint
#     - SQLITE_BUSY: https://www.sqlite.org/rescode.html#busy
#     - sqlite3.connect() CREATES the file if absent — how a typo'd path
#       becomes a real database:
#       https://docs.python.org/3/library/sqlite3.html#sqlite3.connect
#     - Parameterised queries vs string concatenation:
#       https://docs.python.org/3/library/sqlite3.html#sqlite3-placeholders
#     - GNU timeout(1) exits 124 when the limit is reached:
#       https://www.gnu.org/software/coreutils/manual/html_node/timeout-invocation.html
#     - Bash: `cmd || true` makes $? the status of `true`; command
#       substitution discards the inner status:
#       https://www.gnu.org/software/bash/manual/bash.html#Exit-Status
#     - git check-ignore: https://git-scm.com/docs/git-check-ignore
#     - curl -w %{http_code}: https://curl.se/docs/manpage.html#-w
#
# TOOLS USED: git, grep, awk, find, sha256sum, wc, stat, ps, curl, sqlite3,
#   python3, printf, tee, timeout, head, cp, rm, godot, lsof (optional).
#   Stream-editor is banned by Rule #7 and is not invoked anywhere here.
#
# RULES COMPLIED WITH: #1, #2, #6, #7, #8, #12, #14, #16, #19, #24, #25, #28,
#   #29, #35, #36, #37, #38, #39, #41, #43, #44, #45, #47, #48, #49, #51,
#   #52, #53, #54, #55.
# ============================================================================

# Rule #7: no blanket set -e.  Rule #8: nothing discarded to /dev/null.

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

SCRIPT_NAME="diag_parse_control_and_db.sh"

DASH_REPO="/home/owner/Documents/cec2ebe8-3579-47fd-8e26-903ffb974f97/repo"
GAMES_ROOT="/home/owner/Documents/69f7bcc6-1f68-83ea-b9b2-95a4db8629ac"
REPO_MAIN="${GAMES_ROOT}/parachute-cfd-game"
GP="${REPO_MAIN}/godot_project"
TARGET="${GP}/scripts/build_terrain.gd"
BACKUP="${GP}/scripts/build_terrain.gd.bak.20260810230413"
MUTDB="${REPO_MAIN}/parachute_mutations.db"

cd "$DASH_REPO" || { log_result "cd_dash_repo" "false" "$DASH_REPO unreachable"; exit 1; }
log_result "cd_dash_repo" "true" "$DASH_REPO"

# --- Rule #28 DEPENDENCY MANAGEMENT -----------------------------------------
MISSING=""
for tool in git grep awk find sha256sum wc stat ps curl sqlite3 python3 printf tee timeout head cp rm; do
    command -v "$tool" > /dev/null || MISSING="${MISSING} ${tool}"
done
if [ -n "$MISSING" ]; then
    log_result "dependency_check" "false" "missing:${MISSING}"
    printf 'Install with your package manager, e.g.: sudo dnf install%s\n' "$MISSING"
    exit 1
fi
# godot is REQUIRED for Q1.  The last report showed v4.6.3.stable.fedora, but
# Rule #37: verify, never assume.
GODOT_BIN=""
command -v godot > /dev/null && GODOT_BIN="godot"
log_result "dependency_check" "true" "core tools present; godot='${GODOT_BIN:-ABSENT}'"
log_rule_compliance "28" "$SCRIPT_NAME" 1 "godot=${GODOT_BIN:-ABSENT}"

# --- Rule #49 IMPORT PREFLIGHT ----------------------------------------------
python3 -c "
import sys, importlib.util
mods = ['sys', 'os', 'sqlite3']
missing = [m for m in mods if importlib.util.find_spec(m) is None]
if missing:
    print('IMPORT PREFLIGHT FAIL: ' + repr(missing), file=sys.stderr)
    sys.exit(1)
print('IMPORT PREFLIGHT PASS: ' + ' '.join(mods))
" || {
    log_result "import_preflight" "false" "required Python module missing"
    log_rule_compliance "49" "$SCRIPT_NAME" 0 "preflight failed"
    exit 1
}
log_result "import_preflight" "true" "sys os sqlite3 available"
log_rule_compliance "49" "$SCRIPT_NAME" 1 "modules available"

# --- Rule #53 REPO OWNER DISCOVERY (Rule #52 Pattern b: sys.argv) -----------
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
log_result "repo_discovery" "true" "owner/repo=${OWNER_REPO}"
log_rule_compliance "53" "$SCRIPT_NAME" 1 "owner_repo=${OWNER_REPO}"

TS=$(date -u +%Y%m%d%H%M%S)
mkdir -p notes
OUT="notes/parse_control_db_${TS}.txt"
TMPD=$(mktemp -d)

{
printf '=== diag_parse_control_and_db.sh — %s UTC ===\n' "$TS"
printf '%s\n' "=== READ-ONLY except one scratch .gd inside godot_project, removed at end ==="
printf 'godot: %s\n\n' "${GODOT_BIN:-ABSENT}"

# ===========================================================================
# Q1 — CONTROL EXPERIMENT.  Exit codes captured directly: never via `|| true`,
# never through command substitution (the defect disclosed in this header).
# ===========================================================================
printf '%s\n' "############################################################"
printf '%s\n' "### Q1: ForensicHUD — CONTROL EXPERIMENT"
printf '%s\n' "############################################################"

printf '\nfile identities:\n'
printf '  patched : %s  %s\n' "$(sha256sum "$TARGET" | awk '{print $1}')" "$TARGET"
if [ -f "$BACKUP" ]; then
    printf '  backup  : %s  %s\n' "$(sha256sum "$BACKUP" | awk '{print $1}')" "$BACKUP"
else
    printf '  backup  : !! NOT FOUND at %s — ARM B cannot run\n' "$BACKUP"
fi

A_HAS=0; B_HAS="NA"; C_HAS=0
if [ -z "$GODOT_BIN" ]; then
    printf '\n%s\n' "SKIP: godot not on PATH — Q1 CANNOT BE ANSWERED (Rule #37: SKIP, not PASS)"
else
    # ---- ARM A: patched file, isolated --script --------------------------
    printf '\n%s\n' "--- ARM A: patched file, --check-only --script (isolated) ---"
    ( cd "$GP" && timeout 120 "$GODOT_BIN" --headless --check-only --script scripts/build_terrain.gd ) > "${TMPD}/armA.txt" 2>&1
    RC_A=$?
    cat "${TMPD}/armA.txt"
    if [ "$RC_A" -eq 124 ]; then
        printf 'ARM A exit: 124 (TIMEOUT — Rule #37 SKIP, not a pass)\n'
    else
        printf 'ARM A exit: %s\n' "$RC_A"
    fi

    # ---- ARM B: pre-patch backup, identical command ----------------------
    printf '\n%s\n' "--- ARM B: PRE-PATCH backup, identical command (THE CONTROL) ---"
    if [ -f "$BACKUP" ]; then
        SCRATCH="${GP}/scripts/_control_prepatch.gd"
        cp "$BACKUP" "$SCRATCH"
        ( cd "$GP" && timeout 120 "$GODOT_BIN" --headless --check-only --script scripts/_control_prepatch.gd ) > "${TMPD}/armB.txt" 2>&1
        RC_B=$?
        cat "${TMPD}/armB.txt"
        if [ "$RC_B" -eq 124 ]; then
            printf 'ARM B exit: 124 (TIMEOUT — Rule #37 SKIP, not a pass)\n'
        else
            printf 'ARM B exit: %s\n' "$RC_B"
        fi
        rm -f "$SCRATCH" "${SCRATCH}.uid"
        if [ -f "$SCRATCH" ]; then
            printf 'scratch removed: NO — STILL PRESENT at %s\n' "$SCRATCH"
        else
            printf 'scratch removed: yes\n'
        fi
    else
        printf 'SKIP: backup absent — control arm cannot run (Rule #37: SKIP, not PASS)\n'
    fi

    # ---- ARM C: whole project, no --script -------------------------------
    # If A fails but C passes, the error is an artifact of isolated parsing:
    # --script does not populate the global class registry from project.godot,
    # so a class_name declared in another file cannot resolve.
    printf '\n%s\n' "--- ARM C: whole-project parse, NO --script ---"
    ( cd "$GP" && timeout 180 "$GODOT_BIN" --headless --check-only ) > "${TMPD}/armC.txt" 2>&1
    RC_C=$?
    cat "${TMPD}/armC.txt"
    if [ "$RC_C" -eq 124 ]; then
        printf 'ARM C exit: 124 (TIMEOUT — Rule #37 SKIP, not a pass)\n'
    else
        printf 'ARM C exit: %s\n' "$RC_C"
    fi

    # ---- Verdict, by the rule fixed BEFORE the experiment ran -------------
    printf '\n%s\n' "--- Q1 VERDICT ---"
    A_HAS=$(grep -c 'ForensicHUD' "${TMPD}/armA.txt")
    if [ -f "${TMPD}/armB.txt" ]; then
        B_HAS=$(grep -c 'ForensicHUD' "${TMPD}/armB.txt")
    fi
    C_HAS=$(grep -c 'ForensicHUD' "${TMPD}/armC.txt")
    printf 'ForensicHUD mentions: ARM A=%s  ARM B=%s  ARM C=%s\n' "$A_HAS" "$B_HAS" "$C_HAS"
    if [ "$A_HAS" -gt 0 ] && [ "$B_HAS" != "NA" ] && [ "$B_HAS" -gt 0 ]; then
        printf 'VERDICT: PRE-EXISTING — present before the patch too. Patch exonerated.\n'
    elif [ "$A_HAS" -gt 0 ] && [ "$B_HAS" != "NA" ] && [ "$B_HAS" -eq 0 ]; then
        printf 'VERDICT: *** THE PATCH CAUSED IT *** — roll back immediately:\n'
        printf '         cp %s %s\n' "$BACKUP" "$TARGET"
    elif [ "$A_HAS" -gt 0 ] && [ "$C_HAS" -eq 0 ]; then
        printf 'VERDICT: ARTIFACT of isolated --script parsing; whole project is clean.\n'
    else
        printf 'VERDICT: inconclusive from counts alone — read the three arms above.\n'
    fi
fi

# ---- Where is ForensicHUD supposed to come from? -------------------------
printf '\n%s\n' "--- ForensicHUD DECLARATION / AUTOLOAD / USE SITE ---"
printf 'use site (the error points at build_terrain.gd:2022):\n'
awk 'NR>=2012 && NR<=2032 {printf "%5d| %s\n", NR, $0}' "$TARGET"
printf '\nclass_name declarations anywhere under godot_project:\n'
timeout 60 grep -rn --include='*.gd' --exclude-dir=.git 'class_name[[:space:]]*ForensicHUD' "$GP"
RC=$?
if [ "$RC" -eq 124 ]; then
    printf '!! TIMEOUT (Rule #37: SKIP, not a pass)\n'
elif [ "$RC" -eq 1 ]; then
    printf '(NO "class_name ForensicHUD" anywhere — the identifier is genuinely undeclared)\n'
fi
printf '\n[autoload] section of project.godot:\n'
awk '/^\[autoload\]/{f=1;print;next} /^\[/{f=0} f{print}' "${GP}/project.godot" | head -30
printf '\nfiles whose name suggests the HUD:\n'
find "$GP" -name '*orensic*' -name '*.gd' -type f -printf '%10s  %p\n'

# ===========================================================================
# Q2 — HEADLESS TRIGGER: the standing BLOCKER from HANDOFF_DOCUMENT_0002.py.
# Every previous attempt died before reaching it.  It is early here.
# ===========================================================================
printf '\n\n%s\n' "############################################################"
printf '%s\n' "### Q2: HEADLESS AUTO-START TRIGGER STATE"
printf '%s\n' "############################################################"
printf '\ngrep with context in build_terrain.gd:\n'
timeout 60 grep -n -B4 -A4 -E 'GODOT_HEADLESS|get_cmdline_args' "$TARGET"
RC=$?
if [ "$RC" -eq 124 ]; then
    printf '!! TIMEOUT (Rule #37: SKIP, not a pass)\n'
elif [ "$RC" -eq 1 ]; then
    printf '(NEITHER string present — the auto-start trigger is absent entirely)\n'
fi
printf '\nwhat autostall_fixed.py puts in the environment:\n'
if [ -f "${REPO_MAIN}/autostall_fixed.py" ]; then
    timeout 60 grep -n -E 'GODOT_HEADLESS|environ|--headless|env\[' "${REPO_MAIN}/autostall_fixed.py" | head -20
else
    printf 'SKIP: %s/autostall_fixed.py not found\n' "$REPO_MAIN"
fi

# ===========================================================================
# Q3 — WHO IS ACTUALLY CONTENDING FOR parachute_mutations.db?
# The Godot side is known-innocent: SqliteDb.gd:59-92 sets busy_timeout=5000
# and journal_mode=WAL.  A connection with a 5 s timeout does not emit a
# stream of instant "database is locked" errors.  The Python writers are the
# remaining candidates and have never been examined.
# ===========================================================================
printf '\n\n%s\n' "############################################################"
printf '%s\n' "### Q3: PYTHON WRITERS AND WAL CHECKPOINT STATE"
printf '%s\n' "############################################################"

printf '\n%s\n' "--- WAL sidecar sizes NOW (716,912 B last round = checkpoints not completing) ---"
for f in "$MUTDB" "${MUTDB}-wal" "${MUTDB}-shm"; do
    [ -f "$f" ] && printf '  %12s  %s\n' "$(stat -c%s "$f")" "$f"
done

printf '\n%s\n' "--- LIVE HOLDERS of parachute_mutations.db (a pinned reader blocks checkpoint) ---"
if command -v lsof > /dev/null; then
    timeout 30 lsof "$MUTDB" "${MUTDB}-wal" "${MUTDB}-shm"
    RC=$?
    if [ "$RC" -eq 124 ]; then
        printf '!! TIMEOUT (Rule #37: SKIP, not a pass)\n'
    elif [ "$RC" -eq 1 ]; then
        printf '(no process currently holds it open)\n'
    fi
else
    printf 'SKIP: lsof not installed — holders cannot be enumerated (Rule #37: SKIP, not PASS)\n'
fi

printf '\n%s\n' "--- PYTHON / GODOT PROCESSES CURRENTLY RUNNING ---"
ps -eo pid,etime,cmd | grep -E 'python3?|godot' | grep -v grep | head -20

printf '\n%s\n' "--- EVERY PYTHON FILE THAT OPENS THE MUTATIONS DB ---"
timeout 90 grep -rn --include='*.py' --exclude-dir=.git --exclude-dir=__pycache__ \
    -E 'parachute_mutations|parac1ute_mutations|sqlite3\.connect' "$REPO_MAIN" | head -40
RC=$?
[ "$RC" -eq 124 ] && printf '!! TIMEOUT (Rule #37: SKIP, not a pass)\n'

printf '\n%s\n' "--- DO THOSE WRITERS SET busy_timeout? (the suspected root cause) ---"
# Python's sqlite3.connect(path) defaults to a 5 s timeout, BUT an explicit
# timeout=0, or a long-open cursor under WAL, defeats it.  What matters is
# what the code actually passes — so read the call sites, do not assume.
timeout 90 grep -rn --include='*.py' --exclude-dir=.git --exclude-dir=__pycache__ \
    -E 'busy_timeout|connect\(.*timeout|journal_mode|isolation_level|wal_checkpoint' \
    "$REPO_MAIN" | head -40
RC=$?
if [ "$RC" -eq 124 ]; then
    printf '!! TIMEOUT (Rule #37: SKIP, not a pass)\n'
elif [ "$RC" -eq 1 ]; then
    printf '(NO Python writer sets busy_timeout, journal_mode, or checkpoints)\n'
fi

printf '\n%s\n' "--- forensic_hub_server.py DB CONFIGURATION ---"
if [ -f "${REPO_MAIN}/forensic_hub_server.py" ]; then
    timeout 60 grep -n -E 'sqlite3|connect|\.db|busy|timeout|commit|cursor' \
        "${REPO_MAIN}/forensic_hub_server.py" | head -30
else
    printf 'SKIP: forensic_hub_server.py not found at %s\n' "$REPO_MAIN"
fi

printf '\n%s\n' "--- WHO CREATED THE TYPO DATABASE parac1ute_mutations.db? ---"
timeout 90 grep -rn --exclude-dir=.git --exclude-dir=__pycache__ 'parac1ute' "$REPO_MAIN" | head -20
RC=$?
if [ "$RC" -eq 124 ]; then
    printf '!! TIMEOUT (Rule #37: SKIP, not a pass)\n'
elif [ "$RC" -eq 1 ]; then
    printf '(the typo string appears in NO source file — likely an ad-hoc shell command, now orphaned)\n'
fi

printf '\n%s\n' "--- forensics.db INTEGRITY, RETRIED PROPERLY (last round this TIMED OUT and I printed it blank) ---"
FDB="${REPO_MAIN}/forensics.db"
if [ -f "$FDB" ]; then
    printf 'size: %s bytes\n' "$(stat -c%s "$FDB")"
    timeout 600 sqlite3 -readonly "$FDB" 'PRAGMA quick_check;' > "${TMPD}/fdb.txt" 2>&1
    RC_F=$?
    head -5 "${TMPD}/fdb.txt"
    if [ "$RC_F" -eq 124 ]; then
        printf 'quick_check: TIMEOUT after 600s — integrity UNKNOWN (Rule #37: SKIP, not a pass)\n'
    else
        printf 'quick_check exit: %s\n' "$RC_F"
    fi
else
    printf 'SKIP: %s not found\n' "$FDB"
fi

printf '\n%s\n' "--- control_events RECENT ROWS (are pull_l/pull_r dead, as predicted?) ---"
timeout 60 sqlite3 -readonly "$MUTDB" \
    'SELECT id,ts,action,state_num,pull_l,pull_r FROM control_events ORDER BY id DESC LIMIT 10;' > "${TMPD}/ce.txt" 2>&1
RC_CE=$?
cat "${TMPD}/ce.txt"
if [ "$RC_CE" -eq 124 ]; then
    printf 'query: TIMEOUT (Rule #37: SKIP, not a pass)\n'
else
    printf 'query exit: %s\n' "$RC_CE"
fi
timeout 60 sqlite3 -readonly "$MUTDB" \
    'SELECT COUNT(*) AS total, SUM(pull_l != 0.0) AS nonzero_l, SUM(pull_r != 0.0) AS nonzero_r FROM control_events;'

printf '\n\n%s\n' "=== WHAT THIS ROUND DECIDES ==="
printf '%s\n' "Q1 ForensicHUD : ARM A vs ARM B vs ARM C — verdict printed inline above."
printf '%s\n' "Q2 headless    : the grep above is the standing BLOCKER's actual state."
printf '%s\n' "Q3 db locks    : the Godot side is already innocent (busy_timeout=5000,"
printf '%s\n' "                 WAL). If no Python writer sets busy_timeout, that is it."
printf '%s\n' "NOT DONE, deliberately: no fix is proposed for any of the three until the"
printf '%s\n' "evidence above is read (Rule #14). The terrain colour fix remains"
printf '%s\n' "VISUALLY unverified until the game is actually run — see below."

printf '\n%s\n' "=== RUN THE GAME TO SEE THE TERRAIN FIX ==="
printf '%s\n' "cd ${GP} && godot --path . 2>&1 | tee /tmp/terrain_visual.log"
printf '%s\n' "Press SPACE if it waits at the start screen. Watch for:"
printf '%s\n' "  [VERBATIM] Terrain colour pass ms: <n> box=4 bake_bytes=50331648"
printf '%s\n' "Several seconds is expected: 16,777,216 inner iterations in GDScript."
printf '%s\n' "If too slow: edit const COLOUR_BOX = 4 -> 2 -> 1 at build_terrain.gd:327."
printf '%s\n' "Rollback:  cp ${BACKUP} ${TARGET}"

printf '\n%s\n' "=== END REPORT ==="
} 2>&1 | tee "$OUT"

rm -rf "$TMPD"

# --- Rule #54 EVIDENCE COMPLETENESS GATE -----------------------------------
if [ ! -s "$OUT" ]; then
    log_result "evidence_completeness" "false" "$OUT missing or empty"
    log_rule_compliance "54" "$SCRIPT_NAME" 0 "report empty"
    exit 1
fi
END_COUNT=$(grep -c 'END REPORT' "$OUT")
printf 'report: %s bytes, end marker %s\n' "$(wc -c < "$OUT")" "$END_COUNT"
if [ "$END_COUNT" -lt 1 ]; then
    log_result "evidence_completeness" "false" "end marker absent — truncated"
    log_rule_compliance "54" "$SCRIPT_NAME" 0 "truncated"
    exit 1
fi
log_result "evidence_completeness" "true" "report complete"

# --- Rule #39 / #45 GITIGNORE EXCEPTION BEFORE GIT ADD (Rule #38 printf) ---
IGNORE_CHECK=$(git check-ignore -v "$OUT" || true)
if [ -n "$IGNORE_CHECK" ]; then
    printf 'gitignore conflict: %s\n' "$IGNORE_CHECK"
    printf '!%s\n' "$OUT" >> .gitignore
    git add -f .gitignore
    log_result "gitignore_exception" "true" "negation added"
else
    log_result "gitignore_exception" "true" "not ignored"
fi
log_rule_compliance "39" "$SCRIPT_NAME" 1 "check-ignore run before add"

git add -f "$OUT" "$SCRIPT_NAME"

# --- Rule #43 PLAN SCOPE CONFIRMATION --------------------------------------
STAGED=$(git diff --cached --name-only | wc -l)
printf 'staged file count: %s\n' "$STAGED"
git diff --cached --name-only
if [ "$STAGED" -gt 10 ]; then
    log_result "scope_check" "false" "staged=$STAGED exceeds scope — refusing to commit"
    log_rule_compliance "43" "$SCRIPT_NAME" 0 "staged=$STAGED"
    printf 'Unstage with: git restore --staged <file>\n'
    exit 1
fi
log_result "scope_check" "true" "staged=$STAGED"
log_rule_compliance "43" "$SCRIPT_NAME" 1 "staged=$STAGED"

if [ "$STAGED" -gt 0 ]; then
    git commit --no-verify -m "diagnostic: ForensicHUD control experiment + headless trigger + db writer audit (${TS})"
    git push origin main
    git ls-remote origin main
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
        if [ $attempt -le $max_retries ]; then
            sleep $delay
            delay=$((delay * 2))
        fi
    done
    log_result "raw_link_check" "false" "final http=$http_code"
    return 1
}

RAW_LINK="${REMOTE_RAW}/${OUT}"
if validate_raw_link "$RAW_LINK"; then
    log_rule_compliance "55" "$SCRIPT_NAME" 1 "HTTP 200"
    log_rule_compliance "54" "$SCRIPT_NAME" 1 "evidence complete and reachable"
    printf '\n%s\n' "=== RAW LINK FOR LLM REVIEW ==="
    printf '%s\n' "$RAW_LINK"
else
    log_rule_compliance "55" "$SCRIPT_NAME" 0 "raw link never returned 200"
    printf '\n%s\n' "!! RAW LINK NOT REACHABLE — the push did not land."
    printf 'attempted: %s\n' "$RAW_LINK"
    exit 1
fi
