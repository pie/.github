#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# rollback-deploy.sh — Fully reverts the most recent release: component files
# AND any database migrations that specific deploy applied.
#
# Uploaded fresh to the server by the rollback-deploy action each time it
# runs; nothing is left behind afterward. Scoped strictly to the single most
# recent release — there is no "go back N releases" mode, since only the
# current and one prior release are ever kept on disk. See the README for
# design rationale — comments below are just flow notes.
#
# Unlike rollback-migrations (which reverts whatever the DB's most recent
# batch happens to be, regardless of which deploy that was), this always
# targets the exact deploy currently live — verified against that release's
# own recorded full SHA, not inferred, and against a strict content match
# between live files and that release's own copy before touching anything.
#
# Injected by the action:
#   WP_ROOT      Absolute path to the WordPress root
#   REPO_NAME    GitHub repository name — migrations table name is derived
#                from this the same way swap.sh does
#   RELEASES_DIR Absolute path to the releases directory (defaults to
#                WP_ROOT/releases if unset)
# ==============================================================================

RELEASES_DIR="${RELEASES_DIR:-$WP_ROOT/releases}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# Extracts the "up" or "down" section from a migration file (same as
# swap.sh/migrate.sh/rollback.sh). No markers at all = treated as up-only.
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

# Byte-for-byte the same derivation as swap.sh/rollback.sh — must resolve to
# the same tracking table, or this script checks the wrong project's batch.
MIGRATIONS_SUFFIX="_migrations"
REPO_SLUG_RAW="$(printf '%s' "$REPO_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g')"
MAX_SLUG_LEN=$(( 64 - ${#TARGET_PREFIX} - ${#MIGRATIONS_SUFFIX} ))
if [ "$MAX_SLUG_LEN" -lt 1 ]; then
    echo "ERROR: table_prefix '$TARGET_PREFIX' is too long to derive a migrations table name within MySQL's 64-character identifier limit." >&2
    exit 1
fi

if [ "${#REPO_SLUG_RAW}" -gt "$MAX_SLUG_LEN" ]; then
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

# ==============================================================================
# Step 1: Identify the current and prior release
# ==============================================================================

# deploy-complete.txt is required, not just components.txt — components.txt
# is written before swap.sh even runs, so it only proves this release's
# files were uploaded, not that swap.sh ever actually went live for it. A
# release whose dry run or component swap failed partway would still have
# components.txt; selecting it as current or prior would mean inspecting or
# restoring to a release that was never actually live. deploy-complete.txt
# is only written once swap.sh's migrations and component swap both
# succeeded — same marker swap.sh's own pruning step now requires.
readarray -t RELEASE_DIRS < <(
    find "$RELEASES_DIR" -maxdepth 1 -mindepth 1 -type d -printf '%T@ %p\n' 2>/dev/null \
        | sort -rn | cut -d' ' -f2- \
        | while IFS= read -r DIR; do
              [ -f "$DIR/migrations/deploy-complete.txt" ] && printf '%s\n' "$DIR"
          done
)

if [ "${#RELEASE_DIRS[@]}" -lt 2 ]; then
    echo "ERROR: Found ${#RELEASE_DIRS[@]} release(s) under $RELEASES_DIR — a current and a prior release are both needed to roll back. Nothing to do." >&2
    exit 1
fi

CURRENT_RELEASE_DIR="${RELEASE_DIRS[0]}"
PRIOR_RELEASE_DIR="${RELEASE_DIRS[1]}"
CURRENT_SHA="$(basename "$CURRENT_RELEASE_DIR")"
PRIOR_SHA="$(basename "$PRIOR_RELEASE_DIR")"

log "Current release: $CURRENT_SHA — rolling back to prior release: $PRIOR_SHA"

# Release directories are named by the short SHA, which isn't safe to match
# against the full-SHA batch column by prefix (the same collision risk
# FULL_GIT_SHA exists to avoid in the first place) — read the exact value
# swap-and-migrate recorded for this release instead of inferring it.
FULL_SHA_FILE="$CURRENT_RELEASE_DIR/migrations/full-sha.txt"
if [ ! -f "$FULL_SHA_FILE" ]; then
    echo "ERROR: $FULL_SHA_FILE not found — this release predates full-SHA tracking, so its migrations batch (if any) can't be safely identified. Refusing to guess; revert manually if needed." >&2
    exit 1
fi
CURRENT_FULL_SHA=$(cat "$FULL_SHA_FILE")

if [[ ! "$CURRENT_FULL_SHA" =~ ^[0-9a-f]{40}$ ]]; then
    echo "ERROR: $FULL_SHA_FILE does not contain a valid 40-character hex SHA ('$CURRENT_FULL_SHA') — refusing to use it in SQL." >&2
    exit 1
fi

COMPONENTS_FILE="$CURRENT_RELEASE_DIR/migrations/components.txt"
readarray -t COMPONENTS < <(grep -v '^[[:space:]]*$' "$COMPONENTS_FILE")

if [ "${#COMPONENTS[@]}" -eq 0 ]; then
    echo "ERROR: No components defined in $COMPONENTS_FILE" >&2
    exit 1
fi

# Same format/duplicate checks as swap.sh — TYPE/NAME feed into mv/rm -rf
# paths below, and a duplicate would break Step 5's second pass the same way.
declare -A SEEN_COMPONENTS
for COMPONENT in "${COMPONENTS[@]}"; do
    if [[ ! "$COMPONENT" =~ ^[A-Za-z0-9_-]+:[A-Za-z0-9_-]+$ ]]; then
        echo "ERROR: Invalid component entry '$COMPONENT' in $COMPONENTS_FILE — expected type:name using only letters, digits, hyphens, and underscores." >&2
        exit 1
    fi
    if [ -n "${SEEN_COMPONENTS[$COMPONENT]+x}" ]; then
        echo "ERROR: Duplicate component entry '$COMPONENT' in $COMPONENTS_FILE." >&2
        exit 1
    fi
    SEEN_COMPONENTS[$COMPONENT]=1
done

# ==============================================================================
# Step 2: Verify live files actually match the recorded current release, and
# that the prior release has a copy of every component to restore
# ==============================================================================

log "Verifying live files match the recorded current release"
for COMPONENT in "${COMPONENTS[@]}"; do
    TYPE="${COMPONENT%%:*}"
    NAME="${COMPONENT##*:}"
    LIVE_PATH="$WP_ROOT/wp-content/$TYPE/$NAME"
    CURRENT_PATH="$CURRENT_RELEASE_DIR/$TYPE/$NAME"
    PRIOR_PATH="$PRIOR_RELEASE_DIR/$TYPE/$NAME"

    if [ ! -d "$CURRENT_PATH" ]; then
        echo "ERROR: $CURRENT_PATH not found — the current release's own copy of $TYPE:$NAME is missing, can't verify what's live." >&2
        exit 1
    fi

    # Strict content comparison, not just "does it exist" — if live has
    # drifted from what this release actually deployed (a manual edit, an
    # earlier rollback that failed partway, etc.), guessing which deploy is
    # really live risks reverting the wrong thing entirely. Refuse instead.
    if ! diff -rq "$LIVE_PATH" "$CURRENT_PATH" >/dev/null 2>&1; then
        echo "ERROR: $LIVE_PATH does not match $CURRENT_PATH — live files have drifted from the recorded current release. Refusing to guess; resolve manually before retrying." >&2
        exit 1
    fi

    if [ ! -d "$PRIOR_PATH" ]; then
        echo "ERROR: $PRIOR_PATH not found — $TYPE:$NAME has no prior version to restore (it may have been added in the current release). A full automatic rollback isn't possible; handle this component manually." >&2
        exit 1
    fi

    log "  Verified $TYPE/$NAME"
done

# ==============================================================================
# Step 3: Determine whether the current release applied any migrations
# ==============================================================================

MIGRATIONS_TABLE_EXISTS=$(wp db query \
    "SELECT COUNT(*) FROM information_schema.TABLES \
     WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = '$MIGRATIONS_TABLE'" \
    --path="$WP_ROOT" --skip-column-names)

FILENAMES=""
if [ "$MIGRATIONS_TABLE_EXISTS" -gt 0 ]; then
    # CURRENT_FULL_SHA is already regex-validated as pure hex above, so it's
    # safe to interpolate directly — no quote-escaping needed.
    FILENAMES=$(wp db query \
        "SELECT filename FROM \`$MIGRATIONS_TABLE\` WHERE batch = '$CURRENT_FULL_SHA' ORDER BY id DESC" \
        --path="$WP_ROOT" --skip-column-names)
fi

if [ -n "$FILENAMES" ]; then
    log "Release $CURRENT_SHA applied migration(s) under batch $CURRENT_FULL_SHA — will revert them"
else
    log "Release $CURRENT_SHA applied no migrations — files-only rollback"
fi

# ==============================================================================
# Step 4: Maintenance mode for the duration — always, regardless of whether
# migrations are involved, since live files are being swapped either way.
# ==============================================================================

MAINTENANCE_ALREADY_ACTIVE=false
if [ -f "$WP_ROOT/.maintenance" ]; then
    MAINTENANCE_ALREADY_ACTIVE=true
    log "Maintenance mode already active — leaving it as-is"
else
    log "Enabling maintenance mode"
    # wp-cli errors if already active — tolerate that, but verify against the
    # actual .maintenance file rather than trusting the exit code, since a
    # genuine permission/CLI failure would otherwise look the same and let
    # the rollback run while the site may still be serving traffic.
    wp maintenance-mode activate --path="$WP_ROOT" || true

    if [ ! -f "$WP_ROOT/.maintenance" ]; then
        echo "ERROR: Could not confirm maintenance mode is active (no .maintenance file at $WP_ROOT after activation attempt) — refusing to roll back while the site may still be serving traffic." >&2
        exit 1
    fi
fi

# Flips to false right before the first live change (file swap or migration
# revert). A failure after that point means the rollback may be partially
# applied — bringing the site back online then would serve traffic against
# an inconsistent state, so maintenance mode stays on for manual inspection.
# Same pattern as swap.sh/rollback.sh's SAFE_TO_RECOVER.
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
            # still report success while the site stays down.
            [ $EXIT_CODE -eq 0 ] && EXIT_CODE=1
        fi
    else
        log "ERROR: Rollback of release $CURRENT_SHA failed partway through — site is in maintenance mode"
        log "ERROR: Component files and/or migrations may be partially reverted — before deactivating maintenance mode, verify:"
        log "ERROR:   ls -la $WP_ROOT/wp-content/plugins/ $WP_ROOT/wp-content/themes/"
        log "ERROR:   wp db query \"SELECT * FROM \`$MIGRATIONS_TABLE\` WHERE batch = '$CURRENT_FULL_SHA' ORDER BY id DESC\" --path=\"$WP_ROOT\""
        log "ERROR: Once verified safe: wp maintenance-mode deactivate --path=\"$WP_ROOT\""
    fi
    exit $EXIT_CODE
}
trap restore_maintenance_mode EXIT

# ==============================================================================
# Step 5: Restore component files — stage every component, then swap all
# into place. Same two-pass pattern as swap.sh's own component swap, just
# sourced from the prior release instead of a newly-uploaded one.
# ==============================================================================

log "Restoring components from prior release $PRIOR_SHA"
SAFE_TO_RECOVER=false

for COMPONENT in "${COMPONENTS[@]}"; do
    TYPE="${COMPONENT%%:*}"
    NAME="${COMPONENT##*:}"
    LIVE_PATH="$WP_ROOT/wp-content/$TYPE/$NAME"
    PRIOR_PATH="$PRIOR_RELEASE_DIR/$TYPE/$NAME"
    STAGING_PATH="${LIVE_PATH}.deploying"
    OLD_PATH="${LIVE_PATH}.previous"

    # Clear any remnants from a previous failed attempt
    rm -rf "$STAGING_PATH" "$OLD_PATH"

    mkdir -p "$STAGING_PATH"
    rsync -a --delete "$PRIOR_PATH/" "$STAGING_PATH/"

    log "  Staged $TYPE/$NAME from prior release"
done

log "All components staged — swapping into place"

for COMPONENT in "${COMPONENTS[@]}"; do
    TYPE="${COMPONENT%%:*}"
    NAME="${COMPONENT##*:}"
    LIVE_PATH="$WP_ROOT/wp-content/$TYPE/$NAME"
    STAGING_PATH="${LIVE_PATH}.deploying"
    OLD_PATH="${LIVE_PATH}.previous"

    # Atomic rename: live → .previous, staging → live
    if [ -e "$LIVE_PATH" ] || [ -L "$LIVE_PATH" ]; then
        mv "$LIVE_PATH" "$OLD_PATH"
    fi
    mv "$STAGING_PATH" "$LIVE_PATH"
    rm -rf "$OLD_PATH"

    log "  $TYPE/$NAME -> prior release $PRIOR_SHA"
done

log "Component files reverted to release $PRIOR_SHA"

# ==============================================================================
# Step 6: Revert this release's migrations, if any — reads the SQL files from
# this release's own uploaded copy, not a fresh checkout, so it always
# reverts exactly what this deploy actually applied.
# ==============================================================================

if [ -n "$FILENAMES" ]; then
    QUERIES_DIR="$CURRENT_RELEASE_DIR/migrations/queries"

    while IFS= read -r FILENAME; do
        [ -z "$FILENAME" ] && continue
        SQL_FILE="$QUERIES_DIR/$FILENAME"

        if [ ! -f "$SQL_FILE" ]; then
            echo "ERROR: $FILENAME is recorded as applied under batch $CURRENT_FULL_SHA but its file is missing from $QUERIES_DIR — cannot verify or revert it. Tracking row left as-is." >&2
            exit 1
        fi

        DOWN_SQL=$(extract_section "$SQL_FILE" down)

        if [ -z "$DOWN_SQL" ]; then
            log "  $FILENAME has no '-- +migrate Down' section — leaving its change in place, skipping"
            continue
        fi

        log "Reverting $FILENAME"
        printf '%s\n' "$DOWN_SQL" | sed "s/__WP_PREFIX__/${TARGET_PREFIX}/g" | wp db query --path="$WP_ROOT"

        SAFE_FILENAME=$(printf '%s' "$FILENAME" | sed "s/'/''/g")
        if ! wp db query \
            "DELETE FROM \`$MIGRATIONS_TABLE\` WHERE filename = '$SAFE_FILENAME'" \
            --path="$WP_ROOT"; then
            echo "ERROR: $FILENAME's Down section succeeded, but removing its tracking row from $MIGRATIONS_TABLE failed." >&2
            echo "ERROR: It's still recorded as applied even though it was just reverted. Before retrying, either:" >&2
            echo "ERROR:   1. Manually run: DELETE FROM \`$MIGRATIONS_TABLE\` WHERE filename = '$SAFE_FILENAME';" >&2
            echo "ERROR:   2. Or confirm $FILENAME's Down section is safe to run twice before retrying." >&2
            exit 1
        fi

        log "  Reverted: $FILENAME"
    done <<< "$FILENAMES"

    log "Migrations from batch $CURRENT_FULL_SHA reverted"
fi

log "Full rollback of release $CURRENT_SHA complete — $PRIOR_SHA is now live"
