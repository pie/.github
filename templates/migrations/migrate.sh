#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# migrate.sh — Database migration runner
#
# Called as a subprocess from swap.sh during an atomic deploy. Applies pending
# SQL migrations against the copied tables (NEW_PREFIX), so the live database
# is never touched until the prefix switch succeeds in swap.sh.
#
# Injected by swap.sh:
#   WP_ROOT           Absolute path to the WordPress root
#   MIGRATIONS_TABLE  Tracking table name (pre-computed by swap.sh)
#   CURRENT_PREFIX    Current WP table prefix  (e.g. wp_)
#   NEW_PREFIX        New prefix to target      (e.g. wp_a1b2c3d4_)
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

    sed "s/${CURRENT_PREFIX}/${NEW_PREFIX}/g" "$SQL_FILE" \
        | wp db query --path="$WP_ROOT"

    SAFE_FILENAME=$(printf '%s' "$FILENAME" | sed "s/'/''/g")
    wp db query \
        "INSERT INTO \`$MIGRATIONS_TABLE\` (filename) VALUES ('$SAFE_FILENAME')" \
        --path="$WP_ROOT"

    log "  Applied: $FILENAME"
done

log "All migrations applied"
