#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# migrate.sh — Database migration runner
#
# Uploaded to the server by the swap-and-migrate action on each deploy.
# Do not copy or edit this file per-project — changes belong in the action.
# See the README for design rationale — comments below are just flow notes.
#
# Called as a subprocess from swap.sh. Applies pending SQL migrations
# directly against the live tables. Migration files use __WP_PREFIX__ as a
# placeholder for the table prefix, replaced with TARGET_PREFIX before
# execution. Files may split into "-- +migrate Up"/"-- +migrate Down"
# sections — only Up runs here; Down is for rollback.sh. No markers at all
# = treated as Up-only.
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
#   BATCH             Full commit SHA grouping this deploy's migrations —
#                      rollback.sh undoes one batch at a time
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QUERIES_DIR="$SCRIPT_DIR/queries"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# Extracts the "up" or "down" section from a migration file. No markers at
# all = treated as one plain up-only migration.
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
# Step 1: Ensure tracking table exists, with a wide-enough batch column
# ==============================================================================

wp db query "
    CREATE TABLE IF NOT EXISTS \`$MIGRATIONS_TABLE\` (
        id         INT AUTO_INCREMENT PRIMARY KEY,
        filename   VARCHAR(255) NOT NULL UNIQUE,
        batch      VARCHAR(40)  NOT NULL DEFAULT '',
        applied_at DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP
    )
" --path="$WP_ROOT"

# No "ADD COLUMN IF NOT EXISTS" — not portable to MySQL 5.7. Check via
# information_schema instead, and widen an existing-but-narrower column
# (tables from an earlier version of this script have VARCHAR(8)).
BATCH_COLUMN_LENGTH=$(wp db query \
    "SELECT COALESCE(CHARACTER_MAXIMUM_LENGTH, 0) FROM information_schema.COLUMNS \
     WHERE TABLE_SCHEMA = DATABASE() \
     AND TABLE_NAME = '$MIGRATIONS_TABLE' \
     AND COLUMN_NAME = 'batch'" \
    --path="$WP_ROOT" --skip-column-names)

if [ "$BATCH_COLUMN_LENGTH" -eq 0 ]; then
    wp db query "ALTER TABLE \`$MIGRATIONS_TABLE\` ADD COLUMN batch VARCHAR(40) NOT NULL DEFAULT '' AFTER filename" --path="$WP_ROOT"
elif [ "$BATCH_COLUMN_LENGTH" -lt 40 ]; then
    wp db query "ALTER TABLE \`$MIGRATIONS_TABLE\` MODIFY COLUMN batch VARCHAR(40) NOT NULL DEFAULT ''" --path="$WP_ROOT"
fi

# ==============================================================================
# Step 2: Find pending migrations
# ==============================================================================

if [ ! -d "$QUERIES_DIR" ]; then
    log "No queries directory found — nothing to migrate"
    exit 0
fi

# No error-swallowing here — the table's existence is already guaranteed by
# Step 1, so a failure means a real problem and must propagate via set -e,
# not get treated as "nothing applied" (which would replay every migration).
APPLIED=$(wp db query \
    "SELECT filename FROM \`$MIGRATIONS_TABLE\`" \
    --path="$WP_ROOT" --skip-column-names)

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
    # DDL can't be wrapped in the same transaction as this INSERT — MySQL
    # commits it immediately regardless. If recording fails here, the schema
    # change already landed but isn't tracked; a blind retry would treat it
    # as still pending and re-run its Up section. Name the exact fix instead
    # of letting this propagate as an unexplained failure.
    if ! wp db query \
        "INSERT INTO \`$MIGRATIONS_TABLE\` (filename, batch) VALUES ('$SAFE_FILENAME', '$SAFE_BATCH')" \
        --path="$WP_ROOT"; then
        echo "ERROR: $FILENAME's schema change succeeded, but recording it in $MIGRATIONS_TABLE failed." >&2
        echo "ERROR: Retrying this deploy as-is would re-run $FILENAME's Up section. Before retrying, either:" >&2
        echo "ERROR:   1. Manually run: INSERT INTO \`$MIGRATIONS_TABLE\` (filename, batch) VALUES ('$SAFE_FILENAME', '$SAFE_BATCH');" >&2
        echo "ERROR:   2. Or confirm $FILENAME's Up section is safe to run twice before deploying again." >&2
        exit 1
    fi

    log "  Applied: $FILENAME"
done

log "All migrations applied"
