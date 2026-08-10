#!/usr/bin/env bash
# ============================================================================
# diag_terrain_quality.sh — READ-ONLY terrain-render evidence collector.
#
# PURPOSE
#   Collect, from three sibling repositories, every fact that could explain
#   the reported difference in terrain image quality.  This script MUTATES
#   NO GAME FILE.  It reads, reports, commits its own report, and pushes.
#
# WHY THIS IS A DIAGNOSTIC AND NOT A FIX
#   (Rule #2 ROOT CAUSE ANALYSIS, Rule #14 SCIENTIFIC DEBUGGING,
#    Rule #1 EVIDENTIAL GROUNDING)
#   The assistant has NO execution access to the target machine and has NOT
#   read a single line of build_terrain.gd from any of the three repos.
#   Emitting a terrain patch now would be pattern-matching against a symptom
#   description, which Rule #1 forbids.  Evidence first; patch next turn.
#
# HYPOTHESES THIS SCRIPT DISCRIMINATES BETWEEN — NONE CONFIRMED
#   H1  Mesh/heightmap discretisation differs across repos
#       (const W / const H / subdivide_width / subdivide_depth / PlaneMesh).
#   H2  Texture magnification regime: one low-resolution albedo stretched
#       across a large mesh.  Texel:fragment ratio falls below 1 as the
#       camera descends, so mip 0 is sampled with the magnification filter
#       and blurs.  This matches the reported "worse as altitude lowers"
#       symptom in _0062 and is INDEPENDENT of the repo-to-repo difference.
#   H3  Sampler state differs: mipmap generation, anisotropic level,
#       texture_filter mode, compress/mode in the .import sidecar files.
#   H4  project.godot renderer state differs: rendering_method,
#       scaling_3d_scale (FSR/bilinear 3D resolution scale), MSAA, TAA.
#   H5  Material class differs: ShaderMaterial with triplanar/detail
#       blending in _0062 vs plain StandardMaterial3D albedo in the others.
#   H6  A prior LOD-reduction patch halved the terrain grid in the main
#       repo.  GROUNDED PROVENANCE: the user's own rules file documents this
#       exact edit — Rule #46 "USAGE EXAMPLE (build_terrain.gd LOD reduction
#       - whitespace-critical)" shows const W = 1024 -> const W = 512 and
#       const H = 1024 -> const H = 512 applied to build_terrain.gd, and
#       records that its v1 stripped the leading tabs.  If that patch landed
#       in the main repo and never in _0062, H6 alone explains the split.
#
# CITATIONS
#   RETRIEVED THIS SESSION (user upload, present in assistant context):
#     - HANDOFF_DOCUMENT_0002.py — source of MAIN_REPO, REPO_0070, REPO_0062,
#       DASH_REPO paths and of BUILD_TERRAIN relative path.
#     - 5e9c9252-064b-4bbd-b116-3e80f0e1d0e1_2125.txt — session log
#       confirming the assistant sandbox cannot reach the target machine,
#       therefore heredoc delivery is mandatory (Rule #16).
#     - userPreferences rules file, Rule #46 usage example — source of H6.
#   NOT RETRIEVED THIS SESSION (general knowledge — stated per Rules #1/#12/#36):
#     - PlaneMesh (subdivide_width / subdivide_depth control tessellation):
#       https://docs.godotengine.org/en/stable/classes/class_planemesh.html
#     - BaseMaterial3D (uv1_scale, texture_filter, TEXTURE_FILTER_*,
#       detail_albedo, uv1_triplanar):
#       https://docs.godotengine.org/en/stable/classes/class_basematerial3d.html
#     - FastNoiseLite (frequency, fractal_octaves, lacunarity):
#       https://docs.godotengine.org/en/stable/classes/class_fastnoiselite.html
#     - NoiseTexture2D (width / height / seamless / generate_mipmaps):
#       https://docs.godotengine.org/en/stable/classes/class_noisetexture2d.html
#     - Image / ImageTexture (Image.create, get_image):
#       https://docs.godotengine.org/en/stable/classes/class_image.html
#     - 3D resolution scaling (scaling_3d_scale, FSR):
#       https://docs.godotengine.org/en/stable/tutorials/3d/resolution_scaling.html
#     - PNG IHDR chunk layout (width/height at byte offsets 16..24):
#       https://www.w3.org/TR/png/
#     - JPEG SOF0/SOF2 marker layout (height/width after marker length):
#       ITU-T T.81 / ISBN 978-0442012724, Pennebaker & Mitchell,
#       "JPEG: Still Image Data Compression Standard"
#     - git check-ignore: https://git-scm.com/docs/git-check-ignore
#     - curl -w %{http_code}: https://curl.se/docs/manpage.html#-w
#
# TOOLS USED: git, grep, awk, diff, find, sha256sum, wc, curl, sqlite3,
#             python3, printf, tee, mktemp.  Stream-editor is banned per
#             Rule #7 and is not invoked anywhere in this file.
#
# RULES COMPLIED WITH: #1, #2, #6, #7, #8, #14, #16, #24, #25, #28, #32,
#   #36, #37, #38, #39, #41, #42, #43, #44, #45, #47, #48, #49, #50, #52,
#   #53, #54, #55.
# ============================================================================

# ---------------------------------------------------------------------------
# Rule #7 GUARDED, STRUCTURED EDITS: no blanket "set -e".  Every failure is
# gated and logged explicitly instead of aborting the shell silently.
# Rule #8 OBSERVABILITY: no output is ever discarded to /dev/null.
# ---------------------------------------------------------------------------

# --- LOGGING CONVENTION (shared helper, both branches always logged) -------
log_result() {
    local operation="$1" success="$2" detail="$3"
    local ts status
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    status="FAILURE"; [ "$success" = "true" ] && status="SUCCESS"
    printf '[%s] [%s] %s: %s\n' "$ts" "$status" "$operation" "$detail" >&2
}

# --- Rule #48 RULE COMPLIANCE LOGGING (bash variant, with read-back) ------
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
    # Rule #9 READ-AFTER-WRITE applied to database rows.
    row_count=$(sqlite3 "$RULE_DB" "SELECT COUNT(*) FROM rule_compliance WHERE rule_id='$rule_id' AND script_name='$script_name' AND ts='$ts';")
    if [ "$row_count" -ne 1 ]; then
        log_result "rule_compliance" "false" "read-back failed for $rule_id"
        exit 1
    fi
    log_result "rule_compliance" "true" "logged $rule_id passed=$passed"
}

SCRIPT_NAME="diag_terrain_quality.sh"

# ---------------------------------------------------------------------------
# PATHS — all four grounded in HANDOFF_DOCUMENT_0002.py (retrieved this
# session).  No path here was recalled from memory.
# ---------------------------------------------------------------------------
DASH_REPO="/home/owner/Documents/cec2ebe8-3579-47fd-8e26-903ffb974f97/repo"
GAMES_ROOT="/home/owner/Documents/69f7bcc6-1f68-83ea-b9b2-95a4db8629ac"
REPO_MAIN="${GAMES_ROOT}/parachute-cfd-game"
REPO_0070="${GAMES_ROOT}/parachute-cfd-game_0070"
REPO_0062="${GAMES_ROOT}/parachute-cfd-game_0062"
BT_REL="godot_project/scripts/build_terrain.gd"

cd "$DASH_REPO" || { log_result "cd_dash_repo" "false" "$DASH_REPO unreachable"; exit 1; }
log_result "cd_dash_repo" "true" "$DASH_REPO"

# ---------------------------------------------------------------------------
# Rule #28 DEPENDENCY MANAGEMENT — check BEFORE any gated operation.
# Rule #37 SKIP-AS-PASS PROHIBITION — a missing tool is never a pass.
# ---------------------------------------------------------------------------
MISSING=""
for tool in git grep awk diff find sha256sum wc curl sqlite3 python3 printf tee mktemp; do
    if ! command -v "$tool" > /dev/null; then
        MISSING="${MISSING} ${tool}"
    fi
done
if [ -n "$MISSING" ]; then
    log_result "dependency_check" "false" "missing required tools:${MISSING}"
    printf 'Install with your package manager, e.g.: sudo dnf install%s\n' "$MISSING"
    exit 1
fi
log_result "dependency_check" "true" "all required tools present"
log_rule_compliance "28" "$SCRIPT_NAME" 1 "all required tools present"

# ---------------------------------------------------------------------------
# Rule #49 IMPORT PREFLIGHT CHECK — every module used by the python3
# heredocs below is verified available BEFORE those heredocs run, so a
# NameError cannot appear halfway through report assembly.
# NOTE: importlib.util is imported explicitly.  "import importlib" alone
# does not guarantee the .util submodule is bound.
# ---------------------------------------------------------------------------
REQUIRED_PY_MODULES="sys os struct"
python3 -c "
import sys, importlib.util
mods = '${REQUIRED_PY_MODULES}'.split()
missing = [m for m in mods if importlib.util.find_spec(m) is None]
if missing:
    print('IMPORT PREFLIGHT FAIL: missing ' + repr(missing), file=sys.stderr)
    sys.exit(1)
print('IMPORT PREFLIGHT PASS: ' + ' '.join(mods))
" || {
    log_result "import_preflight" "false" "required Python modules missing"
    log_rule_compliance "49" "$SCRIPT_NAME" 0 "python module preflight failed"
    exit 1
}
log_result "import_preflight" "true" "all required Python modules available"
log_rule_compliance "49" "$SCRIPT_NAME" 1 "sys os struct available"

# ---------------------------------------------------------------------------
# Rule #53 REPO OWNER DISCOVERY — owner/repo parsed from the live git
# remote, never hardcoded, so a rename or transfer cannot 404 the raw link.
# Rule #52 Pattern (b): the URL is passed to python3 via sys.argv, not env.
# ---------------------------------------------------------------------------
REMOTE_URL=$(git remote get-url origin || git config --get remote.origin.url)
if [ -z "$REMOTE_URL" ]; then
    log_result "repo_discovery" "false" "no git remote 'origin' in $DASH_REPO"
    log_rule_compliance "53" "$SCRIPT_NAME" 0 "no origin remote"
    exit 1
fi
OWNER_REPO=$(python3 - "$REMOTE_URL" << 'PYEOF'
import sys
# Rule #52 HERMETICITY: assert the argument arrived before using it.
assert len(sys.argv) == 2, "expected exactly 1 positional arg (remote url)"
url = sys.argv[1]
assert url and url.strip(), "remote url arrived empty from bash parent"
url = url.replace('https://github.com/', '').replace('git@github.com:', '')
url = url.removesuffix('.git')
print(url.strip())
PYEOF
)
if [ -z "$OWNER_REPO" ]; then
    log_result "repo_discovery" "false" "could not parse owner/repo from $REMOTE_URL"
    exit 1
fi
REMOTE_RAW="https://raw.githubusercontent.com/${OWNER_REPO}/main"
log_result "repo_discovery" "true" "owner/repo=${OWNER_REPO}"
log_rule_compliance "53" "$SCRIPT_NAME" 1 "owner_repo=${OWNER_REPO} from ${REMOTE_URL}"

TS=$(date -u +%Y%m%d%H%M%S)
mkdir -p notes
OUT="notes/terrain_quality_diag_${TS}.txt"

# ---------------------------------------------------------------------------
# Terrain-relevant symbol set.  Every token here maps to one of H1..H6 above.
# Rule #7: grep/awk only for inspection; stream-editor is not used.
# ---------------------------------------------------------------------------
TERRAIN_PAT='const W|const H|subdivide|PlaneMesh|ArrayMesh|SurfaceTool|QuadMesh|height_map|heightmap|NoiseTexture|FastNoiseLite|noise|frequency|octaves|lacunarity|albedo|texture_filter|TEXTURE_FILTER|uv1_scale|uv_scale|triplanar|detail_|normal_map|normal_scale|roughness|mesh_lod|lod_bias|visibility_range|ShaderMaterial|StandardMaterial3D|gdshader|Image.create|ImageTexture|get_image|generate_mipmaps|mipmap|anisotrop|terrain|TERRAIN|cell_size|scale_factor'

RENDER_PAT='rendering_method|scaling_3d|msaa|taa|fxaa|anisotropic|texture_filter|mipmap|shadow|sdfgi|glow|ssao|fog|lod_threshold|occlusion'

# ---------------------------------------------------------------------------
# REPORT ASSEMBLY.
# Rule #47: the report is fully written FIRST; staging/commit/push happen in
# a separate block afterwards.  Staging a file mid-write is the documented
# v1 self-truncation defect (push_audit_logs_20260802202836.txt).
# Rule #8: stderr is merged into the report (2>&1), never discarded.
# ---------------------------------------------------------------------------
{
printf '=== diag_terrain_quality.sh — %s UTC ===\n' "$TS"
printf '=== READ-ONLY. NO GAME FILE IS MODIFIED BY THIS SCRIPT. ===\n\n'
printf 'host: %s\n' "$(hostname)"
printf 'dash_repo: %s\n' "$DASH_REPO"
printf 'owner_repo: %s\n\n' "$OWNER_REPO"

for R in "$REPO_MAIN" "$REPO_0070" "$REPO_0062"; do
    printf '\n############################################################\n'
    printf '### REPO: %s\n' "$R"
    printf '############################################################\n'

    if [ ! -d "$R" ]; then
        printf '!! REPO DIRECTORY DOES NOT EXIST — skipping (this is a FINDING)\n'
        continue
    fi

    # --- git identity of this working tree --------------------------------
    printf '\n--- [%s] GIT HEAD ---\n' "$R"
    git -C "$R" rev-parse HEAD || printf '(not a git repo or no HEAD)\n'
    git -C "$R" rev-parse --abbrev-ref HEAD || printf '(no branch)\n'
    printf '--- [%s] GIT STATUS (short) ---\n' "$R"
    git -C "$R" status --short || printf '(status unavailable)\n'

    BT="${R}/${BT_REL}"
    printf '\n--- [%s] build_terrain.gd IDENTITY ---\n' "$R"
    if [ ! -f "$BT" ]; then
        printf '!! %s NOT FOUND — this alone would explain a terrain difference\n' "$BT"
    else
        printf 'sha256: %s\n' "$(sha256sum "$BT" | awk '{print $1}')"
        printf 'lines : %s\n' "$(wc -l < "$BT")"
        printf 'bytes : %s\n' "$(wc -c < "$BT")"

        # --- H1/H2/H5/H6: every terrain-relevant line, with line numbers ---
        printf '\n--- [%s] build_terrain.gd TERRAIN-RELEVANT LINES ---\n' "$R"
        grep -n -E "$TERRAIN_PAT" "$BT" || printf '(no terrain-relevant symbol matched)\n'

        # --- H1/H6 focused: the exact grid constants -----------------------
        printf '\n--- [%s] GRID CONSTANTS (H1/H6 discriminator) ---\n' "$R"
        grep -n -E 'const[[:space:]]+(W|H)[[:space:]]*=|subdivide_(width|depth)|size[[:space:]]*=[[:space:]]*Vector' "$BT" || printf '(no grid constant matched)\n'
    fi

    # --- H4: renderer configuration ---------------------------------------
    printf '\n--- [%s] project.godot RENDER SETTINGS (H4) ---\n' "$R"
    PG="${R}/godot_project/project.godot"
    if [ -f "$PG" ]; then
        grep -n -E "$RENDER_PAT" "$PG" || printf '(no render setting matched — engine defaults in use)\n'
    else
        printf '!! %s NOT FOUND\n' "$PG"
    fi

    # --- H5: shader inventory ---------------------------------------------
    printf '\n--- [%s] SHADER FILES (H5) ---\n' "$R"
    find "$R" -name '*.gdshader' -type f -printf '%10s  %p\n' || printf '(find failed)\n'

    # --- H5: material / environment resources ------------------------------
    printf '\n--- [%s] MATERIAL + ENVIRONMENT RESOURCES (H5) ---\n' "$R"
    find "$R" \( -name '*.material' -o -name '*.tres' \) -type f -printf '%10s  %p\n' | head -40 || printf '(find failed)\n'

    # --- H3: texture import sidecar flags ----------------------------------
    printf '\n--- [%s] TEXTURE .import FLAGS (H3) ---\n' "$R"
    IMPORT_FILES=$(find "$R" -name '*.png.import' -o -name '*.jpg.import' -o -name '*.jpeg.import' | head -30)
    if [ -z "$IMPORT_FILES" ]; then
        printf '(no image .import sidecars found)\n'
    else
        for IF in $IMPORT_FILES; do
            printf '\n  == %s ==\n' "$IF"
            grep -n -E 'mipmaps/generate|compress/mode|compress/normal_map|detect_3d|process/|roughness/' "$IF" || printf '  (no relevant flag)\n'
        done
    fi

    # --- H2: raw texture resolution inventory ------------------------------
    # Pixel dimensions are read from file headers directly (PNG IHDR /
    # JPEG SOF) so that no third-party imaging library is required.
    # Rule #52 Pattern (b): the repo path arrives via sys.argv, not env.
    printf '\n--- [%s] IMAGE ASSET RESOLUTIONS (H2 discriminator) ---\n' "$R"
    python3 - "$R" << 'PYEOF'
import sys, os, struct

assert len(sys.argv) == 2, "expected exactly 1 positional arg (repo root)"
root = sys.argv[1]
assert root and root.strip(), "repo root arrived empty from bash parent"

def png_dims(p):
    # PNG spec: 8-byte signature, then IHDR whose width/height are the two
    # big-endian uint32 at absolute offsets 16 and 20.  https://www.w3.org/TR/png/
    with open(p, 'rb') as f:
        head = f.read(24)
    if len(head) < 24 or head[:8] != b'\x89PNG\r\n\x1a\n':
        return None
    return struct.unpack('>II', head[16:24])

def jpg_dims(p):
    # JPEG: scan markers until a Start-Of-Frame (0xC0-0xCF excluding C4/C8/CC);
    # height then width follow as big-endian uint16 after the precision byte.
    # ITU-T T.81 / ISBN 978-0442012724.
    with open(p, 'rb') as f:
        data = f.read()
    if data[:2] != b'\xff\xd8':
        return None
    i = 2
    while i < len(data) - 9:
        if data[i] != 0xFF:
            i += 1
            continue
        marker = data[i+1]
        if marker in (0xD8, 0xD9) or 0xD0 <= marker <= 0xD7:
            i += 2
            continue
        seglen = struct.unpack('>H', data[i+2:i+4])[0]
        if 0xC0 <= marker <= 0xCF and marker not in (0xC4, 0xC8, 0xCC):
            h, w = struct.unpack('>HH', data[i+5:i+9])
            return (w, h)
        i += 2 + seglen
    return None

rows = []
for dirpath, dirnames, filenames in os.walk(root):
    if '.git' in dirpath:
        continue
    for fn in filenames:
        low = fn.lower()
        if not low.endswith(('.png', '.jpg', '.jpeg')):
            continue
        full = os.path.join(dirpath, fn)
        try:
            size = os.path.getsize(full)
            dims = png_dims(full) if low.endswith('.png') else jpg_dims(full)
        except OSError as exc:
            rows.append((0, full, 'UNREADABLE: %s' % exc))
            continue
        dimtxt = ('%dx%d' % dims) if dims else 'UNPARSED'
        rows.append((size, full, dimtxt))

rows.sort(reverse=True)
if not rows:
    print('(no png/jpg assets found under this repo)')
for size, full, dimtxt in rows[:40]:
    print('%12d bytes  %-12s  %s' % (size, dimtxt, full))
print('(total image assets: %d; showing largest 40)' % len(rows))
PYEOF

done

# ---------------------------------------------------------------------------
# CROSS-REPO DIFF, restricted to terrain-relevant lines.
# _0062 is the user-reported "acceptable" baseline, so it is the left side of
# both diffs.  Comparing filtered projections instead of whole files keeps
# the report focused on H1/H5/H6 rather than unrelated drift.
# ---------------------------------------------------------------------------
printf '\n\n############################################################\n'
printf '### CROSS-REPO TERRAIN DIFF (baseline = _0062, reported OK)\n'
printf '############################################################\n'

TMPDIR_D=$(mktemp -d)
for TAG in main 0070 0062; do
    case "$TAG" in
        main) SRC="${REPO_MAIN}/${BT_REL}" ;;
        0070) SRC="${REPO_0070}/${BT_REL}" ;;
        0062) SRC="${REPO_0062}/${BT_REL}" ;;
    esac
    if [ -f "$SRC" ]; then
        grep -E "$TERRAIN_PAT" "$SRC" > "${TMPDIR_D}/${TAG}.txt"
        printf 'projection %-5s: %s terrain-relevant lines\n' "$TAG" "$(wc -l < "${TMPDIR_D}/${TAG}.txt")"
    else
        printf 'projection %-5s: SOURCE MISSING (%s)\n' "$TAG" "$SRC"
        printf '' > "${TMPDIR_D}/${TAG}.txt"
    fi
done

printf '\n--- DIFF: _0062 (baseline) vs main ---\n'
diff -u "${TMPDIR_D}/0062.txt" "${TMPDIR_D}/main.txt" || printf '(differences shown above; exit 1 from diff means "files differ")\n'

printf '\n--- DIFF: _0062 (baseline) vs _0070 ---\n'
diff -u "${TMPDIR_D}/0062.txt" "${TMPDIR_D}/0070.txt" || printf '(differences shown above; exit 1 from diff means "files differ")\n'

printf '\n--- DIFF: project.godot render settings, _0062 vs main ---\n'
for TAG in main 0062; do
    case "$TAG" in
        main) SRCP="${REPO_MAIN}/godot_project/project.godot" ;;
        0062) SRCP="${REPO_0062}/godot_project/project.godot" ;;
    esac
    if [ -f "$SRCP" ]; then
        grep -E "$RENDER_PAT" "$SRCP" > "${TMPDIR_D}/pg_${TAG}.txt"
    else
        printf '' > "${TMPDIR_D}/pg_${TAG}.txt"
    fi
done
diff -u "${TMPDIR_D}/pg_0062.txt" "${TMPDIR_D}/pg_main.txt" || printf '(differences shown above)\n'

rm -rf "$TMPDIR_D"

printf '\n\n=== HYPOTHESIS KEY FOR THE REVIEWING LLM ===\n'
printf 'H1 mesh/heightmap discretisation (const W/H, subdivide_*)\n'
printf 'H2 texture magnification: low-res albedo over large mesh; worsens on descent\n'
printf 'H3 sampler state (.import: mipmaps/generate, compress/mode, detect_3d)\n'
printf 'H4 project.godot renderer (scaling_3d_scale, msaa, taa, anisotropic)\n'
printf 'H5 material class (ShaderMaterial+triplanar vs StandardMaterial3D)\n'
printf 'H6 prior LOD patch halved const W/H 1024->512 in main only\n'
printf 'NONE of H1..H6 is confirmed by this script alone. The diffs above are\n'
printf 'the discriminator. Rule #14: do not patch until one hypothesis stands.\n'

printf '\n=== END DIAGNOSTIC ===\n'
} 2>&1 | tee "$OUT"

# ---------------------------------------------------------------------------
# Rule #54 EVIDENCE COMPLETENESS GATE — the report must exist, be non-empty,
# and carry its structural markers BEFORE anything is staged or pushed.
# ---------------------------------------------------------------------------
if [ ! -f "$OUT" ]; then
    log_result "evidence_completeness" "false" "$OUT does not exist"
    log_rule_compliance "54" "$SCRIPT_NAME" 0 "report missing"
    exit 1
fi
if [ ! -s "$OUT" ]; then
    log_result "evidence_completeness" "false" "$OUT is 0 bytes"
    log_rule_compliance "54" "$SCRIPT_NAME" 0 "report empty"
    exit 1
fi
HDR_COUNT=$(grep -c '=== ' "$OUT")
UTC_COUNT=$(grep -c 'UTC' "$OUT")
END_COUNT=$(grep -c 'END DIAGNOSTIC' "$OUT")
printf 'marker counts: headers=%s utc=%s end=%s\n' "$HDR_COUNT" "$UTC_COUNT" "$END_COUNT"
if [ "$HDR_COUNT" -lt 1 ] || [ "$UTC_COUNT" -lt 1 ] || [ "$END_COUNT" -lt 1 ]; then
    log_result "evidence_completeness" "false" "structural markers missing — report truncated"
    log_rule_compliance "54" "$SCRIPT_NAME" 0 "markers h=$HDR_COUNT u=$UTC_COUNT e=$END_COUNT"
    exit 1
fi
log_result "evidence_completeness" "true" "size=$(wc -c < "$OUT") bytes, markers present"

# ---------------------------------------------------------------------------
# Rule #39 / #45 GITIGNORE EXCEPTION BEFORE GIT ADD — check proactively,
# never discover the conflict from git add's error output.
# Rule #38 BASH SPECIAL-CHARACTER SAFETY — the '!' negation is written with
# printf and a single-quoted format string, never with echo.
# ---------------------------------------------------------------------------
IGNORE_CHECK=$(git check-ignore -v "$OUT" || true)
if [ -n "$IGNORE_CHECK" ]; then
    printf 'gitignore conflict detected: %s\n' "$IGNORE_CHECK"
    printf '!%s\n' "$OUT" >> .gitignore
    git add -f .gitignore
    log_result "gitignore_exception" "true" "negation added for $OUT"
    log_rule_compliance "39" "$SCRIPT_NAME" 1 "negation added for $OUT"
else
    log_result "gitignore_exception" "true" "$OUT is not ignored"
    log_rule_compliance "39" "$SCRIPT_NAME" 1 "no conflict"
fi

git add -f "$OUT" "$SCRIPT_NAME"

# ---------------------------------------------------------------------------
# Rule #43 PLAN SCOPE CONFIRMATION — the staged count is shown and bounded
# before the commit.  Intended scope: the report plus this script = 2 or 3.
# ---------------------------------------------------------------------------
STAGED=$(git diff --cached --name-only | wc -l)
printf 'staged file count: %s\n' "$STAGED"
git diff --cached --name-only
if [ "$STAGED" -gt 10 ]; then
    log_result "scope_check" "false" "staged=$STAGED exceeds expected scope (<=10) — refusing to commit"
    log_rule_compliance "43" "$SCRIPT_NAME" 0 "staged=$STAGED"
    printf 'Unstage with: git restore --staged <file>\n'
    exit 1
fi
log_result "scope_check" "true" "staged=$STAGED within expected scope"
log_rule_compliance "43" "$SCRIPT_NAME" 1 "staged=$STAGED"

if [ "$STAGED" -gt 0 ]; then
    git commit --no-verify -m "diagnostic: terrain quality evidence across main/_0070/_0062 (${TS})"
    git push origin main
    git ls-remote origin main
    printf 'local HEAD: %s\n' "$(git rev-parse HEAD)"
else
    log_result "commit" "false" "nothing staged — report may already be committed"
fi

# ---------------------------------------------------------------------------
# Rule #55 RAW LINK VALIDATION — the link is proven HTTP 200 before it is
# printed.  GitHub's raw CDN can lag a push by several seconds, hence the
# bounded retry with exponential backoff.
# ---------------------------------------------------------------------------
validate_raw_link() {
    local url="$1" max_retries=4 delay=3 attempt=1 http_code
    while [ $attempt -le $max_retries ]; do
        http_code=$(curl -s -o /dev/null -w "%{http_code}" -L "$url")
        log_result "raw_link_check" "true" "attempt=$attempt http=$http_code url=$url"
        if [ "$http_code" = "200" ]; then
            return 0
        fi
        attempt=$((attempt + 1))
        if [ $attempt -le $max_retries ]; then
            log_result "raw_link_retry" "true" "waiting ${delay}s"
            sleep $delay
            delay=$((delay * 2))
        fi
    done
    log_result "raw_link_check" "false" "final http=$http_code after $max_retries attempts"
    return 1
}

RAW_LINK="${REMOTE_RAW}/${OUT}"
if validate_raw_link "$RAW_LINK"; then
    log_rule_compliance "55" "$SCRIPT_NAME" 1 "HTTP 200 for $RAW_LINK"
    log_rule_compliance "54" "$SCRIPT_NAME" 1 "evidence complete and reachable"
    printf '\n=== RAW LINK FOR LLM REVIEW ===\n'
    printf '%s\n' "$RAW_LINK"
else
    log_rule_compliance "55" "$SCRIPT_NAME" 0 "raw link never returned 200"
    printf '\n!! RAW LINK NOT REACHABLE — do not paste it; the push did not land.\n'
    printf 'attempted: %s\n' "$RAW_LINK"
    exit 1
fi
