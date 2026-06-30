# Github Workflows for PIE.co.de

This repository contains reusable workflows and composite actions for managing repository deployment.

## Workflows

### Atomic Deploy

Deploys components to a release directory keyed by the git commit SHA, then atomically swaps symlinks and runs any pending database migrations in a single maintenance window. Supports instant rollback by re-pointing symlinks to the prior release.

**How it works:**

Rsync jobs deploy each component to `~/site/releases/{sha}/` on the server. Once all jobs complete, the `atomic_deploy` job SSH's in and runs the project's `migrations/swap.sh`, which:

1. Verifies WP-CLI can reach the database
2. Checks for pending SQL migrations
3. If any: enables maintenance mode → exports a database backup → copies live tables to a new `wp_{short-sha}_` prefix → runs migrations against the copy → switches `wp-config.php` to the new prefix → drops old tables
4. Re-points symlinks to the new release (bootstrapping to the release structure automatically on first run)
5. Prunes releases older than 1 prior

Failures are handled based on how far the deploy got:

- **Before `wp-config.php` or symlinks change** — maintenance mode is deactivated automatically and the site recovers on the previous version. A notification is sent with subject *Deploy failed, site recovered*.
- **After either live change begins** — maintenance mode stays on to prevent the site returning in a broken state. A notification is sent with subject *URGENT: Site in maintenance mode*, including instructions for manual verification.

**Server directory structure:**

```
~/site/
├── releases/
│   ├── {current-sha}/          ← new deploy lands here via rsync
│   │   ├── my-plugin/
│   │   ├── my-theme/
│   │   └── migrations/
│   └── {previous-sha}/         ← kept for rollback
├── db-backups/                  ← pre-migration exports (when migrations run)
└── public_html/                 ← WordPress root
    └── wp-content/
        ├── plugins/
        │   └── my-plugin        → symlink → ../../releases/{sha}/my-plugin/
        └── themes/
            └── my-theme         → symlink → ../../releases/{sha}/my-theme/
```

**Inputs:**

- `ssh-host`: SSH host. Required.
- `swap-script`: Absolute path to `migrations/swap.sh` on the server. Required.
- `wp-root`: Absolute path to the WordPress root on the server. Required.
- `ssh-port`: SSH port. Optional, default is `22`.
- `ssh-user`: SSH user. Optional, default is `piecode`.

**Secrets:**

- `SSH_PRIVATE_KEY`: SSH private key. Required.
- `SMTP_SERVER`: SMTP server for failure notifications. Optional — set at organisation level.
- `SMTP_USERNAME`: SMTP username. Optional — set at organisation level.
- `SMTP_PASSWORD`: SMTP password. Optional — set at organisation level.
- `NOTIFY_EMAIL`: Override the notification recipient. Optional — defaults to `#uptime_alerts` Slack channel.

**Example:**

```yaml
name: Deploy to Production
on:
  push:
    branches:
      - production
jobs:
  deploy_plugin:
    uses: pie/.github/.github/workflows/deploy.yaml@main
    with:
      ssh-host: example.com
      destination-path: ~/site/releases/${{ github.sha }}/my-plugin
      npm: true
    secrets:
      SSH_PRIVATE_KEY: ${{secrets.SSH_PRIVATE_KEY}}

  deploy_theme:
    uses: pie/.github/.github/workflows/deploy.yaml@main
    with:
      ssh-host: example.com
      destination-path: ~/site/releases/${{ github.sha }}/my-theme
    secrets:
      SSH_PRIVATE_KEY: ${{secrets.SSH_PRIVATE_KEY}}

  deploy_migrations:
    uses: pie/.github/.github/workflows/deploy.yaml@main
    with:
      ssh-host: example.com
      destination-path: ~/site/releases/${{ github.sha }}/migrations
    secrets:
      SSH_PRIVATE_KEY: ${{secrets.SSH_PRIVATE_KEY}}

  atomic_deploy:
    needs: [deploy_plugin, deploy_theme, deploy_migrations]
    uses: pie/.github/.github/workflows/atomic-deploy.yaml@main
    with:
      ssh-host: example.com
      swap-script: ~/site/releases/${{ github.sha }}/migrations/swap.sh
      wp-root: ~/site/public_html
    secrets:
      SSH_PRIVATE_KEY: ${{secrets.SSH_PRIVATE_KEY}}
      SMTP_SERVER: ${{secrets.SMTP_SERVER}}
      SMTP_USERNAME: ${{secrets.SMTP_USERNAME}}
      SMTP_PASSWORD: ${{secrets.SMTP_PASSWORD}}
```

**Rollback:**

Re-point each symlink to the prior release on the server, then flush the cache:

```bash
WP_ROOT=~/site/public_html
PRIOR=$(ls -dt ~/site/releases/*/ | sed -n '2p')

ln -sfn ${PRIOR}my-plugin $WP_ROOT/wp-content/plugins/my-plugin
ln -sfn ${PRIOR}my-theme  $WP_ROOT/wp-content/themes/my-theme

wp cache flush --path="$WP_ROOT"
```

If the failure notification subject says *URGENT: Site in maintenance mode*, the deploy failed after live changes began. Before deactivating maintenance mode, verify the table prefix and symlinks are in a consistent state — the notification email includes the exact commands to run.

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
| `swap-and-migrate` | Runs DB migrations and symlink swap atomically in a single SSH session |
| `synchronise-remote` | Executes a synchronisation script on a remote server over SSH |
| `verify-branch-is-correct` | Fails the job if the current branch does not match the expected branch (default: `production`) |
| `verify-branch-is-up-to-date` | Fails the job if the current branch is behind the target branch (default: `main`) |

---

## Templates

### SQL Migrations

Copy `templates/migrations/` into your project's `migrations/` directory and make the scripts executable (`chmod +x migrations/*.sh`).

| File | What to do |
|---|---|
| `swap.sh` | Edit the `COMPONENTS` array at the top — list each plugin/theme as `"type:directory-name"` |
| `migrate.sh` | Copy as-is, no changes needed |
| `queries/.gitkeep` | Add `.sql` files here; the `.gitkeep` can be removed once real migrations exist |

**Naming convention:** `{four-digit-number}_{description}.sql` — the number controls execution order. Gaps are fine. Never renumber or delete a migration once committed.

```
migrations/queries/
├── 0001_add_source_column.sql
└── 0002_backfill_source_column.sql
```

Migrations are tracked per-project in a table named `{repo_name}_migrations` (derived automatically). The table is created on first run if it does not exist.
