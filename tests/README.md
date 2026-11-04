# Tests

Tests for PIE's shared workflows and actions. They run on your machine: nothing connects to a
server, and no workflow is dispatched. Written from the brief, not the code; whoever builds a
change doesn't edit them.

```sh
tests/run.sh                                   # everything; exit 0 only if all pass
tests/atomic/test-rollback-then-deploy.sh      # one file
KEEP_SANDBOX=1 tests/atomic/test-...sh         # keep the throwaway server directories to look at
CALLERS_DIR=<folder of callers' workflow files> tests/deploy-type/test-equivalence.sh
```

Needs bash 5, git (with the baselines `c306c5d`, main before #5, and `4b3ef1b`, #5 before the
deploy-type opt-in; if `4b3ef1b` is missing, `git fetch origin refs/pull/5/head`; override with
`BASE_MAIN` / `BASE_PR5`),
python3 with PyYAML, rsync, jq, GNU coreutils/find, and shellcheck. actionlint is optional: set
`ACTIONLINT=/path/to/actionlint` or put it on `PATH`; without it the static check says NOT RUN.

```
tests/
  run.sh                 runs every test below
  lib/gha.py             a small local stand-in for GitHub Actions (see its docstring)
  lib/stubs/             ssh, scp, rsync, sshpass, curl, wp, mv, npm, npx, composer stand-ins
  lib/testlib.sh         sandbox, deploy/rollback helpers, checks
  fixtures/callers.yaml  real callers' deploy.yaml inputs, anonymised (this repo is public)
  deploy-type/           deploy-type: standard == main, atomic == #5, invalid values, release.yaml
  atomic/                atomic deploy safety: exposure check, leftover .previous, rollback then deploy
  static/                shellcheck counts, YAML parsing, actionlint
  functional/            steps a person follows where a script can't reach (live deploys)
```

## How the workflows run locally

`lib/gha.py run-workflow` runs a workflow's jobs in order. `run:` steps go to
`bash --noprofile --norc -eo pipefail`, as on a runner, with `GITHUB_ENV`, `GITHUB_OUTPUT` and
`GITHUB_PATH` honoured. Composite actions under `pie/.github/actions/` are expanded from this
checkout, whatever their `@ref`. `add-ssh-config` and `add-ssh-pass` are skipped (they would write
this machine's SSH config), as is every third-party action (checkout, setup-node, composer).

`lib/stubs` goes first on `PATH`. `ssh server "<cmd>"` runs `<cmd>` here; `server:<path>` in
rsync and scp becomes `<path>`; `curl` is a fake web server for the site (`STUB_CURL_MODE`:
`exposed`, `protected`, `unreachable`, `fixed`); `wp` answers what swap.sh and rollback-deploy.sh
ask when there are no migrations. Each call is logged to `$STUB_LOG`, so a test can check what
ran and in what order (for example, the exposure probe before the first `mv` of a live directory).

A test's "server" is a sandbox directory under `$TMPDIR`: a WordPress root with live
`plugins/alpha` and `themes/beta`, and a checkout to upload from. Its path must contain only
letters, digits and `/_.-`, because the actions reject anything else as `wp-root`.

## Running the tests against other code

`TEST_REPO_ROOT=<a checkout>` runs the workflow tests against that checkout instead of this one,
for example an export of the base branch to see a test fail before the fix
(`git archive 4b3ef1b | tar -x -C <dir>`). Add
`TEST_ALLOW_UNKNOWN_INPUTS=1` when that code doesn't declare `deploy-type`. The equivalence and
static tests always compare git refs with this working tree.

## Functional scripts

Checks a person runs where a script can't reach (a live deploy to the test host). Start from the
ada template. `Last run` is one line: the date, the result in a few words, and where the detail is
(the PR). The run record goes in the PR description, not in the script.
