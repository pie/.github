#!/usr/bin/env bash
# Fix B (brief, Decision 8): after rollback-deploy, the rolled-back release no
# longer counts as a complete prior release. The next deploy's prune keeps the
# release that was live before it and never deletes the live one; a rollback
# after that targets the release that was live before it.
#
# Each scenario runs the real workflows (prepare-releases-dir, deploy.yaml
# with deploy-type: atomic, atomic-deploy, rollback-deploy) through
# tests/lib/gha.py with ssh/rsync/wp stubbed. Releases are named by SHA:
# bbbbbbbb = B, cccccccc = C, dddddddd = D. site-url is left empty so the
# exposure check (fix A) is out of the way.
# shellcheck source-path=SCRIPTDIR source=../lib/testlib.sh
. "$(dirname "$0")/../lib/testlib.sh"

B="$(sha_for b)"; B="${B:0:8}"
C="$(sha_for c)"; C="${C:0:8}"
D="$(sha_for d)"; D="${D:0:8}"

# ---------------------------------------------------------------------------
case_start "Fix B: deploy B, deploy C, rollback (C -> B), deploy D, rollback"
new_sandbox

rc=0; deploy B b || rc=$?
check "deploy B succeeds" succeeded "$rc"
check "after deploy B, B is live" equals "$(version_of "$LIVE_ALPHA")/$(version_of "$LIVE_BETA")" "B/B"
sleep 1

rc=0; deploy C c || rc=$?
check "deploy C succeeds" succeeded "$rc"
check "after deploy C, C is live" equals "$(version_of "$LIVE_ALPHA")/$(version_of "$LIVE_BETA")" "C/C"
check "after deploy C, B is kept as the prior release" exists "$RELEASES/$B"
sleep 1

rc=0; rollback 1 || rc=$?
check "rollback (C -> B) succeeds" succeeded "$rc"
check "after the rollback, B is live" equals "$(version_of "$LIVE_ALPHA")/$(version_of "$LIVE_BETA")" "B/B"
check "the rollback restored B, not some other release" has_line "$OUT/rollback-1.log" "rolling back to prior release: $B"
check "maintenance mode is off after the rollback" absent "$WP_ROOT/.maintenance"
sleep 1

rc=0; deploy D d || rc=$?
check "deploy D succeeds" succeeded "$rc"
check "after deploy D, D is live" equals "$(version_of "$LIVE_ALPHA")/$(version_of "$LIVE_BETA")" "D/D"
check "D's prune keeps D (the live release)" exists "$RELEASES/$D/plugins/alpha"
check "D's prune keeps B (the release live before D)" exists "$RELEASES/$B/plugins/alpha"
check "D's prune logs B as the prior release it keeps (pins the wording the next check relies on)" \
    has_line "$OUT/deploy-D.log" "Keeping .*$B as prior release"
check "D's prune does not keep C as the prior release (C was rolled back)" \
    no_line "$OUT/deploy-D.log" "Keeping .*$C as prior release"
check "D's prune removes C (current + 1 prior: D and B)" absent "$RELEASES/$C"
sleep 1

rc=0; rollback 2 || rc=$?
check "a rollback after D succeeds" succeeded "$rc"
check "a rollback after D targets B" has_line "$OUT/rollback-2.log" "rolling back to prior release: $B"
check "after the second rollback, B is live" equals "$(version_of "$LIVE_ALPHA")/$(version_of "$LIVE_BETA")" "B/B"

# ---------------------------------------------------------------------------
case_start "Fix B, redeploy: deploy B, deploy C, rollback (C -> B), deploy C again, rollback"
# Re-running a rolled-back release (the same SHA) makes it complete again: it
# went live. The deploy's prune keeps B (live before it); a rollback goes C -> B.
new_sandbox
rc=0; deploy B b || rc=$?;  check "deploy B succeeds" succeeded "$rc"; sleep 1
rc=0; deploy C c || rc=$?;  check "deploy C succeeds" succeeded "$rc"; sleep 1
rc=0; rollback 1 || rc=$?;  check "rollback (C -> B) succeeds" succeeded "$rc"; sleep 1
rc=0; deploy C2 c || rc=$?
check "deploying C again succeeds" succeeded "$rc"
check "C is live again" equals "$(version_of "$LIVE_ALPHA")" "C2"
check "the redeploy's prune keeps B (live before it)" exists "$RELEASES/$B/plugins/alpha"
sleep 1
rc=0; rollback 2 || rc=$?
check "a rollback after the redeploy succeeds" succeeded "$rc"
check "it rolls back to B" has_line "$OUT/rollback-2.log" "rolling back to prior release: $B"
check "B is live" equals "$(version_of "$LIVE_ALPHA")" "B"

# ---------------------------------------------------------------------------
case_start "Regression: deploy B, C, D with no rollback (prune keeps D and C; rollback goes D -> C)"
new_sandbox
rc=0; deploy B b || rc=$?; check "deploy B succeeds" succeeded "$rc"; sleep 1
rc=0; deploy C c || rc=$?; check "deploy C succeeds" succeeded "$rc"; sleep 1
rc=0; deploy D d || rc=$?; check "deploy D succeeds" succeeded "$rc"
check "D's prune keeps C as prior" exists "$RELEASES/$C/plugins/alpha"
check "D's prune removes B" absent "$RELEASES/$B"
sleep 1
rc=0; rollback 1 || rc=$?
check "rollback succeeds" succeeded "$rc"
check "it rolls back to C" has_line "$OUT/rollback-1.log" "rolling back to prior release: $C"
check "C is live" equals "$(version_of "$LIVE_ALPHA")/$(version_of "$LIVE_BETA")" "C/C"

finish
