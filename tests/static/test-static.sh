#!/usr/bin/env bash
# Static checks on the files this step changes (brief, Definition of done
# items 8-9).
#
#   ShellCheck: every changed or new .sh under actions/: no more findings
#               than the same file on #5's branch (a new file: none). Prints
#               the counts, before -> after, for REVIEW-REQUEST.
#   YAML:       every changed workflow and action.yml parses.
#   actionlint: every changed workflow, if actionlint is installed (or
#               ACTIONLINT=/path/to/actionlint). Otherwise reported NOT RUN:
#               the script still passes (exit 0, and run.sh prints PASS), so
#               report actionlint as not verified.
#
# "Changed" = differs from $BASE_PR5 in the working tree, or is untracked.
# shellcheck source-path=SCRIPTDIR source=../lib/testlib.sh
. "$(dirname "$0")/../lib/testlib.sh"

changed_files() {
    {
        git -C "$GIT_REPO" diff --name-only "$BASE_PR5" -- actions .github
        git -C "$GIT_REPO" ls-files --others --exclude-standard -- actions .github
    } | sort -u
}
mapfile -t CHANGED < <(changed_files)
echo "Changed vs $BASE_PR5: ${CHANGED[*]:-none}"

count_findings() {  # count_findings <file> -> number of shellcheck findings
    local n
    n="$(shellcheck -f gcc "$1" 2>/dev/null | grep -c ':' || true)"
    printf '%s' "${n:-0}"
}

case_start "shellcheck: no new findings vs $BASE_PR5"
scratch="$(mktemp -d)"
for f in "${CHANGED[@]}"; do
    [[ "$f" == *.sh ]] || continue
    [ -f "$GIT_REPO/$f" ] || continue
    before=0
    if git -C "$GIT_REPO" cat-file -e "$BASE_PR5:$f" 2>/dev/null; then
        git -C "$GIT_REPO" show "$BASE_PR5:$f" > "$scratch/before.sh"
        before="$(count_findings "$scratch/before.sh")"
    fi
    after="$(count_findings "$GIT_REPO/$f")"
    if [ "$after" -le "$before" ]; then
        pass "$f: $before -> $after"
    else
        fail "$f: $before -> $after"
        shellcheck "$GIT_REPO/$f" | sed 's/^/       /' || true
    fi
done
rm -rf "$scratch"

case_start "YAML parses"
for f in "${CHANGED[@]}"; do
    [[ "$f" == *.yml || "$f" == *.yaml ]] || continue
    [ -f "$GIT_REPO/$f" ] || continue
    check "$f parses" python3 -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1]))' "$GIT_REPO/$f"
done

case_start "actionlint on changed workflows"
AL="${ACTIONLINT:-$(command -v actionlint || true)}"
if [ -z "$AL" ]; then
    echo "  NOT RUN actionlint isn't installed (set ACTIONLINT=/path/to/actionlint)"
    ACTIONLINT_NOT_RUN=1
else
    for f in "${CHANGED[@]}"; do
        [[ "$f" == .github/workflows/* ]] || continue
        [ -f "$GIT_REPO/$f" ] || continue
        check "actionlint $f" "$AL" -no-color "$GIT_REPO/$f"
    done
fi

rc=0
finish || rc=$?
if [ "${ACTIONLINT_NOT_RUN:-}" = 1 ]; then
    echo "(actionlint NOT RUN: report it as not verified)"
fi
exit "$rc"
