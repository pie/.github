#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# rollback.sh — Manual rollback of the most recent migration batch
#
# Uploaded to the server by the swap-and-migrate action on every deploy,
# alongside swap.sh and migrate.sh, at releases/{sha}/migrations/rollback.sh —
# it is never run automatically. Invoke it by hand over SSH when you need to
# undo the DB changes from the most recent deploy:
#
#   env WP_ROOT=/path/to/site \
#       MIGRATIONS_TABLE=wp_myrepo_migrations \
#       TARGET_PREFIX=wp_ \
#       bash releases/<sha>/migrations/rollback.sh
#
# WP_ROOT/MIGRATIONS_TABLE/TARGET_PREFIX are the same values swap.sh used for
# that deploy — check its log output, or derive them the same way swap.sh
# does (table_prefix + sanitised repo name + "_migrations").
#
# Runs directly against the live tables — same as migrate.sh, there is no
# clone or backup here. Only migrations whose file has a "-- +migrate Down"
# section are reverted, in reverse order of application; anything without one
# is left as-is (its schema change stays in place, logged clearly) rather
# than guessing at an undo or failing the whole run. A migration is only
# marked as rolled back (its tracking row removed) once its Down section has
# actually run successfully, so a failure partway through a batch leaves an
# accurate record of what's still applied — re-running this script picks up
# from there.
#
# Down only reverses schema shape, not data a migration deleted or
# transformed — restore from your own backup for that.
#
# Injected (same as migrate.sh):
#   WP_ROOT           Absolute path to the WordPress root
#   MIGRATIONS_TABLE  Tracking table name
#   TARGET_PREFIX     Table prefix to target
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUERIES_DIR="$SCRIPT_DIR/queries"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# Extracts the "Up" or "Down" section from a migration file. A file with no
# "-- +migrate Up" marker at all is treated as one plain Up-only migration —
# prints the whole file for "up", nothing for "down".
extract_section() {
    local file="$1" section="$2"
    if [ "$section" = "down" ]; then
        if ! grep -q '^-- +migrate Down[[:space:]]*$' "$file"; then
            return 0
        fi
        awk '/^-- \+migrate Down[[:space:]]*$/{flag=1; next} flag' "$file"
    else
        if ! grep -q '^-- +migrate Up[[:space:]]*$' "$file"; then
            cat "$file"
            return 0
        fi
        awk '/^-- \+migrate Up[[:space:]]*$/{flag=1; next} /^-- \+migrate Down[[:space:]]*$/{flag=0} flag' "$file"
    fi
}

if [ ! -d "$QUERIES_DIR" ]; then
    log "No queries directory found — nothing to roll back"
    exit 0
fi

# COUNT(*) always returns exactly one row, even when it's 0 — wp db query
# falls back to printing a generic status line instead of nothing for a
# SELECT that matches zero rows, which a direct "is this empty" check on a
# LIMIT 1 query could mistake for real output. Gate on the count first.
MIGRATION_COUNT=$(wp db query \
    "SELECT COUNT(*) FROM \`$MIGRATIONS_TABLE\`" \
    --path="$WP_ROOT" --skip-column-names 2>/dev/null || echo "0")

if [ -z "$MIGRATION_COUNT" ] || [ "$MIGRATION_COUNT" -eq 0 ]; then
    log "No applied migrations found — nothing to roll back"
    exit 0
fi

BATCH=$(wp db query \
    "SELECT batch FROM \`$MIGRATIONS_TABLE\` ORDER BY id DESC LIMIT 1" \
    --path="$WP_ROOT" --skip-column-names)

log "Rolling back batch '$BATCH'"

SAFE_BATCH=$(printf '%s' "$BATCH" | sed "s/'/''/g")
FILENAMES=$(wp db query \
    "SELECT filename FROM \`$MIGRATIONS_TABLE\` WHERE batch = '$SAFE_BATCH' ORDER BY id DESC" \
    --path="$WP_ROOT" --skip-column-names)

while IFS= read -r FILENAME; do
    [ -z "$FILENAME" ] && continue
    SQL_FILE="$QUERIES_DIR/$FILENAME"

    if [ ! -f "$SQL_FILE" ]; then
        log "WARN: $FILENAME is recorded as applied but its file is missing from queries/ — skipping, tracking row left as-is"
        continue
    fi

    DOWN_SQL=$(extract_section "$SQL_FILE" down)

    if [ -z "$DOWN_SQL" ]; then
        log "  $FILENAME has no '-- +migrate Down' section — leaving its change in place, skipping"
        continue
    fi

    log "Reverting $FILENAME"
    printf '%s\n' "$DOWN_SQL" | sed "s/__WP_PREFIX__/${TARGET_PREFIX}/g" | wp db query --path="$WP_ROOT"

    SAFE_FILENAME=$(printf '%s' "$FILENAME" | sed "s/'/''/g")
    wp db query \
        "DELETE FROM \`$MIGRATIONS_TABLE\` WHERE filename = '$SAFE_FILENAME'" \
        --path="$WP_ROOT"

    log "  Reverted: $FILENAME"
done <<< "$FILENAMES"

log "Rollback of batch '$BATCH' complete"
