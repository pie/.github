#!/usr/bin/env bash
# Runs every scripted test. Exit 0 only if all pass. See tests/README.md.
set -uo pipefail
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
results=()
status=0
for t in \
    deploy-type/test-equivalence.sh \
    deploy-type/test-invalid-deploy-type.sh \
    deploy-type/test-release-yaml.sh \
    atomic/test-leftover-previous.sh \
    atomic/test-rollback-then-deploy.sh \
    atomic/test-exposure-check.sh \
    static/test-static.sh
do
    echo
    echo "################ $t"
    if bash "$TESTS_DIR/$t"; then
        results+=("PASS $t")
    else
        results+=("FAIL $t")
        status=1
    fi
done
echo
echo "################ summary"
printf '%s\n' "${results[@]}"
exit "$status"
