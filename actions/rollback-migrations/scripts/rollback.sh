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

# Same derivation as swap.sh (byte-for-byte — this must resolve to the same
# tracking table name a deploy would have used, or this script rolls back
# the wrong project's batch).
MIGRATIONS_SUFFIX="_migrations"
REPO_SLUG_RAW="$(printf '%s' "$REPO_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g')"
MAX_SLUG_LEN=$(( 64 - ${#TARGET_PREFIX} - ${#MIGRATIONS_SUFFIX} ))
if [ "$MAX_SLUG_LEN" -lt 1 ]; then
    echo "ERROR: table_prefix '$TARGET_PREFIX' is too long to derive a migrations table name within MySQL's 64-character identifier limit." >&2
    exit 1
fi

if [ "${#REPO_SLUG_RAW}" -gt "$MAX_SLUG_LEN" ]; then
    # A flat cut here risks two different repo names truncating to the same
    # prefix (e.g. "client-a-main-site" and "client-a-staging-site"), which
    # would collide on one shared tracking table — and this script would
    # then roll back whichever project's batch happened to be most recent
    # in it. Reserve room for a short, deterministic hash of the full name
    # so a truncated slug still stays unique even when its visible prefix
    # doesn't. Left alone (the common case), REPO_SLUG is unchanged from
    # before, so already-deployed sites keep resolving to the same
    # tracking table they always have.
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

# The batch column is normally added by migrate.sh, but only as a side
# effect of a deploy that has a pending migration to apply — this script
# can't assume that has already happened by the time it runs, so it ensures
# both the table and the column exist itself, the same way migrate.sh does.
wp db query "
    CREATE TABLE IF NOT EXISTS \`$MIGRATIONS_TABLE\` (
        id         INT AUTO_INCREMENT PRIMARY KEY,
        filename   VARCHAR(255) NOT NULL UNIQUE,
        batch      VARCHAR(40)  NOT NULL DEFAULT '',
        applied_at DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP
    )
" --path="$WP_ROOT"

# "ADD COLUMN IF NOT EXISTS" is a MySQL 8.0.29+/MariaDB extension, not
# standard SQL — a syntax error on stock MySQL 5.7, still a WordPress-
# supported minimum. information_schema.COLUMNS works everywhere, so check
# there first and only run a plain ADD COLUMN when it's actually missing —
# matches migrate.sh.
#
# Also widens an existing-but-too-narrow column: tables created by an
# earlier version of this script have batch VARCHAR(8) (the deploy's short
# SHA); inserting a full 40-character SHA into that would truncate silently
# or error outright depending on SQL mode, so upgrade it in place rather
# than assuming "exists" already means "wide enough".
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

# COUNT(*) always returns exactly one row, even when it's 0 — wp db query
# falls back to printing a generic status line instead of nothing for a
# SELECT that matches zero rows, which a direct "is this empty" check on a
# LIMIT 1 query could mistake for real output. Gate on the count first.
#
# No error-swallowing fallback here: the table is already guaranteed to
# exist by this point (created, or column-checked, just above), so a
# failure now means a real problem (DB outage, permissions) — that must
# propagate and stop the script via set -e, not get treated as "0 rows" and
# silently report the requested rollback as having nothing to do.
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

# A blank batch means the most recently applied migration predates batch
# tracking (it was backfilled to '' by the ADD COLUMN default above, not a
# real deploy identifier) — there's no way to reconstruct which historical
# migrations actually shipped together, and matching on WHERE batch = ''
# below would sweep in every other pre-tracking row too, not just the
# intended one. Refuse rather than guess; revert it by hand instead, e.g.
# by running its Down section directly against a specific filename.
if [ -z "$BATCH" ]; then
    echo "ERROR: The most recently applied migration has no batch recorded (it predates batch tracking) — refusing to roll back, since an empty batch would match every pre-tracking migration at once. Revert it manually instead." >&2
    exit 1
fi

log "Rolling back batch '$BATCH' (deploy ${BATCH:0:8})"

SAFE_BATCH=$(printf '%s' "$BATCH" | sed "s/'/''/g")
FILENAMES=$(wp db query \
    "SELECT filename FROM \`$MIGRATIONS_TABLE\` WHERE batch = '$SAFE_BATCH' ORDER BY id DESC" \
    --path="$WP_ROOT" --skip-column-names)

# Wrap the actual DDL below in a maintenance window — same reasoning as
# swap.sh: a rollback that drops or renames a column can otherwise race
# live requests hitting that table mid-change. If maintenance mode is
# already active (e.g. left on by a deploy that's mid-recovery), leave it
# exactly as-is rather than touching state that belongs to that other
# situation — only restore what this script itself changed, on the way out
# regardless of whether the revert loop below succeeds or fails partway
# through.
MAINTENANCE_ALREADY_ACTIVE=false
if [ -f "$WP_ROOT/.maintenance" ]; then
    MAINTENANCE_ALREADY_ACTIVE=true
    log "Maintenance mode already active — leaving it as-is"
else
    log "Enabling maintenance mode"
    if ! wp maintenance-mode activate --path="$WP_ROOT"; then
        log "WARN: wp maintenance-mode activate failed — continuing anyway"
    fi
fi

restore_maintenance_mode() {
    if [ "$MAINTENANCE_ALREADY_ACTIVE" = false ]; then
        log "Disabling maintenance mode"
        wp maintenance-mode deactivate --path="$WP_ROOT" \
            || log "WARN: Failed to deactivate maintenance mode — run manually: wp maintenance-mode deactivate --path=\"$WP_ROOT\""
    fi
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
    printf '%s\n' "$DOWN_SQL" | sed "s/__WP_PREFIX__/${TARGET_PREFIX}/g" | wp db query --path="$WP_ROOT"

    SAFE_FILENAME=$(printf '%s' "$FILENAME" | sed "s/'/''/g")
    wp db query \
        "DELETE FROM \`$MIGRATIONS_TABLE\` WHERE filename = '$SAFE_FILENAME'" \
        --path="$WP_ROOT"

    log "  Reverted: $FILENAME"
done <<< "$FILENAMES"

log "Rollback of batch '$BATCH' (deploy ${BATCH:0:8}) complete"
