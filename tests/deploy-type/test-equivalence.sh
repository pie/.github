#!/usr/bin/env bash
# deploy-type equivalence (brief, Decisions 1-3; Definition of done items 1-2).
#
#   standard  For every caller input set, the steps deploy.yaml and
#             deploy-via-rsync actually run (name, uses, with, env, run, shell,
#             with every input rendered) on this branch equal origin/main's,
#             text for text. Allowed differences: the deploy-type input, its
#             pass-through, and the one validation step (a step whose name
#             contains "deploy-type"), which must do nothing for a valid value.
#             Checked with deploy-type: standard passed, and not passed at all.
#   atomic    The same extraction with deploy-type: atomic equals #5's branch
#             (origin/feature/add-symlink-and-sql-flows) for the same inputs. A
#             step whose run: text differs is accepted only if running both
#             versions (with and without a .rsyncignore) has the same effect
#             and neither calls anything external (Ada's approval note 2).
#
# Optional: CALLERS_DIR=<folder of real callers' workflow files> also runs the
# standard check over every job in it that calls deploy.yaml. Not committed:
# real callers' inputs hold client hosts.
# shellcheck source-path=SCRIPTDIR source=../lib/testlib.sh
. "$(dirname "$0")/../lib/testlib.sh"

FIXTURES="$TESTS_DIR/fixtures/callers.yaml"
# The working tree under test, unless TEST_REPO_ROOT points elsewhere.
HEAD_ARGS=()
REPO_FOR_GIT="$GIT_REPO"
if [ -n "${TEST_REPO_ROOT:-}" ]; then
    echo "Note: TEST_REPO_ROOT is ignored here; compare reads git refs and the working tree of $GIT_REPO." >&2
fi

compare() {  # compare <description> <base ref> <callers file> [gha compare args...]
    local desc="$1" base="$2" callers="$3"
    shift 3
    echo "  -- $desc"
    if "${GHA[@]}" compare --repo "$REPO_FOR_GIT" --callers "$callers" --base-ref "$base" \
        "${HEAD_ARGS[@]}" "$@" | sed 's/^/     /'; then
        pass "$desc"
    else
        fail "$desc"
    fi
}

case_start "standard == origin/main, for each caller input set"
compare "deploy-type: standard passed" "$BASE_MAIN" "$FIXTURES" --deploy-type standard --expect-validation
compare "deploy-type not passed (default)" "$BASE_MAIN" "$FIXTURES" --expect-validation

case_start "atomic == $BASE_PR5, for each caller input set"
compare "deploy-type: atomic passed" "$BASE_PR5" "$FIXTURES" --deploy-type atomic --expect-validation --effect-equal-run

if [ -n "${CALLERS_DIR:-}" ]; then
    case_start "standard == origin/main, for every real caller in $CALLERS_DIR"
    real="$(mktemp)"
    "${GHA[@]}" collect-callers --dir "$CALLERS_DIR" --out "$real"
    compare "real callers, deploy-type not passed" "$BASE_MAIN" "$real" --expect-validation
    rm -f "$real"
fi

finish
