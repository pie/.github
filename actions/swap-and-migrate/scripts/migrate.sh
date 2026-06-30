#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# migrate.sh — Database migration runner
#
# Uploaded to the server by the swap-and-migrate action on each deploy.
# Do not copy or edit this file per-project — changes belong in the action.
#
# Called as a subprocess from swap.sh during an atomic deploy. Applies pending
# SQL migrations against the copied tables (NEW_PREFIX), so the live database
# is never touched until the prefix switch succeeds in swap.sh.
#
# Migration files must use __WP_PREFIX__ as a placeholder for the table prefix.
# This token is replaced with NEW_PREFIX before execution, ensuring only
# explicit prefix references are rewritten — never string literals or comments
# that happen to contain the prefix substring.
#
# Example:  ALTER TABLE __WP_PREFIX__posts ADD COLUMN source VARCHAR(255);
#
# Injected by swap.sh:
#   WP_ROOT           Absolute path to the WordPress root
#   MIGRATIONS_TABLE  Tracking table name (pre-computed by swap.sh)
#   NEW_PREFIX        New prefix to target (e.g. wp_a1b2c3d4_)
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUERIES_DIR="$SCRIPT_DIR/queries"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# ==============================================================================
# Step 1: Ensure tracking table exists
# ==============================================================================

wp db query "
    CREATE TABLE IF NOT EXISTS \`$MIGRATIONS_TABLE\` (
        id         INT AUTO_INCREMENT PRIMARY KEY,
        filename   VARCHAR(255) NOT NULL UNIQUE,
        applied_at DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP
    )
" --path="$WP_ROOT"

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
    if ! echo "$APPLIED" | grep -qF "$FILENAME"; then
        PENDING+=("$SQL_FILE")
    fi
done < <(find "$QUERIES_DIR" -maxdepth 1 -name "*.sql" | sort)

if [ "${#PENDING[@]}" -eq 0 ]; then
    log "No pending migrations"
    exit 0
fi

log "${#PENDING[@]} migration(s) to apply"

# ==============================================================================
# Step 3: Apply pending migrations against the copied tables
# ==============================================================================

for SQL_FILE in "${PENDING[@]}"; do
    FILENAME=$(basename "$SQL_FILE")
    log "Applying $FILENAME"

    sed "s/__WP_PREFIX__/${NEW_PREFIX}/g" "$SQL_FILE" \
        | wp db query --path="$WP_ROOT"

    SAFE_FILENAME=$(printf '%s' "$FILENAME" | sed "s/'/''/g")
    wp db query \
        "INSERT INTO \`$MIGRATIONS_TABLE\` (filename) VALUES ('$SAFE_FILENAME')" \
        --path="$WP_ROOT"

    log "  Applied: $FILENAME"
done

log "All migrations applied"
