# GitHub Workflows for PIE.co.de

This repository contains reusable workflows and composite actions for managing repository deployment.

## Workflows

### Prepare Releases Directory

Creates and protects `releases/` — `.htaccess` (`Require all denied`) plus `chmod 700` — before anything is uploaded into it. Must run as the first job in the deploy pipeline, before the plugin/theme/migrations rsync jobs and before Atomic Deploy: those all upload content to `releases/` independently, and each does so before `swap.sh` (which repeats this same protection, but too late to matter if a rsync job or an early migration failure means `swap.sh` never gets that far) ever runs. Protecting an empty directory before anything lands in it, rather than a populated one after the fact, is what actually closes that gap.

**Inputs:**

- `ssh-host`: SSH host. Required.
- `wp-root`: Absolute path to the WordPress root on the server. Required. Must start with `/`.
- `ssh-port`: SSH port. Optional, default is `22`.
- `ssh-user`: SSH user. Optional, default is `piecode`.
- `releases-dir`: Absolute path to the releases directory on the server. Optional, defaults to a `releases` subdirectory inside `wp-root` — must match whatever `releases-dir` Atomic Deploy is given, if that's overridden.

**Secrets:**

- `SSH_PRIVATE_KEY`: SSH private key. Required — the same one used for Atomic Deploy.

**Example:** see Atomic Deploy's example below — `prepare_releases_dir` is the job every upload job (and, transitively, `atomic_deploy`) depends on.

---

### Atomic Deploy

Deploys components to a release directory keyed by the short (8-character) git commit SHA, then atomically swaps them into place and runs any pending database migrations directly against the live tables. When migrations are pending, the database work and component swap are performed inside a maintenance window. When there are no pending migrations, components are swapped with no downtime. Migrations run with no table clone or automated backup — the only pre-flight check is a dry run against a disposable structure-only clone. Take a full site backup and confirm migrations against staging before deploying; see **Migrations run against live tables** below.

**How it works:**

The **Prepare Releases Directory** workflow (see below) must run first, before anything is rsynced anywhere — it creates and protects `releases/` while it's still empty, so the protection in step 4 below isn't the first time it's applied. Rsync jobs then deploy each component to a release directory keyed by the short SHA (see the `setup` workflow's `short-sha` output). Once all jobs complete, the `atomic_deploy` job SSH's in and runs `swap.sh`, which:

1. Verifies WP-CLI can reach the database
2. Checks for pending SQL migrations
3. If any: enables maintenance mode → dry-runs the pending migrations against structure-only clones of the live tables (no data, dropped immediately after) and bails out with maintenance mode deactivated if any fail → runs migrations directly against the live tables
4. Creates `releases/.htaccess` and tightens `releases/` to `chmod 700` if they aren't already there (see **Requirements** below — a defensive, idempotent repeat of what Prepare Releases Directory already did before any upload happened, not the first application of it), then rsyncs each component from the release directory to a hidden staging path and atomically renames it into place
5. Prunes releases older than 1 prior

If `site-url` is set, the `atomic_deploy` job then runs one more check after `swap.sh` finishes: fetching a file under `releases/` over real HTTP and failing the job if it's actually reachable — this doesn't touch the deploy, which has already completed by that point, but does surface as a failed run (see **Requirements**).

Failures are handled based on how far the deploy got:

- **Before migrations start** (dry run failed) — maintenance mode is deactivated automatically and the site recovers on the previous version, *unless* it was already active before this run started (e.g. left on by an earlier failed deploy still awaiting manual recovery) — in that case it's left as-is rather than clearing a state this run didn't set, and the log says so.
- **After migrations start** — maintenance mode stays on; there is no clone or backup to recover from automatically. Manual verification instructions are printed in the run's log output.

No email notification is sent — GitHub's own workflow-failure notifications (to whoever triggered the run, per their notification settings) cover that; check the Actions log for which case applies and what to do next.

**Concurrency:**

`atomic_deploy` and **Rollback Migrations** share a `concurrency` group keyed on `ssh-host`+`wp-root` — queued, never cancelled, so a rollback and a deploy to the same site never touch the live tables or migrations tracking table at the same time.

That alone doesn't cover the rsync jobs, which upload independently of that lock. Two overlapping deploys to the same site could otherwise race: one's release-pruning step (Step 5 above) could delete the other's freshly-uploaded release directory before its own `atomic_deploy` gets to use it — the second deploy fails cleanly (its release directory goes missing), but confusingly, for a deploy that actually uploaded fine. Close this by adding a workflow-level `concurrency` block to your own calling workflow, so the whole run — rsync jobs included — queues behind any other run of it:

```yaml
concurrency:
  group: ${{ github.workflow }}
  cancel-in-progress: false
```

This doesn't need to match the group key above — that pair already handles deploy-vs-rollback DB safety independently of this.

**Migrations run against live tables:**

Earlier versions of this workflow cloned every table to a new prefix, migrated the copy, then switched `wp-config.php` over — giving an instant fallback if something went wrong, at the cost of a lot of moving parts (full DB export, foreign key/trigger reconstruction, prefix bookkeeping) for a safety net that MySQL's non-transactional DDL couldn't fully honour anyway. Mainstream migration tools (Laravel, Rails, Django) don't clone either — they migrate live tables directly, for the same reason. This workflow now does the same:

- **Confirm migrations against a staging copy of the site first.** The dry run here only checks that the SQL is syntactically valid against the live schema — it can't tell you whether the migration does the right thing.
- **Take a full site backup before deploying migrations.** Nothing in this workflow backs up the database. If a migration fails partway through, the affected tables are left in whatever state that migration reached, and the deploy stops with the site in maintenance mode for manual recovery — there's no automatic revert.

**Server directory structure:**

`releases/` is created inside `wp-root` — not a sibling of it — because some hosts don't grant the deploy user write access above the web root. See **Requirements** below for the access rule this requires.

```
/home/piecode/site/public_html/     ← WordPress root
├── releases/
│   ├── {current-sha}/          ← new deploy lands here via rsync
│   │   ├── plugins/
│   │   │   └── my-plugin/
│   │   ├── themes/
│   │   │   └── my-theme/
│   │   └── migrations/
│   └── {previous-sha}/         ← kept for rollback
└── wp-content/
    ├── plugins/
    │   └── my-plugin/      ← files copied from releases/{sha}/plugins/my-plugin/
    └── themes/
        └── my-theme/       ← files copied from releases/{sha}/themes/my-theme/
```

**Requirements:**

`releases/` lives inside `wp-root` — not a sibling of it — because some hosts (confirmed on at least two we've deployed to) don't grant the deploy user write access above the web root. That means it's web-reachable by default unless blocked, and no single mechanism guarantees that across every host, so this uses three layers together rather than relying on any one of them:

1. **Automatic, before anything is uploaded:** the **Prepare Releases Directory** workflow creates `releases/.htaccess` (`Require all denied`) and tightens the directory to `chmod 700` — required as the first job in the deploy pipeline (see its own section below), so `releases/` is protected before the plugin/theme/migrations rsync jobs or `swap-and-migrate`'s own upload ever put anything in it. `swap.sh` repeats the same thing, idempotently, as a defensive fallback — but that runs after this deploy's own dry run and live migrations, which is too late to matter if either of those fails first; the workflow running first is what actually closes the gap. Neither is a guarantee on its own regardless of timing — `.htaccess` only takes effect on Apache with `AllowOverride` enabled for that path, and the permission tightening only blocks the web server where it runs as a *different* OS user than the deploy user, which isn't true on most per-site shared hosting (PHP-FPM-per-user, `suexec`, etc. — the same architecture that forces `releases/` inside `wp-root` in the first place).
2. **Manual, one-time, per host — do this before your first deploy:** add the actual server-level deny rule, since (1) can't be relied on alone:
   - **Apache** (if `AllowOverride` isn't already enabled for `wp-root`) — add to the vhost config:
     ```apache
     <Directory "/path/to/wp-root/releases">
       Require all denied
     </Directory>
     ```
   - **Nginx** — add to the site's server block:
     ```nginx
     location ~ ^/releases/ { deny all; }
     ```
3. **Automatic, every deploy, if `site-url` is set:** a final workflow step fetches a known file under `releases/` over real HTTP and fails the job if it's actually reachable — see **Inputs** below. This is what actually confirms (1) and (2) are working, rather than trusting either blindly; it doesn't affect the deploy itself, which has already fully completed by the time this runs.

**Inputs:**

- `ssh-host`: SSH host. Required.
- `wp-root`: Absolute path to the WordPress root on the server. Required. Must start with `/`.
- `components`: Newline-separated list of components in `type:name` format. Required. The rsync job for each one must deploy to `releases/{sha}/{type}/{name}` (not just `{name}`) — otherwise a plugin and a theme sharing the same name would resolve to the same release path and clobber each other.
- `ssh-port`: SSH port. Optional, default is `22`.
- `ssh-user`: SSH user. Optional, default is `piecode`.
- `site-url`: Public URL of the site (e.g. `https://example.com`). Optional, but strongly recommended — enables the post-deploy `releases/` exposure check described above. The check is skipped entirely when this is omitted.

**Secrets:**

- `SSH_PRIVATE_KEY`: SSH private key. Required.

**Example:**

```yaml
name: Deploy to Production
on:
  push:
    branches:
      - production
jobs:
  setup:
    uses: pie/.github/.github/workflows/setup.yaml@main

  prepare_releases_dir:
    needs: setup
    uses: pie/.github/.github/workflows/prepare-releases-dir.yaml@main
    with:
      ssh-host: example.com
      wp-root: /home/piecode/site/public_html
    secrets:
      SSH_PRIVATE_KEY: ${{secrets.SSH_PRIVATE_KEY}}

  deploy_plugin:
    needs: [setup, prepare_releases_dir]
    uses: pie/.github/.github/workflows/deploy.yaml@main
    with:
      ssh-host: example.com
      destination-path: /home/piecode/site/public_html/releases/${{ needs.setup.outputs.short-sha }}/plugins/my-plugin
      npm: true
    secrets:
      SSH_PRIVATE_KEY: ${{secrets.SSH_PRIVATE_KEY}}

  deploy_theme:
    needs: [setup, prepare_releases_dir]
    uses: pie/.github/.github/workflows/deploy.yaml@main
    with:
      ssh-host: example.com
      destination-path: /home/piecode/site/public_html/releases/${{ needs.setup.outputs.short-sha }}/themes/my-theme
    secrets:
      SSH_PRIVATE_KEY: ${{secrets.SSH_PRIVATE_KEY}}

  deploy_migrations:
    needs: [setup, prepare_releases_dir]
    uses: pie/.github/.github/workflows/deploy.yaml@main
    with:
      ssh-host: example.com
      source-path: migrations/
      destination-path: /home/piecode/site/public_html/releases/${{ needs.setup.outputs.short-sha }}/migrations
    secrets:
      SSH_PRIVATE_KEY: ${{secrets.SSH_PRIVATE_KEY}}

  atomic_deploy:
    needs: [deploy_plugin, deploy_theme, deploy_migrations]
    uses: pie/.github/.github/workflows/atomic-deploy.yaml@main
    with:
      ssh-host: example.com
      wp-root: /home/piecode/site/public_html
      site-url: https://example.com
      components: |
        plugins:my-plugin
        themes:my-theme
    secrets:
      SSH_PRIVATE_KEY: ${{secrets.SSH_PRIVATE_KEY}}
```

**Rollback:**

If no migrations ran, resync each component from the prior release back to the live directory:

```bash
WP_ROOT=/home/piecode/site/public_html
RELEASES=/home/piecode/site/public_html/releases
PRIOR=$(ls -dt "$RELEASES"/*/  | sed -n '2p')

rsync -a --delete "${PRIOR}plugins/my-plugin/" "$WP_ROOT/wp-content/plugins/my-plugin/"
rsync -a --delete "${PRIOR}themes/my-theme/"  "$WP_ROOT/wp-content/themes/my-theme/"

wp cache flush --path="$WP_ROOT"
```

If migrations ran, rolling back the code alone leaves it running against the migrated schema, which may or may not be compatible. Two options, in order of preference:

1. **Run the [Rollback Migrations](#rollback-migrations) workflow**, if the migrations that ran define a `-- +migrate Down` section — see **SQL Migrations** below. It only reverses schema shape, not data a migration deleted or transformed.
2. **Restore from your own pre-deploy backup** — required for anything the rollback can't undo (a migration with no Down section, or one that changed data). See **Migrations run against live tables** above — this workflow doesn't take a backup for you.

If the workflow run's log shows the site is still in maintenance mode, the deploy failed after migrations had already started. Before deactivating maintenance mode, verify which migrations were recorded as applied and that component directories are in a consistent state — the log output includes the exact commands to run.

**Cleaning up after a manual recovery:** the `releases/{sha}/` directory for a failed deploy (its component copies, `swap.sh`, `migrate.sh`, `queries/`) is only pruned by a *later successful* deploy's own pruning step (Step 5) — a run that stops for manual recovery never reaches it. In practice this self-heals within a deploy or two once you're back to shipping normally, since pruning keeps only the current release plus one prior regardless of which ones succeeded. If you're not deploying again soon and want it gone immediately, it's safe to `rm -rf releases/{sha}/` yourself.

---

### Rollback Migrations

Reverts the most recently applied batch of database migrations, directly against the live tables. Triggered manually from the Actions tab (`workflow_dispatch`) — no SSH access to the deploy user is needed, since it reuses the same `SSH_PRIVATE_KEY` secret the deploy pipeline already has.

**How it works:**

Checks out the repo, connects over SSH (same as Atomic Deploy), uploads a fresh copy of `rollback.sh` plus the local `migrations/queries/` directory to a temporary directory on the server, runs it, then deletes that temporary directory regardless of outcome — nothing is left behind on the server.

`rollback.sh` derives the same `table_prefix` and migrations tracking table `swap.sh` would have used (from `wp-root` and the repository name — no need to look either up yourself), finds the most recently applied batch (the migrations from one specific deploy, identified by its short SHA), and reverts them **in reverse order**:

- A migration with a `-- +migrate Down` section: its Down SQL runs, then its tracking row is removed — only once the Down SQL actually succeeds, so a failure partway through a batch leaves an accurate record of what's still applied, and re-running the workflow picks up from there.
- A migration with no Down section: left as-is, logged clearly, not treated as an error — this is deliberate so a mixed batch (some migrations revertible, some not) doesn't fail outright partway through.

Down only reverses schema shape, not data a migration deleted or transformed — restore from your own backup for that (see **Migrations run against live tables** under Atomic Deploy).

If the batch fails partway through (one migration's Down section or tracking-row update fails after an earlier one in the same batch already succeeded), maintenance mode is deliberately left on rather than cleared automatically — the schema may be in a mix of reverted and un-reverted state, and bringing the site back online then would serve traffic against that inconsistency. The log names the exact query to check which migrations in the batch are still applied before deactivating it manually.

**Inputs:**

- `ssh-host`: SSH host. Required.
- `wp-root`: Absolute path to the WordPress root on the server. Required. Must start with `/`.
- `ssh-port`: SSH port. Optional, default is `22`.
- `ssh-user`: SSH user. Optional, default is `piecode`.
- `releases-dir`: Absolute path to a writable directory used only to stage this run's temporary working directory. Optional, defaults to a `releases` subdirectory inside `wp-root`.
- `migrations-path`: Local path (relative to the checked-out repo) containing the `migrations` directory. Optional, default is `migrations`.

**Secrets:**

- `SSH_PRIVATE_KEY`: SSH private key. Required — the same one used for Atomic Deploy.

**Example:**

```yaml
name: Rollback Migrations
on:
  workflow_dispatch:
jobs:
  rollback_migrations:
    uses: pie/.github/.github/workflows/rollback-migrations.yaml@main
    with:
      ssh-host: example.com
      wp-root: /home/piecode/site/public_html
    secrets:
      SSH_PRIVATE_KEY: ${{secrets.SSH_PRIVATE_KEY}}
```

---

### Deploy via Rsync

Deploys to a remote server using rsync, supporting both SSH key and password-based authentication.

**Setup:**

- Generate an SSH keypair for your repository if you haven't already — [GitHub docs](https://docs.github.com/en/authentication/connecting-to-github-with-ssh/generating-a-new-ssh-key-and-adding-it-to-the-ssh-agent#generating-a-new-ssh-key)
- Add `SSH_PRIVATE_KEY` to your repository secrets (used as the SSH password when `sshpass: true`).
- Add `SSH_PUBLIC_KEY` to your repository variables.
- Add an `.rsyncignore` file to the root of your repo listing files that should not be deployed.

**Inputs:**

- `ssh-host`: The SSH host. Required.
- `destination-path`: The path on the remote server to deploy to. Required.
- `source-path`: The path within the repo to deploy files from. Optional, default is `.`.
- `working-directory`: Working directory to run commands in. Optional, default is `.`.
- `ssh-port`: The SSH port. Optional, default is `22`.
- `ssh-user`: The SSH user. Optional, default is `piecode`.
- `sshpass`: Use password-based auth (sshpass) instead of an SSH key. Optional, default is `false`. When `true`, `SSH_PRIVATE_KEY` is used as the password.
- `rsync-args`: Additional arguments to pass to rsync. Optional, default is `--no-perms --no-times --no-owner --delete-after --delete-excluded`.
- `composer`: Run `composer install` before deploying. Optional, default is `false`.
- `composer-args`: Additional arguments to pass to composer. Optional, default is `--no-dev --no-interaction --no-progress --optimize-autoloader --prefer-dist`.
- `npm`: Run `npm install` and build before deploying. Optional, default is `false`.
- `node_version`: Node.js version for the build. Optional, default is `18`.
- `npm-run-command`: Command to run after `npm install`. Optional, default is `npm run build`.

**Secrets:**

- `SSH_PRIVATE_KEY`: SSH private key (or password when `sshpass: true`). Required.

**Example:**

```yaml
name: Deploy to WP Engine
on:
  workflow_dispatch:
jobs:
  deploy:
    uses: pie/.github/.github/workflows/deploy.yaml@main
    with:
      ssh-host: some_site.ssh.wpengine.net
      ssh-user: some_site
      destination-path: /home/wpe-user/sites/anysite/wp-content/plugins/some-plugin
    secrets:
      SSH_PRIVATE_KEY: ${{secrets.SSH_PRIVATE_KEY}}
```

---

### Deploy via FTP

Deploys to a remote server over FTP with optional Composer and npm build steps.

**Inputs:**

- `ftp-host`: The FTP server host. Required.
- `ftp-username`: The FTP username. Required.
- `destination-path`: The destination path on the remote server. Required.
- `ftp-port`: The FTP port. Optional, default is `21`.
- `ftp-exclude`: Glob patterns of files to exclude. Optional, default excludes `.git*` and `node_modules`.
- `composer`: Run `composer install` before deploying. Optional, default is `false`.
- `npm`: Run `npm install` and build before deploying. Optional, default is `false`.
- `node_version`: Node.js version for the build. Optional, default is `18`.

**Secrets:**

- `FTP_PASSWORD`: FTP password. Required.

**Example:**

```yaml
name: Deploy via FTP
on:
  workflow_dispatch:
jobs:
  deploy:
    uses: pie/.github/.github/workflows/deploy-via-ftp.yaml@main
    with:
      ftp-host: ftp.example.com
      ftp-username: myuser
      destination-path: /public_html/my-plugin
    secrets:
      FTP_PASSWORD: ${{secrets.FTP_PASSWORD}}
```

---

### Synchronise Environments

Logs into a remote server over SSH and runs a script to copy one environment into another.

**Inputs:**

- `ssh-host`: The SSH host. Required.
- `synchronisation-script`: Remote path to the synchronisation script. Required.
- `ssh-port`: The SSH port. Optional, default is `22`.
- `ssh-user`: The SSH user. Optional, default is `piecode`.

**Secrets:**

- `SSH_PRIVATE_KEY`: SSH private key. Required.

**Example:**

```yaml
name: Synchronise Development Server
on: workflow_dispatch
jobs:
  run-synchronisation-workflow:
    uses: pie/.github/.github/workflows/synchronise.yaml@main
    with:
      ssh-host: 100.12.34.56
      synchronisation-script: ~/sync_live_to_dev.sh
    secrets:
      SSH_PRIVATE_KEY: ${{secrets.SSH_PRIVATE_KEY}}
```

---

### Create Release

Checks whether a release is required based on PR labels, bumps version numbers across key files, packages a zip artifact, and publishes a GitHub release.

**Trigger:** Label a pull request with `release:major`, `release:minor`, or `release:patch` before merging to `main`.

**What it does:**

1. Uses [release-on-push-action](https://github.com/rymndhng/release-on-push-action) in dry-run mode to determine whether a release is needed and what the next version should be.
2. If a release is required, checks out `main` and bumps the version string via `sed` in:
   - `package.json`
   - `update.json` (version field and download URL)
   - `{repository-name}.php` (Version header comment)
   - `changelog.md` (Unreleased section)
3. Commits and pushes the version bump.
4. Creates a zip of the repository root, respecting `.zipignore` if present.
5. Publishes a GitHub release with the version tag, auto-generated release notes, and the zip as a downloadable artifact.

**Example:**

```yaml
name: Release
on:
  push:
    branches:
      - main
jobs:
  release:
    uses: pie/.github/.github/workflows/release.yaml@main
```

---

## Actions

These composite actions are used internally by the workflows above but can also be referenced directly.

| Action | Description |
|---|---|
| `add-ssh-config` | Adds an SSH private key to the runner and creates a `server` host alias for key-based auth |
| `add-ssh-pass` | Installs sshpass and configures password-based SSH authentication |
| `deploy-via-rsync` | Runs an optional Composer/npm build then deploys files via rsync |
| `deploy-via-ftp` | Runs an optional Composer/npm build then deploys files via FTP |
| `prepare-releases-dir` | Creates and protects the releases directory before anything is uploaded into it |
| `rollback-migrations` | Reverts the most recently applied batch of database migrations over SSH |
| `swap-and-migrate` | Runs DB migrations and atomic component swap in a single SSH session |
| `synchronise-remote` | Executes a synchronisation script on a remote server over SSH |
| `verify-branch-is-correct` | Fails the job if the current branch does not match the expected branch (default: `production`) |
| `verify-branch-is-up-to-date` | Fails the job if the current branch is behind the target branch (default: `main`) |

---

## Templates

### SQL Migrations

Copy `templates/migrations/` into your project to get the `migrations/queries/` directory structure. No scripts are needed per-project — `swap.sh` and `migrate.sh` are bundled with the action and uploaded to the server automatically on each deploy; `rollback.sh` is bundled separately and only uploaded when the **Rollback Migrations** workflow runs.

The calling workflow should rsync `migrations/` to `releases/${{ needs.setup.outputs.short-sha }}/migrations` (see the Atomic Deploy example below) and pass the component list to the `atomic-deploy` workflow. Using `github.sha` (the full 40-character SHA) here instead would put `queries/` under a directory `swap.sh` never looks in — it always resolves the release directory from the short SHA — so migrations would silently never be found and the deploy would proceed as if none were pending:

```yaml
components: |
  plugins:my-plugin
  themes:my-theme
```

**Naming convention:** `{four-digit-number}_{description}.sql` — the number controls execution order. Gaps are fine. Never renumber or delete a migration once committed.

```
migrations/queries/
├── 0001_add_source_column.sql
└── 0002_backfill_source_column.sql
```

**Table prefix placeholder:** Use `__WP_PREFIX__` in migration files wherever a table prefix is needed. It is replaced with the correct prefix at deploy time. Never hardcode `wp_` or any other prefix — a global string replacement would risk corrupting string literals or comments that happen to contain the prefix.

```sql
-- 0001_add_source_column.sql
ALTER TABLE __WP_PREFIX__posts ADD COLUMN source VARCHAR(255) DEFAULT NULL;
```

**Rollback (optional):** split a file into `-- +migrate Up` and `-- +migrate Down` sections to make it revertible via the **Rollback Migrations** workflow (see above). A file with no markers — like the plain example above — is treated as Up-only; rollback leaves its change in place and logs that it has nothing to revert, rather than guessing or failing. `Down` should reverse the schema shape `Up` created — it can't recover data `Up` deleted or transformed unless you explicitly write logic to preserve it first.

```sql
-- 0001_add_source_column.sql

-- +migrate Up
ALTER TABLE __WP_PREFIX__posts ADD COLUMN source VARCHAR(255) DEFAULT NULL;

-- +migrate Down
ALTER TABLE __WP_PREFIX__posts DROP COLUMN source;
```

Migrations are tracked per-project in a table named `{repo_name}_migrations` (derived automatically), including which deploy (`batch`) applied each one — the **Rollback Migrations** workflow uses this to undo one deploy's migrations at a time, most-recently-applied first. The table is created on first run if it does not exist.
