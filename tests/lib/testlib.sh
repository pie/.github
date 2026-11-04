# shellcheck shell=bash
# Shared helpers for the scripted tests. Source it; don't run it.
#
# A "sandbox" is a throwaway directory standing in for the server: a WordPress
# root with two live components (plugins/alpha, themes/beta), a repo checkout
# to upload from, and a log of every stubbed command (ssh, rsync, mv, curl,
# wp...). The workflows run through tests/lib/gha.py with tests/lib/stubs first
# on PATH, so nothing connects anywhere.

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The code under test. Override to run the tests against another checkout
# (e.g. an export of the base branch, to see them fail there).
REPO_ROOT="${TEST_REPO_ROOT:-$(cd "$TESTS_DIR/.." && pwd)}"
# shellcheck disable=SC2034 # used by the scripts that source this
GIT_REPO="$(cd "$TESTS_DIR/.." && pwd)"
GHA=(python3 "$TESTS_DIR/lib/gha.py")
# Fixed baselines, so the comparisons still mean something once #5 is in main:
# main before #5 (#8, c306c5d), and #5's branch before the deploy-type opt-in
# (#10). If 4b3ef1b is missing locally: git fetch origin refs/pull/5/head
BASE_MAIN="${BASE_MAIN:-c306c5d}"
BASE_PR5="${BASE_PR5:-4b3ef1b}"
COMPONENTS=$'plugins:alpha\nthemes:beta'
# shellcheck disable=SC2034
TAB=$'\t'
PASSES=0
FAILS=0
RUN_COUNTER=1000
SANDBOXES=()

UNKNOWN_INPUTS=()
if [ "${TEST_ALLOW_UNKNOWN_INPUTS:-}" = 1 ]; then
    UNKNOWN_INPUTS=(--allow-unknown-inputs)
fi

case_start() { echo; echo "== $*"; }
pass() { PASSES=$((PASSES + 1)); echo "  ok   $*"; }
fail() { FAILS=$((FAILS + 1)); echo "  FAIL $*"; }

# check "<what should be true>" command args...
check() {
    local desc="$1"
    shift
    if "$@"; then pass "$desc"; else fail "$desc"; fi
}

finish() {
    echo
    echo "$(basename "$0"): $PASSES passed, $FAILS failed"
    [ "$FAILS" -eq 0 ]
}

cleanup_sandboxes() {
    if [ "${KEEP_SANDBOX:-}" = 1 ]; then
        echo "(sandboxes kept: ${SANDBOXES[*]:-none})"
        return
    fi
    local s
    for s in "${SANDBOXES[@]}"; do
        rm -rf "$s"
    done
}
trap cleanup_sandboxes EXIT

put_component() {  # put_component <dir> <label>
    mkdir -p "$1"
    printf '%s\n' "$2" > "$1/version.txt"
    printf '%s\n' "$2" > "$1/only-in-$2.txt"
}

version_of() {  # version_of <dir>: its version.txt, or MISSING
    if [ -f "$1/version.txt" ]; then cat "$1/version.txt"; else echo MISSING; fi
}

new_sandbox() {
    SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/atomic-tests.XXXXXX")"
    SANDBOXES+=("$SANDBOX")
    if [[ ! "$SANDBOX" =~ ^/[A-Za-z0-9/_.-]*$ ]]; then
        echo "Sandbox path $SANDBOX has characters the workflows reject as wp-root; set TMPDIR to a plainer path." >&2
        exit 2
    fi
    WP_ROOT="$SANDBOX/site/public_html"
    RELEASES="$WP_ROOT/releases"
    LIVE_ALPHA="$WP_ROOT/wp-content/plugins/alpha"
    LIVE_BETA="$WP_ROOT/wp-content/themes/beta"
    WORKSPACE="$SANDBOX/workspace"
    OUT="$SANDBOX/out"
    export STUB_LOG="$SANDBOX/stub.log"
    export STUB_REMOTE_HOME="$SANDBOX/remote-home"
    export STUB_WEB_ROOT="$WP_ROOT"
    export STUB_SITE_URL="https://site.example.test"
    export STUB_CURL_MODE="protected"
    export GHA_TMP="$SANDBOX/gha"
    unset STUB_RSYNC_FAIL_MATCH STUB_CURL_STATUS STUB_PROTECTED_PREFIX
    mkdir -p "$WP_ROOT/wp-content/plugins" "$WP_ROOT/wp-content/themes" "$WORKSPACE" \
        "$STUB_REMOTE_HOME" "$GHA_TMP" "$OUT"
    : > "$STUB_LOG"
    put_component "$LIVE_ALPHA" initial
    put_component "$LIVE_BETA" initial
}

sha_for() {  # sha_for <letter>: a 40-character SHA made of that hex letter
    printf '%s' "$(printf "%040d" 0 | tr 0 "$1")"
}

github_json() {  # github_json <full sha>
    RUN_COUNTER=$((RUN_COUNTER + 1))
    printf '{"sha":"%s","run_id":"%s","run_attempt":"1","repository":"pie/example-repo","event":{"repository":{"name":"example-repo"}}}' \
        "$1" "$RUN_COUNTER"
}

run_workflow() {  # run_workflow <workflow path> <inputs json> <github json> <log file>
    "${GHA[@]}" run-workflow --repo "$REPO_ROOT" --workspace "$WORKSPACE" "${UNKNOWN_INPUTS[@]}" \
        --workflow "$1" --inputs "$2" --github "$3" >> "$4" 2>&1
}

# deploy <label> <letter> [site-url] [releases-dir]
# One atomic deploy as the README's example caller does it: prepare the
# releases dir, upload each component with deploy.yaml (deploy-type: atomic),
# then atomic-deploy.yaml. The release's files say <label>. Returns
# atomic-deploy's result; 90 if an earlier job failed. Output: $OUT/deploy-<label>.log
deploy() {
    local label="$1" sha site_url="${3-}" releases_input="${4-}" short gh log rel_dir comp type name
    sha="$(sha_for "$2")"
    short="${sha:0:8}"
    log="$OUT/deploy-$label.log"
    : > "$log"
    rm -rf "${WORKSPACE:?}"/*
    put_component "$WORKSPACE/plugins/alpha" "$label"
    put_component "$WORKSPACE/themes/beta" "$label"
    rel_dir="${releases_input:-$RELEASES}"
    gh="$(github_json "$sha")"
    run_workflow .github/workflows/prepare-releases-dir.yaml \
        "$(jq -nc --arg r "$WP_ROOT" --arg d "$releases_input" '{"ssh-host":"server.example.test","wp-root":$r,"releases-dir":$d}')" \
        "$gh" "$log" || return 90
    while IFS= read -r comp; do
        type="${comp%%:*}"
        name="${comp##*:}"
        run_workflow .github/workflows/deploy.yaml \
            "$(jq -nc --arg s "$type/$name/" --arg d "$rel_dir/$short/$type/$name" \
                '{"ssh-host":"server.example.test","source-path":$s,"destination-path":$d,"deploy-type":"atomic"}')" \
            "$gh" "$log" || return 90
    done <<< "$COMPONENTS"
    run_workflow .github/workflows/atomic-deploy.yaml \
        "$(jq -nc --arg r "$WP_ROOT" --arg c "$COMPONENTS" --arg u "$site_url" --arg d "$releases_input" \
            '{"ssh-host":"server.example.test","wp-root":$r,"components":$c,"site-url":$u,"releases-dir":$d}')" \
        "$gh" "$log"
}

# rollback <label>: rollback-deploy.yaml. Output: $OUT/rollback-<label>.log
rollback() {
    local log="$OUT/rollback-$1.log"
    : > "$log"
    run_workflow .github/workflows/rollback-deploy.yaml \
        "$(jq -nc --arg r "$WP_ROOT" '{"ssh-host":"server.example.test","wp-root":$r}')" \
        "$(github_json "$(sha_for 0)")" "$log"
}

# Line numbers (in $STUB_LOG) of each mv whose source is a live component dir.
live_mv_lines() {
    awk -F'\t' -v a="$LIVE_ALPHA" -v b="$LIVE_BETA" \
        '$1 == "mv" { for (i = 2; i < NF; i++) if ($i == a || $i == b) { print NR; break } }' "$STUB_LOG"
}

curl_lines() { awk -F'\t' '$1 == "curl" { print NR }' "$STUB_LOG"; }

# Helpers that read as assertions inside check.
equals() { [ "$1" = "$2" ] || { echo "       expected '$2', got '$1'"; return 1; }; }
succeeded() { [ "$1" -eq 0 ] || { echo "       exit code $1"; return 1; }; }
failed() { [ "$1" -ne 0 ] || { echo "       exit code 0"; return 1; }; }
exists() { [ -e "$1" ] || { echo "       missing: $1"; return 1; }; }
absent() { [ ! -e "$1" ] || { echo "       present: $1"; return 1; }; }
has_line() {  # has_line <file> <extended regex>
    grep -Eq -- "$2" "$1" || { echo "       no line matching /$2/ in $1"; return 1; }
}
no_line() {
    ! grep -Eq -- "$2" "$1" || { echo "       unexpected line matching /$2/ in $1:"; grep -E -- "$2" "$1" | head -3 | sed 's/^/         /'; return 1; }
}
