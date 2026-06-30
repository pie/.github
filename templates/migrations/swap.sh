#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# swap.sh — Atomic deploy: migrations + symlink swap
#
# Called remotely by the swap-and-migrate GitHub Action. Runs in a single SSH
# session. set -euo pipefail means any failure exits immediately — if that
# happens after maintenance mode is activated, the site stays down rather than
# coming back up in a broken state.
#
# Injected by the action:
#   WP_ROOT      Absolute path to the WordPress root (e.g. ~/site/public_html)
#   GIT_SHA      Full git commit SHA for this deployment
#   REPO_NAME    GitHub repository name (used to derive migrations table name)
#
# Copy this file into your project's migrations/ directory and update the
# COMPONENTS array below. Do not edit below the configuration section.
# ==============================================================================

# ==============================================================================
# PROJECT CONFIGURATION — edit this section only
# ==============================================================================

# Format: "type:directory-name" — type must be "plugins" or "themes"
COMPONENTS=(
    "plugins:my-plugin"
    "themes:my-theme"
)

# ==============================================================================
# Generic infrastructure — do not edit below this line
# ==============================================================================

SHORT_SHA="${GIT_SHA:0:8}"
RELEASES_DIR="$(dirname "$WP_ROOT")/releases"
NEW_RELEASE_DIR="$RELEASES_DIR/$GIT_SHA"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIGRATE_SCRIPT="$SCRIPT_DIR/migrate.sh"
QUERIES_DIR="$SCRIPT_DIR/queries"
MIGRATIONS_TABLE="$(echo "$REPO_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g' | cut -c1-53)_migrations"
HAS_MIGRATIONS=false

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# Uses || true so a failed deactivate call never masks the real error
maintenance_off() {
    log "Disabling maintenance mode"
    wp maintenance-mode deactivate --path="$WP_ROOT" || true
}

# ==============================================================================
# Step 1: Pre-flight checks
# ==============================================================================

log "Atomic deploy starting — SHA: $GIT_SHA"

if ! command -v wp &>/dev/null; then
    echo "ERROR: wp-cli is not available on this server" >&2
    exit 1
fi

log "Verifying database connectivity"
wp db check --path="$WP_ROOT"

if [ ! -d "$NEW_RELEASE_DIR" ]; then
    echo "ERROR: Release directory $NEW_RELEASE_DIR not found — did all rsync jobs complete?" >&2
    exit 1
fi

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
        if ! echo "$APPLIED" | grep -qF "$FILENAME"; then
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
# Maintenance mode is activated here. If anything fails from this point on,
# set -euo pipefail exits the script and maintenance mode stays ON — the site
# remains down rather than returning in a broken state.
# ==============================================================================

if [ "$HAS_MIGRATIONS" = true ]; then

    log "Enabling maintenance mode"
    wp maintenance-mode activate --path="$WP_ROOT"

    BACKUP_DIR="$(dirname "$WP_ROOT")/db-backups"
    mkdir -p "$BACKUP_DIR"
    BACKUP_FILE="$BACKUP_DIR/pre_deploy_${SHORT_SHA}_$(date +%Y%m%d%H%M%S).sql"
    log "Exporting database backup to $BACKUP_FILE"
    wp db export "$BACKUP_FILE" --path="$WP_ROOT"

    CURRENT_PREFIX=$(wp config get table_prefix --path="$WP_ROOT")
    NEW_PREFIX="wp_${SHORT_SHA}_"
    log "Copying tables from prefix '$CURRENT_PREFIX' to '$NEW_PREFIX'"

    TABLES=$(wp db query \
        "SELECT table_name FROM information_schema.tables \
         WHERE table_schema = DATABASE() AND table_name LIKE '${CURRENT_PREFIX}%'" \
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
    MIGRATIONS_TABLE="$MIGRATIONS_TABLE" \
    CURRENT_PREFIX="$CURRENT_PREFIX" \
    NEW_PREFIX="$NEW_PREFIX" \
        bash "$MIGRATE_SCRIPT"

    log "Switching wp-config.php table_prefix to '$NEW_PREFIX'"
    wp config set table_prefix "$NEW_PREFIX" --path="$WP_ROOT"

    log "Dropping old tables with prefix '$CURRENT_PREFIX'"
    while IFS= read -r TABLE; do
        [ -z "$TABLE" ] && continue
        wp db query "DROP TABLE IF EXISTS \`$TABLE\`" --path="$WP_ROOT"
    done <<< "$TABLES"

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
    LINK_PATH="$WP_ROOT/wp-content/$TYPE/$NAME"
    RELEASE_PATH="$NEW_RELEASE_DIR/$NAME"

    if [ ! -d "$RELEASE_PATH" ]; then
        echo "ERROR: $RELEASE_PATH not found — did the rsync job for $NAME complete?" >&2
        exit 1
    fi

    if [ -d "$LINK_PATH" ] && [ ! -L "$LINK_PATH" ]; then
        log "  First run: migrating $NAME to releases/initial/"
        mkdir -p "$RELEASES_DIR/initial"
        mv "$LINK_PATH" "$RELEASES_DIR/initial/"
    fi

    ln -sfn "$RELEASE_PATH" "$LINK_PATH"
    log "  $TYPE/$NAME -> $RELEASE_PATH"
done

# ==============================================================================
# Step 5: Prune old releases — keep current + 1 prior
# ==============================================================================

log "Pruning old releases"

while IFS= read -r OLD_RELEASE; do
    log "  Removing $OLD_RELEASE"
    rm -rf "$OLD_RELEASE"
done < <(find "$RELEASES_DIR" -maxdepth 1 -mindepth 1 -type d \
    ! -name "$GIT_SHA" ! -name "initial" \
    -printf '%T@ %p\n' | sort -rn | awk 'NR>1 {print $2}')

# ==============================================================================
# Step 6: Disable maintenance mode
# ==============================================================================

if [ "$HAS_MIGRATIONS" = true ]; then
    maintenance_off
fi

log "Atomic deploy complete — $GIT_SHA is live"
