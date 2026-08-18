#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# swap.sh — Atomic deploy: migrations + component swap
#
# Uploaded to the server by the swap-and-migrate action on each deploy.
# Do not copy or edit this file per-project — changes belong in the action.
#
# Injected by the action:
#   WP_ROOT    Absolute path to the WordPress root (e.g. /home/piecode/site/public_html)
#   GIT_SHA    Git commit SHA for this deployment (8-character short SHA is acceptable)
#   REPO_NAME  GitHub repository name (used to derive migrations table name)
#
# Components are read from components.txt in the same directory, written by the
# action before this script runs. Format: one "type:name" entry per line.
# ==============================================================================

SHORT_SHA="${GIT_SHA:0:8}"
RELEASES_DIR="${RELEASES_DIR:-$WP_ROOT/releases}"
NEW_RELEASE_DIR="$RELEASES_DIR/$GIT_SHA"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIGRATE_SCRIPT="$SCRIPT_DIR/migrate.sh"
QUERIES_DIR="$SCRIPT_DIR/queries"
HAS_MIGRATIONS=false
MAINTENANCE_ACTIVE=false
SAFE_TO_RECOVER=true

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# Fires on any non-zero exit via set -euo pipefail.
#
# If maintenance mode was never activated, nothing to do.
# If activated and we haven't yet touched wp-config or components, it is safe to
# deactivate — the live site is unmodified. Exit 1.
# If activated and live changes have begun (SAFE_TO_RECOVER=false), the site
# must stay in maintenance mode until manually verified. Exit 2.
cleanup() {
    local EXIT_CODE=$?
    [ $EXIT_CODE -eq 0 ] && return
    if [ "$MAINTENANCE_ACTIVE" = true ]; then
        if [ "$SAFE_TO_RECOVER" = true ]; then
            log "Deploy failed before live changes — deactivating maintenance mode"
            wp maintenance-mode deactivate --path="$WP_ROOT" || true
            exit 1
        else
            log "ERROR: Deploy failed after live changes began — site is in maintenance mode"
            log "ERROR: Before deactivating maintenance mode, verify:"
            log "ERROR:   wp config get table_prefix --path=\"$WP_ROOT\""
            log "ERROR:   ls -la $WP_ROOT/wp-content/plugins/ $WP_ROOT/wp-content/themes/"
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

CURRENT_PREFIX=$(wp config get table_prefix --path="$WP_ROOT")

# CURRENT_PREFIX is interpolated into SQL string literals and identifiers below
# (directly, and via BASE_PREFIX/NEW_PREFIX derived from it). WordPress's own
# installer already restricts table_prefix to this character set — enforcing
# it here means a misconfigured wp-config.php fails cleanly instead of
# corrupting a query or behaving like injected SQL.
if [[ ! "$CURRENT_PREFIX" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    echo "ERROR: table_prefix '$CURRENT_PREFIX' contains unexpected characters — refusing to use it in SQL. Expected only letters, digits, and underscores, not starting with a digit." >&2
    exit 1
fi

# Derived unconditionally (not just when migrations are pending) so its
# length is known before REPO_SLUG below is sized against it — NEW_PREFIX
# (used later if migrations do run) is always this plus an 8-char short SHA
# and "_", making it the longer of the two prefixes this repo's migrations
# table name can be built with.
BASE_PREFIX=$(printf '%s' "$CURRENT_PREFIX" | sed 's/[0-9a-f]\{8\}_$//')

# REPO_SLUG is embedded into the migrations tracking table name under both
# CURRENT_PREFIX and NEW_PREFIX. MySQL caps identifiers at 64 characters, so
# cap REPO_SLUG to whatever's left after the longer (NEW_PREFIX) case,
# instead of a flat cut that ignores the prefix entirely — a flat cap left
# room to overflow 64 as soon as a repo name pushed REPO_SLUG near its limit.
MIGRATIONS_SUFFIX="_migrations"
MAX_SLUG_LEN=$(( 64 - ${#BASE_PREFIX} - ${#SHORT_SHA} - 1 - ${#MIGRATIONS_SUFFIX} ))
if [ "$MAX_SLUG_LEN" -lt 1 ]; then
    echo "ERROR: table_prefix '$CURRENT_PREFIX' is too long to derive a migrations table name within MySQL's 64-character identifier limit." >&2
    exit 1
fi
REPO_SLUG="$(printf '%s' "$REPO_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g' | cut -c1-"$MAX_SLUG_LEN")"

LIVE_MIGRATIONS_TABLE="${CURRENT_PREFIX}${REPO_SLUG}_migrations"

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

# TYPE and NAME are extracted from each entry below and built into paths that
# are later passed to mv/rm -rf. Restricting to slug-safe characters up front
# rules out a stray '/' or '..' steering those destructive calls outside
# wp-content/, however the entry ended up malformed.
for COMPONENT in "${COMPONENTS[@]}"; do
    if [[ ! "$COMPONENT" =~ ^[A-Za-z0-9_-]+:[A-Za-z0-9_-]+$ ]]; then
        echo "ERROR: Invalid component entry '$COMPONENT' — expected type:name using only letters, digits, hyphens, and underscores." >&2
        exit 1
    fi
done

log "Validating component release paths"
for COMPONENT in "${COMPONENTS[@]}"; do
    NAME="${COMPONENT##*:}"
    RELEASE_PATH="$NEW_RELEASE_DIR/$NAME"
    if [ ! -d "$RELEASE_PATH" ]; then
        echo "ERROR: $RELEASE_PATH not found — did the rsync job for $NAME complete?" >&2
        exit 1
    fi
done

# ==============================================================================
# Step 2: Detect pending migrations
# ==============================================================================

PENDING_FILES=()

if [ -d "$QUERIES_DIR" ]; then
    APPLIED=$(wp db query \
        "SELECT filename FROM \`$LIVE_MIGRATIONS_TABLE\`" \
        --path="$WP_ROOT" --skip-column-names 2>/dev/null || echo "")

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
# Step 3: Database migrations
#
# Prefix derivation and pre-existence check run before the maintenance window
# so a retry collision or bad config fails before any downtime.
# ==============================================================================

if [ "$HAS_MIGRATIONS" = true ]; then

    # BASE_PREFIX was already derived above (stable base with any previous
    # atomic-deploy SHA suffix stripped) so REPO_SLUG could be sized against it.
    # e.g. wp_ -> wp_abc12345_; foo_abc12345_ -> foo_ -> foo_def67890_
    NEW_PREFIX="${BASE_PREFIX}${SHORT_SHA}_"
    NEW_MIGRATIONS_TABLE="${NEW_PREFIX}${REPO_SLUG}_migrations"
    log "Table prefix: '$CURRENT_PREFIX' -> '$NEW_PREFIX'"

    EXISTING_COUNT=$(wp db query \
        "SELECT COUNT(*) FROM information_schema.tables \
         WHERE table_schema = DATABASE() \
         AND LEFT(table_name, CHAR_LENGTH('${NEW_PREFIX}')) = '${NEW_PREFIX}'" \
        --path="$WP_ROOT" --skip-column-names)

    if [ "$EXISTING_COUNT" -gt 0 ]; then
        echo "ERROR: Tables with prefix '${NEW_PREFIX}' already exist — a previous deploy attempt may have left partial data." >&2
        echo "ERROR: Drop them before retrying:" >&2
        wp db query \
            "SELECT CONCAT('DROP TABLE \`', table_name, '\`;') \
             FROM information_schema.tables \
             WHERE table_schema = DATABASE() \
             AND LEFT(table_name, CHAR_LENGTH('${NEW_PREFIX}')) = '${NEW_PREFIX}'" \
            --path="$WP_ROOT" --skip-column-names >&2
        exit 1
    fi

    log "Enabling maintenance mode"
    wp maintenance-mode activate --path="$WP_ROOT"
    MAINTENANCE_ACTIVE=true

    # ------------------------------------------------------------------
    # Dry run: validate pending migration patches before spending time on
    # a backup and the full data clone below. Patches are applied to
    # structure-only clones of the live tables (columns/indexes, no rows)
    # under a throwaway prefix, then those clones are dropped immediately.
    # Live data and the real NEW_PREFIX clone are untouched either way —
    # a data-dependent patch (e.g. an UPDATE matching on row content) can
    # still pass here and fail for other reasons later, since no rows
    # exist yet to match against.
    # ------------------------------------------------------------------
    log "Dry run: validating ${#PENDING_FILES[@]} pending migration(s) against a structure-only clone"

    DRYRUN_PREFIX="dryrun_${SHORT_SHA}_"
    DRYRUN_SOURCE_TABLES=$(wp db query \
        "SELECT table_name FROM information_schema.tables \
         WHERE table_schema = DATABASE() \
         AND LEFT(table_name, CHAR_LENGTH('${CURRENT_PREFIX}')) = '${CURRENT_PREFIX}'" \
        --path="$WP_ROOT" --skip-column-names)

    set +e
    DRYRUN_FAILED=false

    # Clear any remnants from a previous failed attempt at this SHA, then clone structure only.
    while IFS= read -r TABLE; do
        [ -z "$TABLE" ] && continue
        DRYRUN_TABLE="${DRYRUN_PREFIX}${TABLE#$CURRENT_PREFIX}"
        wp db query "DROP TABLE IF EXISTS \`$DRYRUN_TABLE\`" --path="$WP_ROOT" || true
        wp db query "CREATE TABLE \`$DRYRUN_TABLE\` LIKE \`$TABLE\`" --path="$WP_ROOT" || DRYRUN_FAILED=true
    done <<< "$DRYRUN_SOURCE_TABLES"

    if [ "$DRYRUN_FAILED" = false ]; then
        for SQL_FILE in "${PENDING_FILES[@]}"; do
            FILENAME=$(basename "$SQL_FILE")
            log "Dry run: applying $FILENAME"
            if ! sed "s/__WP_PREFIX__/${DRYRUN_PREFIX}/g" "$SQL_FILE" | wp db query --path="$WP_ROOT"; then
                echo "ERROR: Dry run failed applying $FILENAME" >&2
                DRYRUN_FAILED=true
                break
            fi
        done
    fi

    log "Dry run: cleaning up scratch tables"
    while IFS= read -r TABLE; do
        [ -z "$TABLE" ] && continue
        DRYRUN_TABLE="${DRYRUN_PREFIX}${TABLE#$CURRENT_PREFIX}"
        wp db query "DROP TABLE IF EXISTS \`$DRYRUN_TABLE\`" --path="$WP_ROOT" || true
    done <<< "$DRYRUN_SOURCE_TABLES"
    set -e

    if [ "$DRYRUN_FAILED" = true ]; then
        echo "ERROR: Dry run detected a migration failure — bailing out before the database backup. No live data was touched." >&2
        exit 1
    fi

    log "Dry run passed"

    BACKUP_DIR="$(dirname "$RELEASES_DIR")/db-backups"
    mkdir -p "$BACKUP_DIR"
    BACKUP_FILE="$BACKUP_DIR/pre_deploy_${SHORT_SHA}_$(date +%Y%m%d%H%M%S).sql"
    log "Exporting database backup to $BACKUP_FILE"
    wp db export "$BACKUP_FILE" --path="$WP_ROOT"

    log "Copying tables from prefix '$CURRENT_PREFIX' to '$NEW_PREFIX'"

    TABLES=$(wp db query \
        "SELECT table_name FROM information_schema.tables \
         WHERE table_schema = DATABASE() \
         AND LEFT(table_name, CHAR_LENGTH('${CURRENT_PREFIX}')) = '${CURRENT_PREFIX}'" \
        --path="$WP_ROOT" --skip-column-names)

    while IFS= read -r TABLE; do
        [ -z "$TABLE" ] && continue
        NEW_TABLE="${NEW_PREFIX}${TABLE#$CURRENT_PREFIX}"
        log "  $TABLE -> $NEW_TABLE"
        wp db query "CREATE TABLE \`$NEW_TABLE\` LIKE \`$TABLE\`" --path="$WP_ROOT"
        wp db query "INSERT INTO \`$NEW_TABLE\` SELECT * FROM \`$TABLE\`" --path="$WP_ROOT"
    done <<< "$TABLES"

    # CREATE TABLE ... LIKE (above) copies columns and indexes but not foreign
    # key constraints or triggers, so both are rebuilt here from
    # information_schema before the old tables are dropped for good. Names
    # get a "_$SHORT_SHA" suffix — constraint/trigger names are unique per
    # schema and the old ones are still around until the drop step below.
    # Trigger bodies are copied verbatim: one that only touches its own table
    # (the common case, via NEW/OLD) is fully correct, but a body that
    # references another prefixed table by name still points at the old
    # prefix, since rewriting arbitrary SQL text safely isn't possible here.
    log "Recreating foreign keys on new prefix tables"

    # wp db query falls back to printing a generic "Success: Query succeeded"
    # status line to stdout when a SELECT matches zero rows, instead of
    # nothing — so an empty result from the DDL-building query below can't be
    # told apart from real output just by checking for a non-empty capture.
    # COUNT(*) always returns exactly one real row, zero matches included,
    # so gate on that first and only build/run the DDL query when it's certain
    # to have actual rows to return.
    FK_COUNT=$(wp db query \
        "SELECT COUNT(*) FROM (
             SELECT kcu.TABLE_NAME
             FROM information_schema.KEY_COLUMN_USAGE kcu
             WHERE kcu.CONSTRAINT_SCHEMA = DATABASE()
               AND kcu.REFERENCED_TABLE_NAME IS NOT NULL
               AND LEFT(kcu.TABLE_NAME, CHAR_LENGTH('${CURRENT_PREFIX}')) = '${CURRENT_PREFIX}'
             GROUP BY kcu.TABLE_NAME, kcu.CONSTRAINT_NAME
         ) fk_count" \
        --path="$WP_ROOT" --skip-column-names)

    if [ "$FK_COUNT" -gt 0 ]; then
    FK_DDL=$(wp db query \
        "SELECT CONCAT(
             'ALTER TABLE \`', new_table, '\` ADD CONSTRAINT \`', new_constraint, '\` ',
             'FOREIGN KEY (', cols, ') REFERENCES \`', new_ref_table, '\` (', ref_cols, ') ',
             'ON DELETE ', delete_rule, ' ON UPDATE ', update_rule, ';'
         )
         FROM (
             SELECT
                 CONCAT('${NEW_PREFIX}', SUBSTRING(kcu.TABLE_NAME, CHAR_LENGTH('${CURRENT_PREFIX}') + 1)) AS new_table,
                 CONCAT(SUBSTRING(kcu.CONSTRAINT_NAME, 1, 54), '_${SHORT_SHA}') AS new_constraint,
                 GROUP_CONCAT(CONCAT('\`', kcu.COLUMN_NAME, '\`') ORDER BY kcu.ORDINAL_POSITION) AS cols,
                 CASE WHEN LEFT(kcu.REFERENCED_TABLE_NAME, CHAR_LENGTH('${CURRENT_PREFIX}')) = '${CURRENT_PREFIX}'
                      THEN CONCAT('${NEW_PREFIX}', SUBSTRING(kcu.REFERENCED_TABLE_NAME, CHAR_LENGTH('${CURRENT_PREFIX}') + 1))
                      ELSE kcu.REFERENCED_TABLE_NAME END AS new_ref_table,
                 GROUP_CONCAT(CONCAT('\`', kcu.REFERENCED_COLUMN_NAME, '\`') ORDER BY kcu.ORDINAL_POSITION) AS ref_cols,
                 rc.DELETE_RULE AS delete_rule,
                 rc.UPDATE_RULE AS update_rule
             FROM information_schema.KEY_COLUMN_USAGE kcu
             JOIN information_schema.REFERENTIAL_CONSTRAINTS rc
                 ON rc.CONSTRAINT_SCHEMA = kcu.CONSTRAINT_SCHEMA
                 AND rc.CONSTRAINT_NAME = kcu.CONSTRAINT_NAME
                 AND rc.TABLE_NAME = kcu.TABLE_NAME
             WHERE kcu.CONSTRAINT_SCHEMA = DATABASE()
               AND kcu.REFERENCED_TABLE_NAME IS NOT NULL
               AND LEFT(kcu.TABLE_NAME, CHAR_LENGTH('${CURRENT_PREFIX}')) = '${CURRENT_PREFIX}'
             GROUP BY kcu.TABLE_NAME, kcu.CONSTRAINT_NAME, kcu.REFERENCED_TABLE_NAME, rc.DELETE_RULE, rc.UPDATE_RULE
         ) fk" \
        --path="$WP_ROOT" --skip-column-names)

        printf '%s\n' "$FK_DDL" | wp db query --path="$WP_ROOT"
    fi

    log "Recreating triggers on new prefix tables"

    TRIGGER_COUNT=$(wp db query \
        "SELECT COUNT(*) FROM information_schema.TRIGGERS
         WHERE TRIGGER_SCHEMA = DATABASE()
           AND LEFT(EVENT_OBJECT_TABLE, CHAR_LENGTH('${CURRENT_PREFIX}')) = '${CURRENT_PREFIX}'" \
        --path="$WP_ROOT" --skip-column-names)

    if [ "$TRIGGER_COUNT" -gt 0 ]; then
    # A trigger body is often a multi-statement BEGIN...END block, which has
    # its own semicolons — piped through mysql's stdin (as wp db query does
    # here), those would otherwise get split as separate top-level statements
    # the same way they would from a plain .sql file. Ending each generated
    # statement in '$$' instead of ';', bracketed by DELIMITER changes, is
    # MySQL's own documented fix for exactly this.
    TRIGGER_DDL=$(wp db query \
        "SELECT CONCAT(
             'CREATE TRIGGER \`', SUBSTRING(TRIGGER_NAME, 1, 54), '_${SHORT_SHA}\` ',
             ACTION_TIMING, ' ', EVENT_MANIPULATION, ' ON \`',
             '${NEW_PREFIX}', SUBSTRING(EVENT_OBJECT_TABLE, CHAR_LENGTH('${CURRENT_PREFIX}') + 1), '\` ',
             'FOR EACH ROW ', ACTION_STATEMENT, '\$\$'
         )
         FROM information_schema.TRIGGERS
         WHERE TRIGGER_SCHEMA = DATABASE()
           AND LEFT(EVENT_OBJECT_TABLE, CHAR_LENGTH('${CURRENT_PREFIX}')) = '${CURRENT_PREFIX}'" \
        --path="$WP_ROOT" --skip-column-names)

        printf 'DELIMITER $$\n%s\nDELIMITER ;\n' "$TRIGGER_DDL" | wp db query --path="$WP_ROOT"
    fi

    log "Applying migrations against new prefix '$NEW_PREFIX'"
    WP_ROOT="$WP_ROOT" \
    MIGRATIONS_TABLE="$NEW_MIGRATIONS_TABLE" \
    NEW_PREFIX="$NEW_PREFIX" \
        bash "$MIGRATE_SCRIPT"

    log "Updating usermeta keys and option names from '$CURRENT_PREFIX' to '$NEW_PREFIX'"
    wp db query "UPDATE \`${NEW_PREFIX}usermeta\` SET meta_key = REPLACE(meta_key, '${CURRENT_PREFIX}', '${NEW_PREFIX}') WHERE LEFT(meta_key, CHAR_LENGTH('${CURRENT_PREFIX}')) = '${CURRENT_PREFIX}'" --path="$WP_ROOT"
    wp db query "UPDATE \`${NEW_PREFIX}options\` SET option_name = REPLACE(option_name, '${CURRENT_PREFIX}', '${NEW_PREFIX}') WHERE LEFT(option_name, CHAR_LENGTH('${CURRENT_PREFIX}')) = '${CURRENT_PREFIX}'" --path="$WP_ROOT"

    # ------------------------------------------------------------------
    # Point of no return — wp-config.php and components are about to change.
    # Any failure from here requires manual verification before the site
    # can safely come back up. The cleanup trap exits 2 if MAINTENANCE_ACTIVE
    # is true and SAFE_TO_RECOVER is false.
    # ------------------------------------------------------------------
    SAFE_TO_RECOVER=false

    log "Switching wp-config.php table_prefix to '$NEW_PREFIX'"
    wp config set table_prefix "$NEW_PREFIX" --path="$WP_ROOT"

    log "Dropping old tables with prefix '$CURRENT_PREFIX'"
    {
        echo "SET FOREIGN_KEY_CHECKS=0;"
        while IFS= read -r TABLE; do
            [ -z "$TABLE" ] && continue
            echo "DROP TABLE IF EXISTS \`$TABLE\`;"
        done <<< "$TABLES"
        echo "SET FOREIGN_KEY_CHECKS=1;"
    } | wp db query --path="$WP_ROOT"

    log "Database migrations complete"
fi

# ==============================================================================
# Step 4: Component swap
#
# Each component is rsynced to a hidden staging directory, then atomically
# renamed into place. WordPress ignores directories starting with '.', so
# the staging copy is never served during the transfer.
# ==============================================================================

log "Deploying components for release $GIT_SHA"

mkdir -p "$RELEASES_DIR"

for COMPONENT in "${COMPONENTS[@]}"; do
    TYPE="${COMPONENT%%:*}"
    NAME="${COMPONENT##*:}"
    LIVE_PATH="$WP_ROOT/wp-content/$TYPE/$NAME"
    RELEASE_PATH="$NEW_RELEASE_DIR/$NAME"
    STAGING_PATH="${LIVE_PATH}.deploying"
    OLD_PATH="${LIVE_PATH}.previous"

    # Clear any remnants from a previous failed deploy
    rm -rf "$STAGING_PATH" "$OLD_PATH"

    # Rsync to a hidden staging directory not yet visible to WordPress
    mkdir -p "$STAGING_PATH"
    rsync -a --delete "$RELEASE_PATH/" "$STAGING_PATH/"

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
# MAINTENANCE_ACTIVE is set to false regardless — the cleanup trap must not
# attempt a second deactivation after this point.
# ==============================================================================

if [ "$MAINTENANCE_ACTIVE" = true ]; then
    log "Disabling maintenance mode"
    if ! wp maintenance-mode deactivate --path="$WP_ROOT"; then
        log "ERROR: Failed to deactivate maintenance mode — run manually:"
        log "ERROR:   wp maintenance-mode deactivate --path=\"$WP_ROOT\""
        exit 2
    fi
    MAINTENANCE_ACTIVE=false
fi

# ==============================================================================
# Step 6: Prune old releases — keep current + 1 prior
# ==============================================================================

log "Pruning old releases"

while IFS= read -r OLD_RELEASE; do
    log "  Removing $OLD_RELEASE"
    rm -rf "$OLD_RELEASE" || log "WARN: Could not remove $OLD_RELEASE — manual cleanup may be needed"
done < <(find "$RELEASES_DIR" -maxdepth 1 -mindepth 1 -type d \
    ! -name "$GIT_SHA" ! -name "initial" \
    -printf '%T@ %p\n' | sort -rn | tail -n +2 | cut -d' ' -f2-)

# ==============================================================================
# Step 7: Prune old database backups — keep only this deploy's backup
# ==============================================================================

if [ "$HAS_MIGRATIONS" = true ]; then
    log "Pruning old database backups — keeping only $(basename "$BACKUP_FILE")"

    while IFS= read -r OLD_BACKUP; do
        log "  Removing $OLD_BACKUP"
        rm -f "$OLD_BACKUP" || log "WARN: Could not remove $OLD_BACKUP — manual cleanup may be needed"
    done < <(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'pre_deploy_*.sql' ! -name "$(basename "$BACKUP_FILE")")
fi

log "Atomic deploy complete — $GIT_SHA is live"
