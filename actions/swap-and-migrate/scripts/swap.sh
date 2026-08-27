#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# swap.sh — Atomic deploy: migrations + component swap
#
# Uploaded to the server by the swap-and-migrate action on each deploy.
# Do not copy or edit this file per-project — changes belong in the action.
#
# Migrations run directly against the live tables, in maintenance mode, with
# no table clone, prefix switch, or automated backup — a dry run against a
# disposable structure-only clone is the only pre-flight check before that
# happens. If a migration fails partway through, there is nothing to revert
# to automatically; the site stays in maintenance mode for manual recovery.
# Take a full site backup before deploying migrations, and confirm the
# patches against a staging copy first.
#
# Injected by the action:
#   WP_ROOT    Absolute path to the WordPress root (e.g. /home/piecode/site/public_html)
#   GIT_SHA    Git commit SHA for this deployment (8-character short SHA is acceptable)
#   REPO_NAME  GitHub repository name (used to derive migrations table name)
#
# Components are read from components.txt in the same directory, written by the
# action before this script runs. Format: one "type:name" entry per line.
# ==============================================================================

SHORT_SHA="${GIT_SHA:0:8}"
RELEASES_DIR="${RELEASES_DIR:-$WP_ROOT/releases}"
NEW_RELEASE_DIR="$RELEASES_DIR/$GIT_SHA"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIGRATE_SCRIPT="$SCRIPT_DIR/migrate.sh"
QUERIES_DIR="$SCRIPT_DIR/queries"
HAS_MIGRATIONS=false
MAINTENANCE_ACTIVE=false
SAFE_TO_RECOVER=true

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# Fires on any non-zero exit via set -euo pipefail.
#
# If maintenance mode was never activated, nothing to do.
# If activated and migrations haven't started yet (dry run only, or none
# pending), it is safe to deactivate — the live site is unmodified. Exit 1.
# If activated and migrations have started (SAFE_TO_RECOVER=false), the site
# must stay in maintenance mode until manually verified — there is no clone
# or automated backup to recover from. Exit 2.
cleanup() {
    local EXIT_CODE=$?
    [ $EXIT_CODE -eq 0 ] && return
    if [ "$MAINTENANCE_ACTIVE" = true ]; then
        if [ "$SAFE_TO_RECOVER" = true ]; then
            log "Deploy failed before live changes — deactivating maintenance mode"
            wp maintenance-mode deactivate --path="$WP_ROOT" || true
            exit 1
        else
            log "ERROR: Deploy failed after live changes began — site is in maintenance mode"
            log "ERROR: Migrations may have applied only partially — before deactivating maintenance mode, verify:"
            log "ERROR:   wp db query \"SELECT * FROM \`$MIGRATIONS_TABLE\` ORDER BY id DESC LIMIT 5\" --path=\"$WP_ROOT\""
            log "ERROR:   ls -la $WP_ROOT/wp-content/plugins/ $WP_ROOT/wp-content/themes/"
            exit 2
        fi
    fi
    exit $EXIT_CODE
}
trap cleanup EXIT

# ==============================================================================
# Step 1: Pre-flight checks
# ==============================================================================

log "Atomic deploy starting — SHA: $GIT_SHA"

if [[ "$WP_ROOT" != '/'* ]]; then
    echo "ERROR: WP_ROOT must be an absolute path starting with / (e.g. /home/piecode/site/public_html)." >&2
    exit 1
fi

if ! command -v wp &>/dev/null; then
    echo "ERROR: wp-cli is not available on this server" >&2
    exit 1
fi

log "Verifying database connectivity"
wp db check --path="$WP_ROOT"

CURRENT_PREFIX=$(wp config get table_prefix --path="$WP_ROOT")

# CURRENT_PREFIX is interpolated into SQL string literals and identifiers
# below. WordPress's own installer already restricts table_prefix to this
# character set — enforcing it here means a misconfigured wp-config.php fails
# cleanly instead of corrupting a query or behaving like injected SQL.
if [[ ! "$CURRENT_PREFIX" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    echo "ERROR: table_prefix '$CURRENT_PREFIX' contains unexpected characters — refusing to use it in SQL. Expected only letters, digits, and underscores, not starting with a digit." >&2
    exit 1
fi

# REPO_SLUG is embedded into the migrations tracking table name alongside
# CURRENT_PREFIX. MySQL caps identifiers at 64 characters, so cap REPO_SLUG
# to whatever's left, instead of a flat cut that ignores the prefix entirely.
MIGRATIONS_SUFFIX="_migrations"
MAX_SLUG_LEN=$(( 64 - ${#CURRENT_PREFIX} - ${#MIGRATIONS_SUFFIX} ))
if [ "$MAX_SLUG_LEN" -lt 1 ]; then
    echo "ERROR: table_prefix '$CURRENT_PREFIX' is too long to derive a migrations table name within MySQL's 64-character identifier limit." >&2
    exit 1
fi
REPO_SLUG="$(printf '%s' "$REPO_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g' | cut -c1-"$MAX_SLUG_LEN")"

MIGRATIONS_TABLE="${CURRENT_PREFIX}${REPO_SLUG}_migrations"

if [ ! -d "$NEW_RELEASE_DIR" ]; then
    echo "ERROR: Release directory $NEW_RELEASE_DIR not found — did all rsync jobs complete?" >&2
    exit 1
fi

COMPONENTS_FILE="$SCRIPT_DIR/components.txt"
if [ ! -f "$COMPONENTS_FILE" ]; then
    echo "ERROR: components.txt not found at $COMPONENTS_FILE" >&2
    exit 1
fi

readarray -t COMPONENTS < <(grep -v '^[[:space:]]*$' "$COMPONENTS_FILE")

if [ "${#COMPONENTS[@]}" -eq 0 ]; then
    echo "ERROR: No components defined in components.txt" >&2
    exit 1
fi

# TYPE and NAME are extracted from each entry below and built into paths that
# are later passed to mv/rm -rf. Restricting to slug-safe characters up front
# rules out a stray '/' or '..' steering those destructive calls outside
# wp-content/, however the entry ended up malformed.
for COMPONENT in "${COMPONENTS[@]}"; do
    if [[ ! "$COMPONENT" =~ ^[A-Za-z0-9_-]+:[A-Za-z0-9_-]+$ ]]; then
        echo "ERROR: Invalid component entry '$COMPONENT' — expected type:name using only letters, digits, hyphens, and underscores." >&2
        exit 1
    fi
done

log "Validating component release paths"
for COMPONENT in "${COMPONENTS[@]}"; do
    NAME="${COMPONENT##*:}"
    RELEASE_PATH="$NEW_RELEASE_DIR/$NAME"
    if [ ! -d "$RELEASE_PATH" ]; then
        echo "ERROR: $RELEASE_PATH not found — did the rsync job for $NAME complete?" >&2
        exit 1
    fi
done

# ==============================================================================
# Step 2: Detect pending migrations
# ==============================================================================

PENDING_FILES=()

if [ -d "$QUERIES_DIR" ]; then
    APPLIED=$(wp db query \
        "SELECT filename FROM \`$MIGRATIONS_TABLE\`" \
        --path="$WP_ROOT" --skip-column-names 2>/dev/null || echo "")

    while IFS= read -r SQL_FILE; do
        FILENAME=$(basename "$SQL_FILE")
        if ! echo "$APPLIED" | grep -qxF "$FILENAME"; then
            PENDING_FILES+=("$SQL_FILE")
        fi
    done < <(find "$QUERIES_DIR" -maxdepth 1 -name "*.sql" | sort)
fi

if [ "${#PENDING_FILES[@]}" -gt 0 ]; then
    HAS_MIGRATIONS=true
    log "${#PENDING_FILES[@]} pending migration(s) found"
else
    log "No pending migrations"
fi

# ==============================================================================
# Step 3: Database migrations — applied directly against the live tables
# ==============================================================================

if [ "$HAS_MIGRATIONS" = true ]; then

    log "Enabling maintenance mode"
    wp maintenance-mode activate --path="$WP_ROOT"
    MAINTENANCE_ACTIVE=true

    # ------------------------------------------------------------------
    # Dry run: validate pending migration patches before touching live
    # tables. Patches are applied to structure-only clones of the live
    # tables (columns/indexes, no rows) under a throwaway prefix, then
    # those clones are dropped immediately. This is the only pre-flight
    # check before migrations run directly against production — there is
    # no table clone or backup to fall back to if a patch turns out to be
    # broken. A data-dependent patch (e.g. an UPDATE matching on row
    # content) can still pass here and fail for other reasons later,
    # since no rows exist yet to match against.
    # ------------------------------------------------------------------
    log "Dry run: validating ${#PENDING_FILES[@]} pending migration(s) against a structure-only clone"

    DRYRUN_PREFIX="dryrun_${SHORT_SHA}_"
    DRYRUN_SOURCE_TABLES=$(wp db query \
        "SELECT table_name FROM information_schema.tables \
         WHERE table_schema = DATABASE() \
         AND LEFT(table_name, CHAR_LENGTH('${CURRENT_PREFIX}')) = '${CURRENT_PREFIX}'" \
        --path="$WP_ROOT" --skip-column-names)

    set +e
    DRYRUN_FAILED=false

    # Clear any remnants from a previous failed attempt at this SHA, then clone structure only.
    while IFS= read -r TABLE; do
        [ -z "$TABLE" ] && continue
        DRYRUN_TABLE="${DRYRUN_PREFIX}${TABLE#$CURRENT_PREFIX}"
        wp db query "DROP TABLE IF EXISTS \`$DRYRUN_TABLE\`" --path="$WP_ROOT" || true
        wp db query "CREATE TABLE \`$DRYRUN_TABLE\` LIKE \`$TABLE\`" --path="$WP_ROOT" || DRYRUN_FAILED=true
    done <<< "$DRYRUN_SOURCE_TABLES"

    if [ "$DRYRUN_FAILED" = false ]; then
        for SQL_FILE in "${PENDING_FILES[@]}"; do
            FILENAME=$(basename "$SQL_FILE")
            log "Dry run: applying $FILENAME"
            if ! sed "s/__WP_PREFIX__/${DRYRUN_PREFIX}/g" "$SQL_FILE" | wp db query --path="$WP_ROOT"; then
                echo "ERROR: Dry run failed applying $FILENAME" >&2
                DRYRUN_FAILED=true
                break
            fi
        done
    fi

    log "Dry run: cleaning up scratch tables"
    while IFS= read -r TABLE; do
        [ -z "$TABLE" ] && continue
        DRYRUN_TABLE="${DRYRUN_PREFIX}${TABLE#$CURRENT_PREFIX}"
        wp db query "DROP TABLE IF EXISTS \`$DRYRUN_TABLE\`" --path="$WP_ROOT" || true
    done <<< "$DRYRUN_SOURCE_TABLES"
    set -e

    if [ "$DRYRUN_FAILED" = true ]; then
        echo "ERROR: Dry run detected a migration failure — bailing out before touching live tables. No live data was touched." >&2
        exit 1
    fi

    log "Dry run passed"

    # ------------------------------------------------------------------
    # Point of no return — migrations are about to run against the live
    # tables directly, with no clone or backup to fall back to. Any
    # failure from here requires manual verification before the site can
    # safely come back up. The cleanup trap exits 2 if MAINTENANCE_ACTIVE
    # is true and SAFE_TO_RECOVER is false.
    # ------------------------------------------------------------------
    SAFE_TO_RECOVER=false

    log "Applying migrations against live tables (prefix '$CURRENT_PREFIX')"
    WP_ROOT="$WP_ROOT" \
    MIGRATIONS_TABLE="$MIGRATIONS_TABLE" \
    TARGET_PREFIX="$CURRENT_PREFIX" \
    BATCH="$SHORT_SHA" \
        bash "$MIGRATE_SCRIPT"

    log "Database migrations complete"
fi

# ==============================================================================
# Step 4: Component swap
#
# Each component is rsynced to a hidden staging directory, then atomically
# renamed into place. WordPress ignores directories starting with '.', so
# the staging copy is never served during the transfer.
# ==============================================================================

log "Deploying components for release $GIT_SHA"

mkdir -p "$RELEASES_DIR"

for COMPONENT in "${COMPONENTS[@]}"; do
    TYPE="${COMPONENT%%:*}"
    NAME="${COMPONENT##*:}"
    LIVE_PATH="$WP_ROOT/wp-content/$TYPE/$NAME"
    RELEASE_PATH="$NEW_RELEASE_DIR/$NAME"
    STAGING_PATH="${LIVE_PATH}.deploying"
    OLD_PATH="${LIVE_PATH}.previous"

    # Clear any remnants from a previous failed deploy
    rm -rf "$STAGING_PATH" "$OLD_PATH"

    # Rsync to a hidden staging directory not yet visible to WordPress
    mkdir -p "$STAGING_PATH"
    rsync -a --delete "$RELEASE_PATH/" "$STAGING_PATH/"

    # Atomic rename: live → .previous, staging → live
    if [ -e "$LIVE_PATH" ] || [ -L "$LIVE_PATH" ]; then
        mv "$LIVE_PATH" "$OLD_PATH"
    fi
    mv "$STAGING_PATH" "$LIVE_PATH"
    rm -rf "$OLD_PATH"

    log "  $TYPE/$NAME -> $RELEASE_PATH"
done

# ==============================================================================
# Step 5: Disable maintenance mode
#
# Done before pruning so the site comes back up even if cleanup fails.
# MAINTENANCE_ACTIVE is set to false regardless — the cleanup trap must not
# attempt a second deactivation after this point.
# ==============================================================================

if [ "$MAINTENANCE_ACTIVE" = true ]; then
    log "Disabling maintenance mode"
    if ! wp maintenance-mode deactivate --path="$WP_ROOT"; then
        log "ERROR: Failed to deactivate maintenance mode — run manually:"
        log "ERROR:   wp maintenance-mode deactivate --path=\"$WP_ROOT\""
        exit 2
    fi
    MAINTENANCE_ACTIVE=false
fi

# ==============================================================================
# Step 6: Prune old releases — keep current + 1 prior
# ==============================================================================

log "Pruning old releases"

while IFS= read -r OLD_RELEASE; do
    log "  Removing $OLD_RELEASE"
    rm -rf "$OLD_RELEASE" || log "WARN: Could not remove $OLD_RELEASE — manual cleanup may be needed"
done < <(find "$RELEASES_DIR" -maxdepth 1 -mindepth 1 -type d \
    ! -name "$GIT_SHA" ! -name "initial" \
    -printf '%T@ %p\n' | sort -rn | tail -n +2 | cut -d' ' -f2-)

log "Atomic deploy complete — $GIT_SHA is live"
