#!/usr/bin/env bash
# Fix A (brief, Decision 7, and its 2026-11-04 amendment): the releases/
# exposure check runs before the swap.
#
#   exposed  (HTTP 200 on a file under releases/<sha>/): the run fails before
#            any live directory is renamed.
#   safe     (any other HTTP status): the deploy goes ahead, the run passes.
#   unknown  (curl fails / status 000): a ::warning::, the deploy carries on,
#            and the run still ends failed, as today.
#   no site-url, or releases-dir outside wp-root: skipped, as today.
#
# Part 1 runs the check script on its own
# (actions/swap-and-migrate/scripts/check-releases-exposure.sh, env SITE_URL,
# SHORT_SHA, WP_ROOT, RELEASES_DIR_INPUT). Part 2 runs whole deploys through
# the workflows with curl stubbed as a fake web server (tests/lib/stubs/curl)
# and mv recorded, so "before any mv of a live directory" is checked from the
# order of calls.
# shellcheck source-path=SCRIPTDIR source=../lib/testlib.sh
. "$(dirname "$0")/../lib/testlib.sh"

CHECK_SCRIPT="$REPO_ROOT/actions/swap-and-migrate/scripts/check-releases-exposure.sh"
SHA="$(sha_for e)"; SHORT="${SHA:0:8}"
URL_DEFAULT="https://site.example.test/releases/$SHORT/migrations/components.txt"

# run_check <site-url> <releases-dir input>: the script alone, curl stubbed,
# in a step-like environment (Actions always sets GITHUB_OUTPUT and GITHUB_ENV).
run_check() {
    : > "$STUB_LOG"
    CHECK_OUT="$OUT/check.$RANDOM.log"
    : > "$OUT/GITHUB_OUTPUT"
    : > "$OUT/GITHUB_ENV"
    local rc=0
    env PATH="$TESTS_DIR/lib/stubs:$PATH" SITE_URL="$1" SHORT_SHA="$SHORT" WP_ROOT="$WP_ROOT" \
        RELEASES_DIR_INPUT="$2" GITHUB_OUTPUT="$OUT/GITHUB_OUTPUT" GITHUB_ENV="$OUT/GITHUB_ENV" \
        bash "$CHECK_SCRIPT" > "$CHECK_OUT" 2>&1 || rc=$?
    return "$rc"
}

# A release whose components.txt is on disk, as after "Upload swap scripts".
put_uploaded_release() {  # <releases dir>
    mkdir -p "$1/$SHORT/migrations"
    printf 'plugins:alpha\n' > "$1/$SHORT/migrations/components.txt"
}

curl_called() { [ -n "$(curl_lines)" ] || { echo "       curl was not called"; return 1; }; }
curl_not_called() { [ -z "$(curl_lines)" ] || { echo "       curl was called:"; grep '^curl' "$STUB_LOG" | sed 's/^/         /'; return 1; }; }
probed() {  # probed <url> <status>
    grep -qxF "$(printf 'curl\t%s\t%s' "$1" "$2")" "$STUB_LOG" || {
        echo "       no probe of $1 answered $2; curl calls:"; grep '^curl' "$STUB_LOG" | sed 's/^/         /'; return 1; }
}
probe_before_first_live_mv() {
    local first_curl first_mv
    first_curl="$(curl_lines | head -1)"
    first_mv="$(live_mv_lines | head -1)"
    [ -n "$first_curl" ] || { echo "       no probe at all"; return 1; }
    [ -n "$first_mv" ] || { echo "       no live mv at all"; return 1; }
    [ "$first_curl" -lt "$first_mv" ] || { echo "       first probe (log line $first_curl) after first live mv (line $first_mv)"; return 1; }
}
curl_maxtime_at_most() {  # curl_maxtime_at_most <seconds>: every curl call had a max time within it
    local t
    t="$(awk -F'\t' '$1 == "curl-maxtime" { print $2 }' "$STUB_LOG")"
    [ -n "$t" ] || { echo "       curl was called with no max time"; return 1; }
    while IFS= read -r v; do
        awk -v v="$v" -v m="$1" 'BEGIN { exit !(v + 0 > 0 && v + 0 <= m + 0) }' || { echo "       max time $v is not within 1..$1"; return 1; }
    done <<< "$t"
}
no_live_mv() {
    [ -z "$(live_mv_lines)" ] || { echo "       live directories were renamed:"; awk 'NR==FNR{l[$1];next} FNR in l' <(live_mv_lines) "$STUB_LOG" | sed 's/^/         /'; return 1; }
}
live_is() { equals "$(version_of "$LIVE_ALPHA")/$(version_of "$LIVE_BETA")" "$1/$1"; }

# ===========================================================================
# Part 1: the check script on its own
# ===========================================================================
case_start "check script exists"
new_sandbox
check "actions/swap-and-migrate/scripts/check-releases-exposure.sh exists" exists "$CHECK_SCRIPT"

case_start "check script: no site-url -> skipped, passes, no probe"
rc=0; run_check "" "" || rc=$?
check "exits 0" succeeded "$rc"
check "does not call curl" curl_not_called

case_start "check script: releases-dir outside wp-root -> skipped, passes, no probe"
export STUB_CURL_MODE=exposed
put_uploaded_release "$SANDBOX/elsewhere/releases"
rc=0; run_check "https://site.example.test" "$SANDBOX/elsewhere/releases" || rc=$?
check "exits 0" succeeded "$rc"
check "does not call curl" curl_not_called

case_start "check script: exposed (HTTP 200 on releases/<sha>/migrations/components.txt) -> fails"
export STUB_CURL_MODE=exposed
put_uploaded_release "$RELEASES"
rc=0; run_check "https://site.example.test" "" || rc=$?
check "exits non-zero" failed "$rc"
check "probes $URL_DEFAULT and gets 200" probed "$URL_DEFAULT" 200
check "prints an ::error:: line" has_line "$CHECK_OUT" '^::error::'

case_start "check script: exposed, site-url with a trailing slash -> same URL, fails"
rc=0; run_check "https://site.example.test/" "" || rc=$?
check "exits non-zero" failed "$rc"
check "probes $URL_DEFAULT" probed "$URL_DEFAULT" 200

case_start "check script: exposed, releases-dir overridden inside wp-root -> probes that path, fails"
put_uploaded_release "$WP_ROOT/app/releases"
rc=0; run_check "https://site.example.test" "$WP_ROOT/app/releases" || rc=$?
check "exits non-zero" failed "$rc"
check "probes app/releases/<sha>/migrations/components.txt" \
    probed "https://site.example.test/app/releases/$SHORT/migrations/components.txt" 200

case_start "check script: protected (403) -> safe, passes"
export STUB_CURL_MODE=protected
rc=0; run_check "https://site.example.test" "" || rc=$?
check "exits 0" succeeded "$rc"
check "probes $URL_DEFAULT and gets 403" probed "$URL_DEFAULT" 403

case_start "check script: 404 -> safe, passes"
export STUB_CURL_MODE=fixed STUB_CURL_STATUS=404
rc=0; run_check "https://site.example.test" "" || rc=$?
check "exits 0" succeeded "$rc"
check "probes $URL_DEFAULT and gets 404" probed "$URL_DEFAULT" 404
unset STUB_CURL_STATUS

case_start "check script: curl hangs (exit 28, status 000) -> unknown, warns, passes, and curl was given a max time"
# Decision 1 of the 2026-11-04 review: the probe is bounded (--max-time 30), so
# a hang becomes the "unknown" result instead of holding the deploy.
export STUB_CURL_MODE=hang
rc=0; run_check "https://site.example.test" "" || rc=$?
check "exits 0" succeeded "$rc"
check "prints a ::warning:: line" has_line "$CHECK_OUT" '^::warning::'
check "does not print an ::error:: line" no_line "$CHECK_OUT" '^::error::'
check "writes result=unknown to GITHUB_OUTPUT" has_line "$OUT/GITHUB_OUTPUT" '^result=unknown$'
check "curl was given a max time" has_line "$STUB_LOG" "^curl-maxtime${TAB}[1-9][0-9]*$"
check "the max time is no more than 60 seconds" curl_maxtime_at_most 60
unset STUB_CURL_MODE

# ===========================================================================
# Part 2: whole deploys
# ===========================================================================
case_start "deploy, releases/ exposed: fails before any live directory is renamed"
new_sandbox
export STUB_CURL_MODE=exposed
rc=0; deploy E e "https://site.example.test" || rc=$?
check "the run fails" failed "$rc"
check "the probe got HTTP 200 on a file under releases/<sha>/" has_line "$STUB_LOG" "^curl${TAB}https://site\.example\.test/releases/$SHORT/.*${TAB}200$"
check "no live directory was renamed (no mv of plugins/alpha or themes/beta)" no_live_mv
check "the live site is untouched (initial)" live_is initial
# Not asserted: "no .previous/.deploying beside live" and "maintenance mode not
# on". With the old post-swap check the swap completes (which removes
# .previous) and the wp stub reports no migrations (so maintenance mode is
# never entered), so neither could fail here. no_live_mv and live_is above are
# what show the swap never started.
check "an ::error:: line is printed" has_line "$OUT/deploy-E.log" '^::error::'

case_start "deploy, releases/ protected (403): deploys, passes, and probed before the swap"
new_sandbox
export STUB_CURL_MODE=protected
rc=0; deploy E e "https://site.example.test" || rc=$?
check "the run succeeds" succeeded "$rc"
check "E is live" live_is E
check "the probe got 403" has_line "$STUB_LOG" "^curl${TAB}https://site\.example\.test/releases/$SHORT/.*${TAB}403$"
check "the probe ran before the first live directory was renamed" probe_before_first_live_mv

case_start "deploy, probe can't reach the site (unknown): warns, deploys, and the run still ends failed"
new_sandbox
export STUB_CURL_MODE=unreachable
rc=0; deploy E e "https://site.example.test" || rc=$?
check "the deploy carried on: E is live" live_is E
check "a ::warning:: line is printed" has_line "$OUT/deploy-E.log" '^::warning::'
check "the run still ends failed" failed "$rc"
check "the probe ran before the first live directory was renamed" probe_before_first_live_mv

case_start "deploy, probe hangs (curl exit 28): warns, deploys, the probe was bounded, and the run still ends failed"
new_sandbox
export STUB_CURL_MODE=hang
rc=0; deploy E e "https://site.example.test" || rc=$?
check "the deploy carried on: E is live" live_is E
check "a ::warning:: line is printed" has_line "$OUT/deploy-E.log" '^::warning::'
check "the run still ends failed" failed "$rc"
check "curl was given a max time" has_line "$STUB_LOG" "^curl-maxtime${TAB}[1-9][0-9]*$"
check "the max time is no more than 60 seconds" curl_maxtime_at_most 60
check "the probe ran before the first live directory was renamed" probe_before_first_live_mv

case_start "deploy, no site-url: skipped, deploys, passes"
new_sandbox
export STUB_CURL_MODE=exposed
rc=0; deploy E e "" || rc=$?
check "the run succeeds" succeeded "$rc"
check "E is live" live_is E
check "curl is not called" curl_not_called

case_start "deploy, releases-dir outside wp-root: skipped, deploys, passes"
new_sandbox
export STUB_CURL_MODE=exposed
rc=0; deploy E e "https://site.example.test" "$SANDBOX/elsewhere/releases" || rc=$?
check "the run succeeds" succeeded "$rc"
check "E is live" live_is E
check "curl is not called" curl_not_called

finish
