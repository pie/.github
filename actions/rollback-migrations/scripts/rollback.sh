#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# rollback.sh — Reverts the most recently applied batch of database migrations
#
# Uploaded fresh to the server by the rollback-migrations action each time it
# runs; nothing is left behind afterward. Runs directly against the live
# tables — same as migrate.sh, no clone or backup. See the README for design
# rationale — comments below are just flow notes.
#
# Only migrations with a "-- +migrate Down" section are reverted, in reverse
# order; anything without one is left as-is and logged. A migration's
# tracking row is only removed once its Down actually succeeds, so a
# failure partway through leaves an accurate record — re-running picks up
# from there. Down reverses schema shape only, not data a migration deleted
# or transformed.
#
# Injected by the action:
#   WP_ROOT    Absolute path to the WordPress root
#   REPO_NAME  GitHub repository name — migrations table name is derived
#              from this the same way swap.sh does
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

if [[ "$WP_ROOT" != '/'* ]] || [ "$WP_ROOT" = "/" ]; then
    echo "ERROR: WP_ROOT must be an absolute path starting with / and not the filesystem root itself (e.g. /home/piecode/site/public_html)." >&2
    exit 1
fi

if ! command -v wp &>/dev/null; then
    echo "ERROR: wp-cli is not available on this server" >&2
    exit 1
fi

log "Verifying database connectivity"
wp db check --path="$WP_ROOT"

TARGET_PREFIX=$(wp config get table_prefix --path="$WP_ROOT")

# Guard against SQL injection via a malformed table_prefix (interpolated below).
if [[ ! "$TARGET_PREFIX" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    echo "ERROR: table_prefix '$TARGET_PREFIX' contains unexpected characters — refusing to use it in SQL. Expected only letters, digits, and underscores, not starting with a digit." >&2
    exit 1
fi

# Byte-for-byte the same derivation as swap.sh — must resolve to the same
# tracking table, or this script rolls back the wrong project's batch.
MIGRATIONS_SUFFIX="_migrations"
REPO_SLUG_RAW="$(printf '%s' "$REPO_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g')"
MAX_SLUG_LEN=$(( 64 - ${#TARGET_PREFIX} - ${#MIGRATIONS_SUFFIX} ))
if [ "$MAX_SLUG_LEN" -lt 1 ]; then
    echo "ERROR: table_prefix '$TARGET_PREFIX' is too long to derive a migrations table name within MySQL's 64-character identifier limit." >&2
    exit 1
fi

if [ "${#REPO_SLUG_RAW}" -gt "$MAX_SLUG_LEN" ]; then
    # Append a hash when truncating so two long, similarly-prefixed repo
    # names can't collide on the same tracking table.
    REPO_HASH="$(printf '%s' "$REPO_NAME" | md5sum | cut -c1-8)"
    TRUNCATE_LEN=$(( MAX_SLUG_LEN - 1 - ${#REPO_HASH} ))
    if [ "$TRUNCATE_LEN" -lt 1 ]; then
        echo "ERROR: table_prefix '$TARGET_PREFIX' is too long to derive a collision-resistant migrations table name within MySQL's 64-character identifier limit." >&2
        exit 1
    fi
    REPO_SLUG="$(printf '%s' "$REPO_SLUG_RAW" | cut -c1-"$TRUNCATE_LEN")_${REPO_HASH}"
else
    REPO_SLUG="$REPO_SLUG_RAW"
fi

MIGRATIONS_TABLE="${TARGET_PREFIX}${REPO_SLUG}_migrations"

if [ ! -d "$QUERIES_DIR" ]; then
    log "No queries directory found — nothing to roll back"
    exit 0
fi

# migrate.sh normally creates/upgrades this table, but only as a side effect
# of a deploy with a pending migration — can't assume that already ran.
wp db query "
    CREATE TABLE IF NOT EXISTS \`$MIGRATIONS_TABLE\` (
        id         INT AUTO_INCREMENT PRIMARY KEY,
        filename   VARCHAR(255) NOT NULL UNIQUE,
        batch      VARCHAR(40)  NOT NULL DEFAULT '',
        applied_at DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP
    )
" --path="$WP_ROOT"

# No "ADD COLUMN IF NOT EXISTS" — not portable to MySQL 5.7. Check via
# information_schema instead, and widen an existing-but-narrower column.
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

# COUNT(*) always returns one row even when 0 — wp db query prints a generic
# status line instead of nothing for a zero-row SELECT, which a direct
# "is this empty" check could mistake for real output. No error-swallowing
# fallback either: the table's existence is already guaranteed above, so a
# failure now must propagate rather than get treated as "0 rows".
MIGRATION_COUNT=$(wp db query \
    "SELECT COUNT(*) FROM \`$MIGRATIONS_TABLE\`" \
    --path="$WP_ROOT" --skip-column-names)

if [ "$MIGRATION_COUNT" -eq 0 ]; then
    log "No applied migrations found — nothing to roll back"
    exit 0
fi

BATCH=$(wp db query \
    "SELECT batch FROM \`$MIGRATIONS_TABLE\` ORDER BY id DESC LIMIT 1" \
    --path="$WP_ROOT" --skip-column-names)

# Blank batch = predates batch tracking (backfilled default, not a real
# deploy id) — matching WHERE batch = '' would sweep in every other
# pre-tracking row too. Refuse rather than guess; revert that one by hand.
if [ -z "$BATCH" ]; then
    echo "ERROR: The most recently applied migration has no batch recorded (it predates batch tracking) — refusing to roll back, since an empty batch would match every pre-tracking migration at once. Revert it manually instead." >&2
    exit 1
fi

log "Rolling back batch '$BATCH' (deploy ${BATCH:0:8})"

SAFE_BATCH=$(printf '%s' "$BATCH" | sed "s/'/''/g")
FILENAMES=$(wp db query \
    "SELECT filename FROM \`$MIGRATIONS_TABLE\` WHERE batch = '$SAFE_BATCH' ORDER BY id DESC" \
    --path="$WP_ROOT" --skip-column-names)

# Maintenance mode for the DDL below — same reasoning as swap.sh. If already
# active (e.g. a deploy mid-recovery), leave it as-is; only restore what
# this script itself changed, on the way out regardless of outcome.
MAINTENANCE_ALREADY_ACTIVE=false
if [ -f "$WP_ROOT/.maintenance" ]; then
    MAINTENANCE_ALREADY_ACTIVE=true
    log "Maintenance mode already active — leaving it as-is"
else
    log "Enabling maintenance mode"
    # wp-cli errors if already active — tolerate that, but verify against the
    # actual .maintenance file rather than trusting the exit code, since a
    # genuine permission/CLI failure would otherwise look the same and let
    # live Down SQL run while the site may still be serving traffic.
    wp maintenance-mode activate --path="$WP_ROOT" || true

    if [ ! -f "$WP_ROOT/.maintenance" ]; then
        echo "ERROR: Could not confirm maintenance mode is active (no .maintenance file at $WP_ROOT after activation attempt) — refusing to run live rollback SQL while the site may still be serving traffic." >&2
        exit 1
    fi
fi

# Flips to false right before the first Down statement runs. A failure
# after that point means the batch may be partially reverted — bringing the
# site back online then would serve traffic against an inconsistent schema,
# so maintenance mode stays on for manual inspection rather than clearing
# automatically. Same reasoning as swap.sh's SAFE_TO_RECOVER.
SAFE_TO_RECOVER=true

restore_maintenance_mode() {
    local EXIT_CODE=$?
    if [ "$MAINTENANCE_ALREADY_ACTIVE" = true ]; then
        exit $EXIT_CODE
    fi

    if [ $EXIT_CODE -eq 0 ] || [ "$SAFE_TO_RECOVER" = true ]; then
        log "Disabling maintenance mode"
        if ! wp maintenance-mode deactivate --path="$WP_ROOT"; then
            log "ERROR: Failed to deactivate maintenance mode — the site may still be offline. Run manually: wp maintenance-mode deactivate --path=\"$WP_ROOT\""
            # Force a failing result so the caller can't miss this — without
            # this, a rollback that itself succeeded (EXIT_CODE 0) would
            # still report success while the site stays down. Preserve any
            # earlier non-zero code rather than overwrite it.
            [ $EXIT_CODE -eq 0 ] && EXIT_CODE=1
        fi
    else
        log "ERROR: Rollback failed partway through batch '$BATCH' — site is in maintenance mode"
        log "ERROR: Some migrations in this batch may have been reverted and others not — before deactivating maintenance mode, verify:"
        log "ERROR:   wp db query \"SELECT * FROM \`$MIGRATIONS_TABLE\` WHERE batch = '$SAFE_BATCH' ORDER BY id DESC\" --path=\"$WP_ROOT\""
        log "ERROR: Once verified safe: wp maintenance-mode deactivate --path=\"$WP_ROOT\""
    fi
    exit $EXIT_CODE
}
trap restore_maintenance_mode EXIT

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
    SAFE_TO_RECOVER=false
    printf '%s\n' "$DOWN_SQL" | sed "s/__WP_PREFIX__/${TARGET_PREFIX}/g" | wp db query --path="$WP_ROOT"

    SAFE_FILENAME=$(printf '%s' "$FILENAME" | sed "s/'/''/g")
    # Same reasoning as migrate.sh's INSERT: if removing the tracking row
    # fails here, the Down SQL already ran but the row still says "applied".
    # Name the exact fix instead of letting this propagate unexplained.
    if ! wp db query \
        "DELETE FROM \`$MIGRATIONS_TABLE\` WHERE filename = '$SAFE_FILENAME'" \
        --path="$WP_ROOT"; then
        echo "ERROR: $FILENAME's Down section succeeded, but removing its tracking row from $MIGRATIONS_TABLE failed." >&2
        echo "ERROR: It's still recorded as applied even though it was just reverted. Before retrying, either:" >&2
        echo "ERROR:   1. Manually run: DELETE FROM \`$MIGRATIONS_TABLE\` WHERE filename = '$SAFE_FILENAME';" >&2
        echo "ERROR:   2. Or confirm $FILENAME's Down section is safe to run twice before retrying this rollback." >&2
        exit 1
    fi

    log "  Reverted: $FILENAME"
done <<< "$FILENAMES"

log "Rollback of batch '$BATCH' (deploy ${BATCH:0:8}) complete"
