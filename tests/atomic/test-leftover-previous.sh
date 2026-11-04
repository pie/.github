#!/usr/bin/env bash
# Fix C (brief, Decision 9): a leftover <name>.previous is restored, not deleted.
#
# If <name>.previous exists and live <name> doesn't, an earlier run died
# between its two renames (live -> .previous, staging -> live). swap.sh and
# rollback-deploy.sh move .previous back to live, with a ::warning:: (a line
# that starts with ::warning::, so Actions shows it), then carry on. If both
# exist, the stale .previous is removed as today.
#
# "Restored" is seen two ways: the run carries on to the normal end state, and
# a run made to fail later in staging (the rsync stub fails for themes/beta)
# leaves the restored copy live, where today it is deleted.
# shellcheck source-path=SCRIPTDIR source=../lib/testlib.sh
. "$(dirname "$0")/../lib/testlib.sh"

WARN_ALPHA='^::warning::.*alpha'

# An earlier deploy died after "live -> .previous" and before
# "staging -> live": alpha is missing, alpha.previous holds what was live.
break_between_renames() {  # <staging label>
    command mv "$LIVE_ALPHA" "$LIVE_ALPHA.previous"
    put_component "$LIVE_ALPHA.deploying" "$1"
}

# ---------------------------------------------------------------------------
case_start "swap.sh: alpha missing, alpha.previous present; the deploy then fails staging beta"
new_sandbox
rc=0; deploy B b || rc=$?; check "set-up: deploy B succeeds" succeeded "$rc"; sleep 1
break_between_renames X
rc=0; STUB_RSYNC_FAIL_MATCH="beta.deploying" deploy D d || rc=$?
check "the deploy fails (injected rsync failure on beta)" failed "$rc"
check "alpha is restored from alpha.previous (B)" equals "$(version_of "$LIVE_ALPHA")" "B"
check "alpha.previous is gone (moved back, not copied)" absent "$LIVE_ALPHA.previous"
check "a ::warning:: line names alpha" has_line "$OUT/deploy-D.log" "$WARN_ALPHA"
check "beta is untouched (B)" equals "$(version_of "$LIVE_BETA")" "B"

# ---------------------------------------------------------------------------
case_start "swap.sh: alpha missing, alpha.previous present; the deploy carries on"
new_sandbox
rc=0; deploy B b || rc=$?; check "set-up: deploy B succeeds" succeeded "$rc"; sleep 1
break_between_renames X
rc=0; deploy D d || rc=$?
check "the deploy succeeds" succeeded "$rc"
check "D is live" equals "$(version_of "$LIVE_ALPHA")/$(version_of "$LIVE_BETA")" "D/D"
check "a ::warning:: line names alpha" has_line "$OUT/deploy-D.log" "$WARN_ALPHA"
check "no alpha.previous left" absent "$LIVE_ALPHA.previous"
check "no alpha.deploying left" absent "$LIVE_ALPHA.deploying"

# ---------------------------------------------------------------------------
case_start "swap.sh: alpha and a stale alpha.previous both present; the deploy then fails staging beta"
new_sandbox
rc=0; deploy B b || rc=$?; check "set-up: deploy B succeeds" succeeded "$rc"; sleep 1
put_component "$LIVE_ALPHA.previous" STALE
rc=0; STUB_RSYNC_FAIL_MATCH="beta.deploying" deploy D d || rc=$?
check "the deploy fails (injected rsync failure on beta)" failed "$rc"
check "live alpha is kept (B), not replaced by the stale copy" equals "$(version_of "$LIVE_ALPHA")" "B"
check "the stale alpha.previous is removed" absent "$LIVE_ALPHA.previous"

# ---------------------------------------------------------------------------
case_start "swap.sh: alpha and a stale alpha.previous both present; the deploy carries on"
new_sandbox
rc=0; deploy B b || rc=$?; check "set-up: deploy B succeeds" succeeded "$rc"; sleep 1
put_component "$LIVE_ALPHA.previous" STALE
rc=0; deploy D d || rc=$?
check "the deploy succeeds" succeeded "$rc"
check "D is live" equals "$(version_of "$LIVE_ALPHA")/$(version_of "$LIVE_BETA")" "D/D"
check "the stale alpha.previous is removed" absent "$LIVE_ALPHA.previous"

# ---------------------------------------------------------------------------
case_start "rollback-deploy.sh: alpha missing, alpha.previous present (an earlier rollback died); the rollback carries on"
new_sandbox
rc=0; deploy B b || rc=$?; check "set-up: deploy B succeeds" succeeded "$rc"; sleep 1
rc=0; deploy C c || rc=$?; check "set-up: deploy C succeeds" succeeded "$rc"; sleep 1
break_between_renames B
rc=0; rollback 1 || rc=$?
check "the rollback succeeds (the restored alpha matches C, so it isn't 'drifted')" succeeded "$rc"
check "a ::warning:: line names alpha" has_line "$OUT/rollback-1.log" "$WARN_ALPHA"
check "B is live" equals "$(version_of "$LIVE_ALPHA")/$(version_of "$LIVE_BETA")" "B/B"
check "no alpha.previous left" absent "$LIVE_ALPHA.previous"
check "no alpha.deploying left" absent "$LIVE_ALPHA.deploying"

# ---------------------------------------------------------------------------
case_start "rollback-deploy.sh: alpha missing, alpha.previous present; the rollback then fails staging beta"
new_sandbox
rc=0; deploy B b || rc=$?; check "set-up: deploy B succeeds" succeeded "$rc"; sleep 1
rc=0; deploy C c || rc=$?; check "set-up: deploy C succeeds" succeeded "$rc"; sleep 1
break_between_renames B
rc=0; STUB_RSYNC_FAIL_MATCH="beta.deploying" rollback 1 || rc=$?
check "the rollback fails (injected rsync failure on beta)" failed "$rc"
check "alpha is restored from alpha.previous (C)" equals "$(version_of "$LIVE_ALPHA")" "C"
check "alpha.previous is gone" absent "$LIVE_ALPHA.previous"
check "a ::warning:: line names alpha" has_line "$OUT/rollback-1.log" "$WARN_ALPHA"

# ---------------------------------------------------------------------------
case_start "rollback-deploy.sh: alpha and a stale alpha.previous both present"
new_sandbox
rc=0; deploy B b || rc=$?; check "set-up: deploy B succeeds" succeeded "$rc"; sleep 1
rc=0; deploy C c || rc=$?; check "set-up: deploy C succeeds" succeeded "$rc"; sleep 1
put_component "$LIVE_ALPHA.previous" STALE
rc=0; rollback 1 || rc=$?
check "the rollback succeeds" succeeded "$rc"
check "B is live" equals "$(version_of "$LIVE_ALPHA")/$(version_of "$LIVE_BETA")" "B/B"
check "the stale alpha.previous is removed" absent "$LIVE_ALPHA.previous"

finish
