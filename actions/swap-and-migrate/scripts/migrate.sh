#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# migrate.sh — Database migration runner
#
# Uploaded to the server by the swap-and-migrate action on each deploy.
# Do not copy or edit this file per-project — changes belong in the action.
#
# Called as a subprocess from swap.sh during an atomic deploy. Applies pending
# SQL migrations directly against the live tables — there is no clone or
# backup to fall back to if a migration fails partway through.
#
# Migration files must use __WP_PREFIX__ as a placeholder for the table prefix.
# This token is replaced with TARGET_PREFIX before execution, ensuring only
# explicit prefix references are rewritten — never string literals or comments
# that happen to contain the prefix substring.
#
# A migration file may optionally split its SQL into "-- +migrate Up" and
# "-- +migrate Down" sections — only the Up section runs here (Down is used
# by rollback.sh, uploaded alongside this file but never run automatically).
# A file with no markers at all is treated as Up-only, for migrations written
# before this convention existed.
#
# Example:
#   -- +migrate Up
#   ALTER TABLE __WP_PREFIX__posts ADD COLUMN source VARCHAR(255);
#
#   -- +migrate Down
#   ALTER TABLE __WP_PREFIX__posts DROP COLUMN source;
#
# Injected by swap.sh:
#   WP_ROOT           Absolute path to the WordPress root
#   MIGRATIONS_TABLE  Tracking table name (pre-computed by swap.sh)
#   TARGET_PREFIX     Table prefix to target — the live prefix (e.g. wp_)
#   BATCH             Identifier grouping migrations applied by this deploy
#                      (the deploy's short SHA) — rollback.sh undoes one
#                      batch at a time.
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

# ==============================================================================
# Step 1: Ensure tracking table exists (and carries the batch column, for
# tables created before that column existed).
# ==============================================================================

wp db query "
    CREATE TABLE IF NOT EXISTS \`$MIGRATIONS_TABLE\` (
        id         INT AUTO_INCREMENT PRIMARY KEY,
        filename   VARCHAR(255) NOT NULL UNIQUE,
        batch      VARCHAR(8)   NOT NULL DEFAULT '',
        applied_at DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP
    )
" --path="$WP_ROOT"

wp db query "ALTER TABLE \`$MIGRATIONS_TABLE\` ADD COLUMN IF NOT EXISTS batch VARCHAR(8) NOT NULL DEFAULT '' AFTER filename" --path="$WP_ROOT"

# ==============================================================================
# Step 2: Find pending migrations
# ==============================================================================

if [ ! -d "$QUERIES_DIR" ]; then
    log "No queries directory found — nothing to migrate"
    exit 0
fi

APPLIED=$(wp db query \
    "SELECT filename FROM \`$MIGRATIONS_TABLE\`" \
    --path="$WP_ROOT" --skip-column-names 2>/dev/null || echo "")

PENDING=()
while IFS= read -r SQL_FILE; do
    FILENAME=$(basename "$SQL_FILE")
    if ! echo "$APPLIED" | grep -qxF "$FILENAME"; then
        PENDING+=("$SQL_FILE")
    fi
done < <(find "$QUERIES_DIR" -maxdepth 1 -name "*.sql" | sort)

if [ "${#PENDING[@]}" -eq 0 ]; then
    log "No pending migrations"
    exit 0
fi

log "${#PENDING[@]} migration(s) to apply"

# ==============================================================================
# Step 3: Apply pending migrations against the live tables
# ==============================================================================

SAFE_BATCH=$(printf '%s' "$BATCH" | sed "s/'/''/g")

for SQL_FILE in "${PENDING[@]}"; do
    FILENAME=$(basename "$SQL_FILE")
    log "Applying $FILENAME"

    extract_section "$SQL_FILE" up \
        | sed "s/__WP_PREFIX__/${TARGET_PREFIX}/g" \
        | wp db query --path="$WP_ROOT"

    SAFE_FILENAME=$(printf '%s' "$FILENAME" | sed "s/'/''/g")
    wp db query \
        "INSERT INTO \`$MIGRATIONS_TABLE\` (filename, batch) VALUES ('$SAFE_FILENAME', '$SAFE_BATCH')" \
        --path="$WP_ROOT"

    log "  Applied: $FILENAME"
done

log "All migrations applied"
