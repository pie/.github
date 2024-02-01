# Github Workflows for PIE.co.de

This repository contains some re-usable workflows and actions for managing repository deployment

## Workflows

### Deploy via Rsync

This workflow deploys to a remote server using rsync. 

**Usage Notes:**

- Generate a new Keypair for your repository if you haven't already - https://docs.github.com/en/authentication/connecting-to-github-with-ssh/generating-a-new-ssh-key-and-adding-it-to-the-ssh-agent#generating-a-new-ssh-key
- Add SSH_PRIVATE_KEY to your repository secrets.
- Add SSH_PUBLIC_KEY to your repository variables.
- Add an `.rsyncignore` file to the root of your repo listing files which should not be deployed. 

**Inputs:**

- `ssh-host`: The SSH host. Required.
- `destination-path`: The path on the remote server to deploy to. Required.
- `ssh-port`: The SSH port. Optional, default is 22.
- `ssh-user`: The SSH user. Optional, default is `piecode`.
- `rsync-args`: Additional arguments to pass to rsync. Optional, default is `--no-perms --no-times --no-owner --delete-after`.
- `rsync-flags`: Flags to pass to the rsync command. Optional, default is `-aqP`.

**Example Workflow:**

```
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

### Synchronise Environments

**Usage Notes:**

This workflow can be run against any branch in order to log into the remote server and run a script to copy one environment into another. In the future we will run these scripts from within the workflow runner

**Inputs:**

- `ssh-host`: The SSH host. Required.
- `synchronisation-script`: Remote path to the Synchronisation script. Required.
- `ssh-port`: The SSH port. Optional, default is 22.
- `ssh-user`: The SSH user. Optional, default is `piecode`.

**Example Workflow:**

```
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
