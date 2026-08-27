#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# rollback.sh — Reverts the most recently applied batch of database migrations
#
# Uploaded fresh to the server by the rollback-migrations action each time it
# runs — this is not part of a regular deploy, and nothing is left behind
# afterward.
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
# Injected by the action:
#   WP_ROOT    Absolute path to the WordPress root
#   REPO_NAME  GitHub repository name — the migrations table name is derived
#              from this the same way swap.sh does, so this always finds the
#              same tracking table a deploy would have used.
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

TARGET_PREFIX=$(wp config get table_prefix --path="$WP_ROOT")

# Same validation as swap.sh — TARGET_PREFIX is interpolated into SQL below.
if [[ ! "$TARGET_PREFIX" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    echo "ERROR: table_prefix '$TARGET_PREFIX' contains unexpected characters — refusing to use it in SQL. Expected only letters, digits, and underscores, not starting with a digit." >&2
    exit 1
fi

# Same derivation as swap.sh, so this always resolves to the same tracking
# table a deploy would have used.
MIGRATIONS_SUFFIX="_migrations"
MAX_SLUG_LEN=$(( 64 - ${#TARGET_PREFIX} - ${#MIGRATIONS_SUFFIX} ))
if [ "$MAX_SLUG_LEN" -lt 1 ]; then
    echo "ERROR: table_prefix '$TARGET_PREFIX' is too long to derive a migrations table name within MySQL's 64-character identifier limit." >&2
    exit 1
fi
REPO_SLUG="$(printf '%s' "$REPO_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g' | cut -c1-"$MAX_SLUG_LEN")"
MIGRATIONS_TABLE="${TARGET_PREFIX}${REPO_SLUG}_migrations"

if [ ! -d "$QUERIES_DIR" ]; then
    log "No queries directory found — nothing to roll back"
    exit 0
fi

# The batch column is normally added by migrate.sh, but only as a side
# effect of a deploy that has a pending migration to apply — this script
# can't assume that has already happened by the time it runs, so it ensures
# both the table and the column exist itself, the same way migrate.sh does.
wp db query "
    CREATE TABLE IF NOT EXISTS \`$MIGRATIONS_TABLE\` (
        id         INT AUTO_INCREMENT PRIMARY KEY,
        filename   VARCHAR(255) NOT NULL UNIQUE,
        batch      VARCHAR(8)   NOT NULL DEFAULT '',
        applied_at DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP
    )
" --path="$WP_ROOT"

wp db query "ALTER TABLE \`$MIGRATIONS_TABLE\` ADD COLUMN IF NOT EXISTS batch VARCHAR(8) NOT NULL DEFAULT '' AFTER filename" --path="$WP_ROOT"

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
