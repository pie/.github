#!/usr/bin/env bash
# Composer's PHP is pinned (task 1220862271790405). php-actions/composer ran on
# the newest official PHP image, which moved to 8.6 on 19 Nov 2026 without
# mbstring, and composer install failed for packages that need it.
#
# For deploy.yaml (standard and atomic) and deploy-via-ftp.yaml: when composer
# runs, shivammathur/setup-php runs first, with PHP 8.5 and mbstring unless the
# caller says otherwise, then `composer install` with the caller's args in the
# working directory. When composer doesn't run, neither does setup-php.
# shellcheck source-path=SCRIPTDIR source=../lib/testlib.sh
. "$(dirname "$0")/../lib/testlib.sh"

CALLERS="$(mktemp)"
trap 'rm -f "$CALLERS"' EXIT
cat > "$CALLERS" <<'EOF'
callers:
  - id: rsync-composer-defaults
    with:
      ssh-host: host.example.test
      destination-path: /var/www/example
      working-directory: ./themes/example/
      composer: true
  - id: rsync-composer-overrides
    with:
      ssh-host: host.example.test
      destination-path: /var/www/example
      composer: true
      composer-args: --no-dev --no-interaction
      php-version: "8.3"
      php-extensions: mbstring, intl
  - id: rsync-no-composer
    with:
      ssh-host: host.example.test
      destination-path: /var/www/example
  - id: ftp-composer-defaults
    with:
      ftp-host: ftp.example.test
      ftp-username: example
      destination-path: /public_html/
      composer: true
  - id: ftp-composer-overrides
    with:
      ftp-host: ftp.example.test
      ftp-username: example
      destination-path: /public_html/
      composer: true
      php-version: "8.3"
      php-extensions: mbstring, intl
  - id: ftp-no-composer
    with:
      ftp-host: ftp.example.test
      ftp-username: example
      destination-path: /public_html/
EOF

steps() {  # steps <workflow> <caller id> [deploy-type]
    local extra=()
    [ -n "${3:-}" ] && extra=(--deploy-type "$3")
    "${GHA[@]}" extract --repo "$GIT_REPO" --workflow "$1" --callers "$CALLERS" --caller "$2" "${extra[@]}"
}

# The setup-php step's `with`, or null if it doesn't run.
setup_php() { steps "$@" | jq -c '[.steps[] | select((.uses // "") | startswith("shivammathur/setup-php@"))] | if length == 0 then null else .[0].with end'; }

# The steps' names from setup-php onwards, as one line, to check the order.
order() { steps "$@" | jq -r '[.steps[] | select(.step != null) | .step | sub("^.* > "; "")] | map(select(test("Set up PHP|Composer"))) | join(" | ")'; }

composer_step() { steps "$@" | jq -c '[.steps[] | select((.step // "") | test("Install Composer Dependencies"))] | .[0] | {env, run}'; }

no_php_actions_composer() {
    if steps "$@" | jq -e '[.steps[] | select((.uses // "") | startswith("php-actions/composer@"))] | length > 0' >/dev/null; then
        echo "       php-actions/composer still runs"; return 1
    fi
}

RSYNC=.github/workflows/deploy.yaml
FTP=.github/workflows/deploy-via-ftp.yaml
DEFAULT_SETUP='{"coverage":"none","extensions":"mbstring","php-version":"8.5","tools":"composer:v2"}'
OVERRIDE_SETUP='{"coverage":"none","extensions":"mbstring, intl","php-version":"8.3","tools":"composer:v2"}'
ORDER='Set up PHP if required | Install Composer Dependencies if required'

for type in standard atomic; do
    case_start "deploy.yaml, deploy-type: $type"
    check "composer: PHP 8.5 with mbstring by default" equals "$(setup_php $RSYNC rsync-composer-defaults $type)" "$DEFAULT_SETUP"
    check "composer: php-version and php-extensions are passed through" equals "$(setup_php $RSYNC rsync-composer-overrides $type)" "$OVERRIDE_SETUP"
    check "composer: PHP is set up before composer install" equals "$(order $RSYNC rsync-composer-defaults $type)" "$ORDER"
    check "composer: install runs in working-directory with the default args" equals "$(composer_step $RSYNC rsync-composer-defaults $type)" \
        '{"env":{"COMPOSER_ARGS":"--no-dev --no-interaction --no-progress --optimize-autoloader --prefer-dist","WORKING_DIR":"./themes/example/"},"run":"composer install --working-dir=\"$WORKING_DIR\" $COMPOSER_ARGS"}'
    check "composer: install gets the caller's composer-args" equals "$(composer_step $RSYNC rsync-composer-overrides $type | jq -r .env.COMPOSER_ARGS)" "--no-dev --no-interaction"
    check "composer: php-actions/composer no longer runs" no_php_actions_composer $RSYNC rsync-composer-defaults $type
    check "no composer: setup-php doesn't run" equals "$(setup_php $RSYNC rsync-no-composer $type)" "null"
done

case_start "deploy-via-ftp.yaml"
check "composer: PHP 8.5 with mbstring by default" equals "$(setup_php $FTP ftp-composer-defaults)" "$DEFAULT_SETUP"
check "composer: php-version and php-extensions are passed through" equals "$(setup_php $FTP ftp-composer-overrides)" "$OVERRIDE_SETUP"
check "composer: PHP is set up before composer install" equals "$(order $FTP ftp-composer-defaults)" "$ORDER"
check "composer: install runs with the same args as before" equals "$(composer_step $FTP ftp-composer-defaults | jq -r .run)" \
    "composer install --no-dev --no-interaction --no-progress --optimize-autoloader --prefer-dist"
check "composer: php-actions/composer no longer runs" no_php_actions_composer $FTP ftp-composer-defaults
check "no composer: setup-php doesn't run" equals "$(setup_php $FTP ftp-no-composer)" "null"

finish
