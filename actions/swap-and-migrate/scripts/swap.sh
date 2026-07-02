#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# swap.sh — Atomic deploy: migrations + symlink swap
#
# Uploaded to the server by the swap-and-migrate action on each deploy.
# Do not copy or edit this file per-project — changes belong in the action.
#
# Injected by the action:
#   WP_ROOT    Absolute path to the WordPress root (e.g. /home/piecode/site/public_html)
#   GIT_SHA    Full git commit SHA for this deployment
#   REPO_NAME  GitHub repository name (used to derive migrations table name)
#
# Components are read from components.txt in the same directory, written by the
# action before this script runs. Format: one "type:name" entry per line.
# ==============================================================================

SHORT_SHA="${GIT_SHA:0:8}"
RELEASES_DIR="${RELEASES_DIR:-$(dirname "$WP_ROOT")/releases}"
NEW_RELEASE_DIR="$RELEASES_DIR/$GIT_SHA"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIGRATE_SCRIPT="$SCRIPT_DIR/migrate.sh"
QUERIES_DIR="$SCRIPT_DIR/queries"
REPO_SLUG="$(printf '%s' "$REPO_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g' | cut -c1-53)"
HAS_MIGRATIONS=false
MAINTENANCE_ACTIVE=false
SAFE_TO_RECOVER=true

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# Fires on any non-zero exit via set -euo pipefail.
#
# If maintenance mode was never activated, nothing to do.
# If activated and we haven't yet touched wp-config or symlinks, it is safe to
# deactivate — the live site is unmodified. Exit 1.
# If activated and live changes have begun (SAFE_TO_RECOVER=false), the site
# must stay in maintenance mode until manually verified. Exit 2.
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
            log "ERROR: Before deactivating maintenance mode, verify:"
            log "ERROR:   wp config get table_prefix --path=\"$WP_ROOT\""
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
LIVE_MIGRATIONS_TABLE="${CURRENT_PREFIX}${REPO_SLUG}_migrations"

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
        "SELECT filename FROM \`$LIVE_MIGRATIONS_TABLE\`" \
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
# Step 3: Database migrations
#
# Prefix derivation and pre-existence check run before the maintenance window
# so a retry collision or bad config fails before any downtime.
# ==============================================================================

if [ "$HAS_MIGRATIONS" = true ]; then

    # Derive the new prefix from the stable base — strip any previous atomic-deploy
    # SHA suffix (8 hex chars + _) so the base never grows across repeated deploys.
    # e.g. wp_ -> wp_abc12345_; foo_abc12345_ -> foo_ -> foo_def67890_
    BASE_PREFIX=$(printf '%s' "$CURRENT_PREFIX" | sed 's/[0-9a-f]\{8\}_$//')
    NEW_PREFIX="${BASE_PREFIX}${SHORT_SHA}_"
    NEW_MIGRATIONS_TABLE="${NEW_PREFIX}${REPO_SLUG}_migrations"
    log "Table prefix: '$CURRENT_PREFIX' -> '$NEW_PREFIX'"

    EXISTING_COUNT=$(wp db query \
        "SELECT COUNT(*) FROM information_schema.tables \
         WHERE table_schema = DATABASE() \
         AND LEFT(table_name, CHAR_LENGTH('${NEW_PREFIX}')) = '${NEW_PREFIX}'" \
        --path="$WP_ROOT" --skip-column-names)

    if [ "$EXISTING_COUNT" -gt 0 ]; then
        echo "ERROR: Tables with prefix '${NEW_PREFIX}' already exist — a previous deploy attempt may have left partial data." >&2
        echo "ERROR: Drop them before retrying:" >&2
        wp db query \
            "SELECT CONCAT('DROP TABLE \`', table_name, '\`;') \
             FROM information_schema.tables \
             WHERE table_schema = DATABASE() \
             AND LEFT(table_name, CHAR_LENGTH('${NEW_PREFIX}')) = '${NEW_PREFIX}'" \
            --path="$WP_ROOT" --skip-column-names >&2
        exit 1
    fi

    log "Enabling maintenance mode"
    wp maintenance-mode activate --path="$WP_ROOT"
    MAINTENANCE_ACTIVE=true

    BACKUP_DIR="$(dirname "$RELEASES_DIR")/db-backups"
    mkdir -p "$BACKUP_DIR"
    BACKUP_FILE="$BACKUP_DIR/pre_deploy_${SHORT_SHA}_$(date +%Y%m%d%H%M%S).sql"
    log "Exporting database backup to $BACKUP_FILE"
    wp db export "$BACKUP_FILE" --path="$WP_ROOT"

    log "Copying tables from prefix '$CURRENT_PREFIX' to '$NEW_PREFIX'"

    TABLES=$(wp db query \
        "SELECT table_name FROM information_schema.tables \
         WHERE table_schema = DATABASE() \
         AND LEFT(table_name, CHAR_LENGTH('${CURRENT_PREFIX}')) = '${CURRENT_PREFIX}'" \
        --path="$WP_ROOT" --skip-column-names)

    while IFS= read -r TABLE; do
        [ -z "$TABLE" ] && continue
        NEW_TABLE="${NEW_PREFIX}${TABLE#$CURRENT_PREFIX}"
        log "  $TABLE -> $NEW_TABLE"
        wp db query "CREATE TABLE \`$NEW_TABLE\` LIKE \`$TABLE\`" --path="$WP_ROOT"
        wp db query "INSERT INTO \`$NEW_TABLE\` SELECT * FROM \`$TABLE\`" --path="$WP_ROOT"
    done <<< "$TABLES"

    log "Applying migrations against new prefix '$NEW_PREFIX'"
    WP_ROOT="$WP_ROOT" \
    MIGRATIONS_TABLE="$NEW_MIGRATIONS_TABLE" \
    NEW_PREFIX="$NEW_PREFIX" \
        bash "$MIGRATE_SCRIPT"

    log "Updating usermeta keys and option names from '$CURRENT_PREFIX' to '$NEW_PREFIX'"
    wp db query "UPDATE \`${NEW_PREFIX}usermeta\` SET meta_key = REPLACE(meta_key, '${CURRENT_PREFIX}', '${NEW_PREFIX}') WHERE LEFT(meta_key, CHAR_LENGTH('${CURRENT_PREFIX}')) = '${CURRENT_PREFIX}'" --path="$WP_ROOT"
    wp db query "UPDATE \`${NEW_PREFIX}options\` SET option_name = REPLACE(option_name, '${CURRENT_PREFIX}', '${NEW_PREFIX}') WHERE LEFT(option_name, CHAR_LENGTH('${CURRENT_PREFIX}')) = '${CURRENT_PREFIX}'" --path="$WP_ROOT"

    # ------------------------------------------------------------------
    # Point of no return — wp-config.php and symlinks are about to change.
    # Any failure from here requires manual verification before the site
    # can safely come back up. The cleanup trap exits 2 if MAINTENANCE_ACTIVE
    # is true and SAFE_TO_RECOVER is false.
    # ------------------------------------------------------------------
    SAFE_TO_RECOVER=false

    log "Switching wp-config.php table_prefix to '$NEW_PREFIX'"
    wp config set table_prefix "$NEW_PREFIX" --path="$WP_ROOT"

    log "Dropping old tables with prefix '$CURRENT_PREFIX'"
    {
        echo "SET FOREIGN_KEY_CHECKS=0;"
        while IFS= read -r TABLE; do
            [ -z "$TABLE" ] && continue
            echo "DROP TABLE IF EXISTS \`$TABLE\`;"
        done <<< "$TABLES"
        echo "SET FOREIGN_KEY_CHECKS=1;"
    } | wp db query --path="$WP_ROOT"

    log "Database migrations complete"
fi

# ==============================================================================
# Step 4: Symlink swap
#
# On first run, if a real directory exists where a symlink is expected, it is
# moved into releases/initial/ and the symlink is created in its place — no
# manual server setup required.
# ==============================================================================

log "Swapping symlinks to release $GIT_SHA"

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
        log "WARN: Failed to deactivate maintenance mode — run manually:"
        log "WARN:   wp maintenance-mode deactivate --path=\"$WP_ROOT\""
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
