#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# swap.sh — Atomic deploy: migrations + component swap
#
# Uploaded to the server by the swap-and-migrate action on each deploy.
# Do not copy or edit this file per-project — changes belong in the action.
# See the README for the full design rationale (no table clone/backup, the
# dry run, releases/ protection, etc.) — comments below are just flow notes.
#
# Injected by the action:
#   WP_ROOT       Absolute path to the WordPress root
#   GIT_SHA       Short (8-char) SHA — release directory name only
#   FULL_GIT_SHA  Full (40-char) SHA — migration batch grouping (short SHA can collide)
#   REPO_NAME     GitHub repository name — used to derive the migrations table name
#   RUN_ID        Workflow run ID — makes the dry run's scratch-table prefix
#                 unique to this run, not just this SHA (short SHA can collide)
#
# Components are read from components.txt in the same directory, written by
# the action before this script runs. One "type:name" entry per line.
# ==============================================================================

SHORT_SHA="${GIT_SHA:0:8}"
RELEASES_DIR="${RELEASES_DIR:-$WP_ROOT/releases}"
NEW_RELEASE_DIR="$RELEASES_DIR/$GIT_SHA"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIGRATE_SCRIPT="$SCRIPT_DIR/migrate.sh"
QUERIES_DIR="$SCRIPT_DIR/queries"
HAS_MIGRATIONS=false
MAINTENANCE_ACTIVE=false
MAINTENANCE_ALREADY_ACTIVE=false
SAFE_TO_RECOVER=true

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# Extracts the "up" or "down" section from a migration file (same as
# migrate.sh/rollback.sh). No markers at all = treated as up-only.
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

# Exit 1 = safe, maintenance mode deactivated. Exit 2 = live changes began,
# stays in maintenance mode for manual recovery. See README.
cleanup() {
    local EXIT_CODE=$?
    [ $EXIT_CODE -eq 0 ] && return
    if [ "$MAINTENANCE_ACTIVE" = true ]; then
        if [ "$SAFE_TO_RECOVER" = true ]; then
            if [ "$MAINTENANCE_ALREADY_ACTIVE" = true ]; then
                log "ERROR: Deploy failed before live changes, but maintenance mode predates this run — leaving it enabled rather than clearing a state it didn't set"
                log "ERROR: An earlier deploy may still need manual recovery. Once verified safe: wp maintenance-mode deactivate --path=\"$WP_ROOT\""
            else
                log "Deploy failed before live changes — deactivating maintenance mode"
                wp maintenance-mode deactivate --path="$WP_ROOT" || true
            fi
            exit 1
        else
            log "ERROR: Deploy failed after live changes began — site is in maintenance mode"
            log "ERROR: Migrations may have applied only partially — before deactivating maintenance mode, verify:"
            log "ERROR:   wp db query \"SELECT * FROM \`$MIGRATIONS_TABLE\` ORDER BY id DESC LIMIT 5\" --path=\"$WP_ROOT\""
            log "ERROR:   ls -la $WP_ROOT/wp-content/plugins/ $WP_ROOT/wp-content/themes/"
            log "ERROR: To revert migrations with a '-- +migrate Down' section, run the Rollback Migrations workflow from the Actions tab rather than SSHing in"
            log "ERROR: Once verified safe: wp maintenance-mode deactivate --path=\"$WP_ROOT\""
            exit 2
        fi
    fi
    exit $EXIT_CODE
}
trap cleanup EXIT

# ==============================================================================
# Step 1: Pre-flight checks
# ==============================================================================

log "Atomic deploy starting — SHA: $GIT_SHA"

if [[ "$WP_ROOT" != '/'* ]] || [ "$WP_ROOT" = "/" ]; then
    echo "ERROR: WP_ROOT must be an absolute path starting with / and not the filesystem root itself (e.g. /home/piecode/site/public_html)." >&2
    exit 1
fi

# Step 4 later runs mkdir/chmod/writes an .htaccess directly against
# RELEASES_DIR — refuse the exact-"/" case here too, not just via the
# action's own input validation, since this script also runs standalone.
if [ "$RELEASES_DIR" = "/" ]; then
    echo "ERROR: releases-dir resolved to the filesystem root — refusing to touch it." >&2
    exit 1
fi

# Trailing-slash-normalized: releases-dir == wp-root would deny/chmod the
# entire WordPress root, not just a releases subdirectory.
if [ "${RELEASES_DIR%/}" = "${WP_ROOT%/}" ]; then
    echo "ERROR: releases-dir must not be the same path as WP_ROOT." >&2
    exit 1
fi

# Belt and braces: Step 4's .htaccess/chmod only ever target RELEASES_DIR
# directly — requiring its final path segment to actually be "releases"
# rules out WP_ROOT, "/", or any unrelated directory, however it was
# misconfigured, without needing to know their relationship to each other.
if [ "$(basename "${RELEASES_DIR%/}")" != "releases" ]; then
    echo "ERROR: releases-dir must be a directory named 'releases' (e.g. /home/piecode/site/public_html/releases)." >&2
    exit 1
fi

if ! command -v wp &>/dev/null; then
    echo "ERROR: wp-cli is not available on this server" >&2
    exit 1
fi

log "Verifying database connectivity"
wp db check --path="$WP_ROOT"

CURRENT_PREFIX=$(wp config get table_prefix --path="$WP_ROOT")

# Guard against SQL injection via a malformed table_prefix (interpolated below).
if [[ ! "$CURRENT_PREFIX" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    echo "ERROR: table_prefix '$CURRENT_PREFIX' contains unexpected characters — refusing to use it in SQL. Expected only letters, digits, and underscores, not starting with a digit." >&2
    exit 1
fi

# Cap REPO_SLUG so prefix + slug + "_migrations" stays under MySQL's 64-char limit.
MIGRATIONS_SUFFIX="_migrations"
REPO_SLUG_RAW="$(printf '%s' "$REPO_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g')"
MAX_SLUG_LEN=$(( 64 - ${#CURRENT_PREFIX} - ${#MIGRATIONS_SUFFIX} ))
if [ "$MAX_SLUG_LEN" -lt 1 ]; then
    echo "ERROR: table_prefix '$CURRENT_PREFIX' is too long to derive a migrations table name within MySQL's 64-character identifier limit." >&2
    exit 1
fi

if [ "${#REPO_SLUG_RAW}" -gt "$MAX_SLUG_LEN" ]; then
    # Append a hash when truncating so two long, similarly-prefixed repo names
    # can't collide on the same tracking table. Untruncated case is unchanged.
    REPO_HASH="$(printf '%s' "$REPO_NAME" | md5sum | cut -c1-8)"
    TRUNCATE_LEN=$(( MAX_SLUG_LEN - 1 - ${#REPO_HASH} ))
    if [ "$TRUNCATE_LEN" -lt 1 ]; then
        echo "ERROR: table_prefix '$CURRENT_PREFIX' is too long to derive a collision-resistant migrations table name within MySQL's 64-character identifier limit." >&2
        exit 1
    fi
    REPO_SLUG="$(printf '%s' "$REPO_SLUG_RAW" | cut -c1-"$TRUNCATE_LEN")_${REPO_HASH}"
else
    REPO_SLUG="$REPO_SLUG_RAW"
fi

MIGRATIONS_TABLE="${CURRENT_PREFIX}${REPO_SLUG}_migrations"

if [ ! -d "$NEW_RELEASE_DIR" ]; then
    echo "ERROR: Release directory $NEW_RELEASE_DIR not found — did all rsync jobs complete?" >&2
    exit 1
fi

COMPONENTS_FILE="$SCRIPT_DIR/components.txt"
if [ ! -f "$COMPONENTS_FILE" ]; then
    echo "ERROR: components.txt not found at $COMPONENTS_FILE" >&2
    exit 1
fi

readarray -t COMPONENTS < <(grep -v '^[[:space:]]*$' "$COMPONENTS_FILE")

if [ "${#COMPONENTS[@]}" -eq 0 ]; then
    echo "ERROR: No components defined in components.txt" >&2
    exit 1
fi

# Slug-safe only — TYPE/NAME feed into mv/rm -rf paths below.
declare -A SEEN_COMPONENTS
for COMPONENT in "${COMPONENTS[@]}"; do
    if [[ ! "$COMPONENT" =~ ^[A-Za-z0-9_-]+:[A-Za-z0-9_-]+$ ]]; then
        echo "ERROR: Invalid component entry '$COMPONENT' — expected type:name using only letters, digits, hyphens, and underscores." >&2
        exit 1
    fi

    # A duplicate entry breaks Step 4's second pass: its first iteration
    # already consumed the staging directory moving it into place, so the
    # second iteration's mv fails after the live directory has been moved
    # aside — leaving that component missing entirely.
    if [ -n "${SEEN_COMPONENTS[$COMPONENT]+x}" ]; then
        echo "ERROR: Duplicate component entry '$COMPONENT' in components.txt." >&2
        exit 1
    fi
    SEEN_COMPONENTS[$COMPONENT]=1
done

log "Validating component release paths"
for COMPONENT in "${COMPONENTS[@]}"; do
    TYPE="${COMPONENT%%:*}"
    NAME="${COMPONENT##*:}"
    RELEASE_PATH="$NEW_RELEASE_DIR/$TYPE/$NAME"
    if [ ! -d "$RELEASE_PATH" ]; then
        echo "ERROR: $RELEASE_PATH not found — did the rsync job for $TYPE:$NAME complete?" >&2
        exit 1
    fi
done

# ==============================================================================
# Step 2: Detect pending migrations
# ==============================================================================

PENDING_FILES=()

if [ -d "$QUERIES_DIR" ]; then
    # Table may genuinely not exist yet (first-ever deploy) — check explicitly
    # rather than swallowing errors, so a real failure still propagates.
    MIGRATIONS_TABLE_EXISTS=$(wp db query \
        "SELECT COUNT(*) FROM information_schema.TABLES \
         WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = '$MIGRATIONS_TABLE'" \
        --path="$WP_ROOT" --skip-column-names)

    if [ "$MIGRATIONS_TABLE_EXISTS" -eq 0 ]; then
        APPLIED=""
    else
        APPLIED=$(wp db query \
            "SELECT filename FROM \`$MIGRATIONS_TABLE\`" \
            --path="$WP_ROOT" --skip-column-names)
    fi

    while IFS= read -r SQL_FILE; do
        FILENAME=$(basename "$SQL_FILE")
        if ! echo "$APPLIED" | grep -qxF "$FILENAME"; then
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
# Step 3: Database migrations — applied directly against the live tables
# ==============================================================================

if [ "$HAS_MIGRATIONS" = true ]; then

    # Distinct from MAINTENANCE_ACTIVE below: this tracks whether maintenance
    # mode predates this run (e.g. left on by an earlier failed deploy still
    # awaiting manual recovery) so cleanup/Step 5 never turn off something
    # they didn't turn on — same pattern as rollback.sh.
    if [ -f "$WP_ROOT/.maintenance" ]; then
        MAINTENANCE_ALREADY_ACTIVE=true
        log "Maintenance mode already active — leaving it as-is"
    else
        log "Enabling maintenance mode"
        # wp-cli errors if already active — tolerate that, but verify against
        # the actual .maintenance file rather than trusting the exit code,
        # since a genuine permission/CLI failure would otherwise look the
        # same and let live migrations run while the site is still serving
        # traffic.
        wp maintenance-mode activate --path="$WP_ROOT" || true

        if [ ! -f "$WP_ROOT/.maintenance" ]; then
            echo "ERROR: Could not confirm maintenance mode is active (no .maintenance file at $WP_ROOT after activation attempt) — refusing to run live migrations while the site may still be serving traffic." >&2
            exit 1
        fi
    fi

    MAINTENANCE_ACTIVE=true

    # Dry run: apply pending migrations' Up sections to structure-only clones
    # (no rows) under a throwaway prefix before touching anything live.
    log "Dry run: validating ${#PENDING_FILES[@]} pending migration(s) against a structure-only clone"

    # Cleanup below drops every table matching this prefix, not just ones
    # this run created — SHORT_SHA alone can collide (same reason
    # FULL_GIT_SHA exists for batch grouping), so RUN_ID is included too,
    # making an unrelated table ever matching this exact prefix implausible.
    # RUN_ATTEMPT is deliberately left out: retrying a failed attempt should
    # reuse the same prefix, since the clone step below already clears
    # remnants from a previous failed attempt at it.
    DRYRUN_PREFIX="dryrun_${SHORT_SHA}_${RUN_ID}_"

    # MIGRATIONS_TABLE is excluded: its own name is already truncated to fit
    # MySQL's 64-char limit under the live (short) prefix, with no headroom
    # left for a longer one — re-prefixing it with DRYRUN_PREFIX can overflow
    # that limit. Migrations don't need a scratch copy of their own tracking
    # table anyway; they validate schema changes to the site's own tables.
    DRYRUN_SOURCE_TABLES=$(wp db query \
        "SELECT table_name FROM information_schema.tables \
         WHERE table_schema = DATABASE() \
         AND LEFT(table_name, CHAR_LENGTH('${CURRENT_PREFIX}')) = '${CURRENT_PREFIX}' \
         AND table_name != '${MIGRATIONS_TABLE}'" \
        --path="$WP_ROOT" --skip-column-names)

    set +e
    DRYRUN_FAILED=false

    # One combined script instead of two wp-cli calls per table — the
    # per-invocation PHP/wp-cli bootstrap, not the SQL itself, dominates
    # cost on sites with many tables. Clears remnants from a previous failed
    # attempt at this SHA, then clones structure only.
    DRYRUN_CLONE_SQL=""
    while IFS= read -r TABLE; do
        [ -z "$TABLE" ] && continue
        DRYRUN_TABLE="${DRYRUN_PREFIX}${TABLE#$CURRENT_PREFIX}"
        DRYRUN_CLONE_SQL+="DROP TABLE IF EXISTS \`$DRYRUN_TABLE\`; CREATE TABLE \`$DRYRUN_TABLE\` LIKE \`$TABLE\`;"$'\n'
    done <<< "$DRYRUN_SOURCE_TABLES"

    if [ -n "$DRYRUN_CLONE_SQL" ]; then
        printf '%s' "$DRYRUN_CLONE_SQL" | wp db query --path="$WP_ROOT" || DRYRUN_FAILED=true
    fi

    if [ "$DRYRUN_FAILED" = false ]; then
        for SQL_FILE in "${PENDING_FILES[@]}"; do
            FILENAME=$(basename "$SQL_FILE")
            log "Dry run: applying $FILENAME"
            if ! extract_section "$SQL_FILE" up | sed "s/__WP_PREFIX__/${DRYRUN_PREFIX}/g" | wp db query --path="$WP_ROOT"; then
                echo "ERROR: Dry run failed applying $FILENAME" >&2
                DRYRUN_FAILED=true
                break
            fi
        done
    fi

    # Discover current dryrun_*-prefixed tables fresh, rather than reusing the
    # pre-migration snapshot — a migration that creates/renames a table would
    # otherwise leave an orphan the old snapshot never knew about.
    log "Dry run: cleaning up scratch tables"
    DRYRUN_CLEANUP_TABLES=$(wp db query \
        "SELECT table_name FROM information_schema.tables \
         WHERE table_schema = DATABASE() \
         AND LEFT(table_name, CHAR_LENGTH('${DRYRUN_PREFIX}')) = '${DRYRUN_PREFIX}'" \
        --path="$WP_ROOT" --skip-column-names)

    DRYRUN_CLEANUP_SQL=""
    while IFS= read -r DRYRUN_TABLE; do
        [ -z "$DRYRUN_TABLE" ] && continue
        DRYRUN_CLEANUP_SQL+="DROP TABLE IF EXISTS \`$DRYRUN_TABLE\`;"$'\n'
    done <<< "$DRYRUN_CLEANUP_TABLES"

    if [ -n "$DRYRUN_CLEANUP_SQL" ]; then
        printf '%s' "$DRYRUN_CLEANUP_SQL" | wp db query --path="$WP_ROOT" || true
    fi
    set -e

    if [ "$DRYRUN_FAILED" = true ]; then
        echo "ERROR: Dry run detected a migration failure — bailing out before touching live tables. No live data was touched." >&2
        exit 1
    fi

    log "Dry run passed"

    # Point of no return — live tables are about to change, no clone/backup to fall back to.
    SAFE_TO_RECOVER=false

    log "Applying migrations against live tables (prefix '$CURRENT_PREFIX')"
    WP_ROOT="$WP_ROOT" \
    MIGRATIONS_TABLE="$MIGRATIONS_TABLE" \
    TARGET_PREFIX="$CURRENT_PREFIX" \
    BATCH="$FULL_GIT_SHA" \
        bash "$MIGRATE_SCRIPT"

    log "Database migrations complete"
fi

# ==============================================================================
# Step 4: Component swap — stage every component, then swap all into place
# ==============================================================================

log "Deploying components for release $GIT_SHA"

mkdir -p "$RELEASES_DIR"

# Protects releases/ from being served over HTTP — best-effort only; see
# README Requirements for why (.htaccess/AllowOverride, permission model on
# shared hosting) and the active check that actually confirms it worked.
# Overwritten, not appended: this file has exactly one job, and Apache
# combines sibling Require directives as an OR, so appending our deny rule
# next to a pre-existing "Require all granted" wouldn't actually deny anything.
printf 'Require all denied\n' > "$RELEASES_DIR/.htaccess"
chmod 700 "$RELEASES_DIR" || true

# Pass 1: stage (rsync) every component before changing any live path. No
# maintenance mode here (zero-downtime by design when nothing's pending) —
# this narrows, not eliminates, the window where a partial failure could
# leave a mix of old/new components live.
for COMPONENT in "${COMPONENTS[@]}"; do
    TYPE="${COMPONENT%%:*}"
    NAME="${COMPONENT##*:}"
    LIVE_PATH="$WP_ROOT/wp-content/$TYPE/$NAME"
    RELEASE_PATH="$NEW_RELEASE_DIR/$TYPE/$NAME"
    STAGING_PATH="${LIVE_PATH}.deploying"
    OLD_PATH="${LIVE_PATH}.previous"

    # Clear any remnants from a previous failed deploy
    rm -rf "$STAGING_PATH" "$OLD_PATH"

    # Rsync to a hidden staging directory not yet visible to WordPress
    mkdir -p "$STAGING_PATH"
    rsync -a --delete "$RELEASE_PATH/" "$STAGING_PATH/"

    log "  Staged $TYPE/$NAME"
done

log "All components staged — swapping into place"

# Pass 2: only reached once every rsync above succeeded.
for COMPONENT in "${COMPONENTS[@]}"; do
    TYPE="${COMPONENT%%:*}"
    NAME="${COMPONENT##*:}"
    LIVE_PATH="$WP_ROOT/wp-content/$TYPE/$NAME"
    RELEASE_PATH="$NEW_RELEASE_DIR/$TYPE/$NAME"
    STAGING_PATH="${LIVE_PATH}.deploying"
    OLD_PATH="${LIVE_PATH}.previous"

    # Atomic rename: live → .previous, staging → live
    if [ -e "$LIVE_PATH" ] || [ -L "$LIVE_PATH" ]; then
        mv "$LIVE_PATH" "$OLD_PATH"
    fi
    mv "$STAGING_PATH" "$LIVE_PATH"
    rm -rf "$OLD_PATH"

    log "  $TYPE/$NAME -> $RELEASE_PATH"
done

# ==============================================================================
# Step 5: Disable maintenance mode
#
# Done before pruning so the site comes back up even if cleanup fails.
# ==============================================================================

if [ "$MAINTENANCE_ACTIVE" = true ]; then
    if [ "$MAINTENANCE_ALREADY_ACTIVE" = true ]; then
        log "This deploy succeeded, but maintenance mode predates this run — leaving it enabled rather than clearing a state it didn't set"
        log "An earlier deploy may still need manual recovery. Once verified safe: wp maintenance-mode deactivate --path=\"$WP_ROOT\""
    else
        log "Disabling maintenance mode"
        if ! wp maintenance-mode deactivate --path="$WP_ROOT"; then
            log "ERROR: Failed to deactivate maintenance mode — run manually:"
            log "ERROR:   wp maintenance-mode deactivate --path=\"$WP_ROOT\""
            exit 2
        fi
    fi
    MAINTENANCE_ACTIVE=false
fi

# ==============================================================================
# Step 6: Prune old releases — keep current + 1 prior
# ==============================================================================

log "Pruning old releases"

while IFS= read -r OLD_RELEASE; do
    # Only remove directories that look like ours (releases-dir could point
    # anywhere absolute) — every real release has this file, so an unrelated
    # sibling directory never matches.
    if [ ! -f "$OLD_RELEASE/migrations/components.txt" ]; then
        log "  Skipping $OLD_RELEASE — doesn't look like a release this pipeline created"
        continue
    fi
    log "  Removing $OLD_RELEASE"
    rm -rf "$OLD_RELEASE" || log "WARN: Could not remove $OLD_RELEASE — manual cleanup may be needed"
done < <(find "$RELEASES_DIR" -maxdepth 1 -mindepth 1 -type d \
    ! -name "$GIT_SHA" ! -name "initial" \
    -printf '%T@ %p\n' | sort -rn | tail -n +2 | cut -d' ' -f2-)

log "Atomic deploy complete — $GIT_SHA is live"
