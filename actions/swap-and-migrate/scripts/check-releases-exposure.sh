#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# check-releases-exposure.sh — Is releases/ reachable over HTTP?
#
# Runs on the workflow runner (not uploaded to the server), between
# swap-and-migrate's upload step and swap.sh, so it fetches this release's
# components.txt, which the upload step has just written.
#
# Environment:
#   SITE_URL            Public URL of the site; empty skips the check
#   SHORT_SHA           Short (8-char) SHA — this release's directory name
#   WP_ROOT             Absolute path to the WordPress root on the server
#   RELEASES_DIR_INPUT  The releases-dir input; empty means WP_ROOT/releases
#   GITHUB_OUTPUT       Set by GitHub Actions; receives result=<value>
#
# Result (written to GITHUB_OUTPUT) and exit status:
#   skipped  exit 0  no site-url, or releases-dir isn't inside wp-root
#   safe     exit 0  the probe returned a status other than 200
#   unknown  exit 0  the probe never completed (curl error or status 000);
#                    a ::warning:: now, and the atomic-deploy workflow's
#                    verify_releases_protected job fails the run afterwards
#   exposed  exit 1  the probe returned 200; the deploy stops here, before
#                    swap.sh changes anything
# ==============================================================================

if [ -z "$SITE_URL" ]; then
    echo "site-url not set — skipping releases/ exposure check. See README Requirements."
    echo "result=skipped" >> "$GITHUB_OUTPUT"
    exit 0
fi

# Mirrors swap-and-migrate's own default-resolution for releases-dir,
# so this checks whatever directory the deploy actually wrote to,
# not always literally "releases/" — a releases-dir override with a
# different name would otherwise make this check probe the wrong
# path, 404, and report "safe" while the real directory sits
# unprotected.
if [ -n "$RELEASES_DIR_INPUT" ]; then
    RELEASES_DIR="$RELEASES_DIR_INPUT"
else
    RELEASES_DIR="$WP_ROOT/releases"
fi

# Only resolvable to a public URL path when releases-dir is inside
# wp-root (the standard, documented setup). An override that lands
# outside wp-root isn't web-reachable via site-url at all, and
# guessing a path here would risk the same false "safe" result this
# is meant to avoid — skip explicitly instead.
case "$RELEASES_DIR/" in
    "$WP_ROOT"/*)
        RELATIVE_RELEASES_PATH="${RELEASES_DIR#"$WP_ROOT"/}"
        ;;
    *)
        echo "releases-dir ('$RELEASES_DIR') isn't inside wp-root ('$WP_ROOT') — can't derive its public URL path, skipping releases/ exposure check."
        echo "result=skipped" >> "$GITHUB_OUTPUT"
        exit 0
        ;;
esac

CHECK_URL="${SITE_URL%/}/${RELATIVE_RELEASES_PATH}/${SHORT_SHA}/migrations/components.txt"
set +e
STATUS=$(curl -s --max-time 30 -o /dev/null -w '%{http_code}' "$CHECK_URL")
CURL_EXIT=$?
set -e

# curl exits non-zero (and/or reports status 000) on a connection,
# DNS, or TLS failure, or with exit 28 when --max-time's 30 seconds
# run out (a site that accepts the connection but never answers) —
# that means the probe never happened, not that it passed. Treating "couldn't check" as "checked and it's
# fine" would let a typo'd site-url (or the site being briefly
# unreachable) mask a real exposure indefinitely. It doesn't block
# the deploy (a fix for a site that's down must still go out); the
# workflow's verify_releases_protected job fails the run afterwards.
if [ "$CURL_EXIT" -ne 0 ] || [ "$STATUS" = "000" ]; then
    echo "::warning::Could not reach $CHECK_URL to check releases/ exposure (curl exit $CURL_EXIT, status '$STATUS') — this is not evidence releases/ is protected, only that the probe failed. The deploy carries on, and the run will be marked failed once it finishes. Verify site-url is correct and the site is reachable."
    echo "result=unknown" >> "$GITHUB_OUTPUT"
    exit 0
fi

if [ "$STATUS" = "200" ]; then
    echo "::error::${RELATIVE_RELEASES_PATH}/ is publicly reachable — $CHECK_URL returned HTTP 200. Nothing has been swapped or migrated: add the Prepare Releases Directory job before the upload jobs (see the README's Atomic Deploy section), or fix the host-side protection in its Requirements section, then re-run the deploy."
    echo "result=exposed" >> "$GITHUB_OUTPUT"
    exit 1
fi

echo "releases/ exposure check passed — $CHECK_URL returned HTTP $STATUS."
echo "result=safe" >> "$GITHUB_OUTPUT"
