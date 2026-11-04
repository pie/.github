#!/usr/bin/env bash
# An invalid deploy-type fails the job early, with a message naming the allowed
# values (brief, Decision 1; Definition of done item 4). And the two valid
# values don't (a regression check that the validation isn't too strict).
#
# Runs deploy.yaml and the deploy-via-rsync action through tests/lib/gha.py
# with ssh/rsync/npm/composer stubbed. "Early" = nothing that builds or
# uploads ran: no stubbed command was called, and no step after the failing
# one ran.
# shellcheck source-path=SCRIPTDIR source=../lib/testlib.sh
. "$(dirname "$0")/../lib/testlib.sh"

no_build_or_upload() {
    if grep -Eq '^(ssh|scp|rsync|sshpass|npm|npx|composer)'"$TAB" "$STUB_LOG"; then
        echo "       these ran:"; grep -E '^(ssh|scp|rsync|sshpass|npm|npx|composer)' "$STUB_LOG" | sed 's/^/         /'
        return 1
    fi
}
# After the first failing step, every later step is skipped.
nothing_after_failure() {
    awk '/\] *FAIL / { failed = 1; next } failed && /\] *step / { print; bad = 1 } END { exit bad }' "$1" \
        || { echo "       steps ran after the failure (above)"; return 1; }
}
names_allowed_values() {  # a line naming both standard and atomic
    grep -i 'standard' "$1" | grep -qi 'atomic' || { echo "       no line in $1 names both 'standard' and 'atomic'"; return 1; }
}

for value in bogus Atomic STANDARD "atomic "; do
    case_start "deploy.yaml with deploy-type: '$value'"
    new_sandbox
    log="$OUT/deploy-yaml.log"
    rc=0
    run_workflow .github/workflows/deploy.yaml \
        "$(jq -nc --arg v "$value" '{"ssh-host":"server.example.test","destination-path":"/var/www/x","npm":"true","composer":"true","deploy-type":$v}')" \
        "$(github_json "$(sha_for a)")" "$log" || rc=$?
    check "the job fails" failed "$rc"
    check "the message names the allowed values (standard, atomic)" names_allowed_values "$log"
    check "nothing was built or uploaded" no_build_or_upload
    check "no step ran after the failing one" nothing_after_failure "$log"

    case_start "deploy-via-rsync action used directly, deploy-type: '$value'"
    : > "$STUB_LOG"
    log="$OUT/action.log"
    rc=0
    "${GHA[@]}" run-action --repo "$REPO_ROOT" --workspace "$WORKSPACE" --action deploy-via-rsync \
        --inputs "$(jq -nc --arg v "$value" '{"ssh-host":"server.example.test","destination-path":"/var/www/x","npm":"true","deploy-type":$v}')" \
        > "$log" 2>&1 || rc=$?
    check "the action fails" failed "$rc"
    check "the message names the allowed values (standard, atomic)" names_allowed_values "$log"
    check "nothing was built or uploaded" no_build_or_upload
    check "no step ran after the failing one" nothing_after_failure "$log"
done

# --- valid values still deploy -------------------------------------------
case_start "deploy.yaml with deploy-type: standard uploads to an existing destination, without creating it"
new_sandbox
put_component "$WORKSPACE/plugins/alpha" S
mkdir -p "$SANDBOX/dest"
rc=0
run_workflow .github/workflows/deploy.yaml \
    "$(jq -nc --arg d "$SANDBOX/dest/alpha" '{"ssh-host":"server.example.test","source-path":"plugins/alpha/","destination-path":$d,"deploy-type":"standard"}')" \
    "$(github_json "$(sha_for a)")" "$OUT/standard.log" || rc=$?
check "the job succeeds" succeeded "$rc"
check "the files arrive" equals "$(version_of "$SANDBOX/dest/alpha")" S
check "no 'mkdir' over ssh (standard has no create-destination step)" no_line "$STUB_LOG" '^ssh.*mkdir'

case_start "deploy.yaml with deploy-type: atomic creates the nested release path and uploads"
put_component "$WORKSPACE/plugins/alpha" A
rc=0
run_workflow .github/workflows/deploy.yaml \
    "$(jq -nc --arg d "$SANDBOX/site/releases/aaaaaaaa/plugins/alpha" '{"ssh-host":"server.example.test","source-path":"plugins/alpha/","destination-path":$d,"deploy-type":"atomic"}')" \
    "$(github_json "$(sha_for a)")" "$OUT/atomic.log" || rc=$?
check "the job succeeds" succeeded "$rc"
check "the files arrive under releases/<sha>/plugins/alpha" equals "$(version_of "$SANDBOX/site/releases/aaaaaaaa/plugins/alpha")" A

finish
