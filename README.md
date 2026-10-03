# Homelab / VPS disaster-recovery repo

Goal: rebuild the OpenMediaVault homelab box and the Hostinger VPS (Ubuntu 24.04) from this repo.

## Step 1: inventory each machine
On each host (as root, read-only):

    git clone <this repo> && cd git_test
    sudo ./scripts/inventory.sh
    tar czf inventory-$(hostname -s).tar.gz inventory-*/

Review the output (secrets are redacted best-effort), then share it with Claude
or move it to `hosts/<hostname>/` and commit.

## Planned layout
    hosts/<name>/   reviewed inventory + configs per machine
    docker/         compose stacks (secrets via .env.example templates)
    docs/           architecture, restore runbook
    secrets/        *.example only; real secrets in a password manager or sops/age
