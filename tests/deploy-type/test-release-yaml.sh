#!/usr/bin/env bash
# release.yaml is identical to origin/main's (brief, Decision 4; Definition of
# done item 3). If it isn't, the PR has to say why: this test then fails and
# shows the difference.
# shellcheck source-path=SCRIPTDIR source=../lib/testlib.sh
. "$(dirname "$0")/../lib/testlib.sh"

case_start "release.yaml in the working tree vs $BASE_MAIN"
same_as_main() {
    git -C "$GIT_REPO" diff --exit-code "$BASE_MAIN" -- .github/workflows/release.yaml \
        || { echo "       (differs from $BASE_MAIN: diff above)"; return 1; }
}
check ".github/workflows/release.yaml is identical to $BASE_MAIN's" same_as_main
finish
