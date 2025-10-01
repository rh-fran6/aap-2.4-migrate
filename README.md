# AAP PVC Migrator

Automates backup, transfer, and restore of an Ansible Automation Platform (AWX/Automation Controller) instance between OpenShift clusters/namespaces using PersistentVolumeClaims (PVCs).

The script orchestrates:
- Creation of an `AutomationControllerBackup` on the source cluster
- Copy of the produced backup directory from the source PVC to a destination PVC (preserving the folder name)
- Creation of an `AutomationControllerRestore` on the destination cluster
- Cleanup of transfer pods and PVCs

Warning: The final cleanup is destructive (deletes both the source backup PVC and the destination recovery PVC). Read the "Destructive Cleanup" section before using.


## Repository layout

- `pvc-migration.sh` — the main migration script
- `pvcs.csv` — example/placeholder PVC mapping CSV
- `creds.csv` — example/placeholder cluster credentials CSV


## Requirements

- OpenShift CLI: `oc`
- Access to both clusters with permissions to:
  - Login (`oc login`)
  - Create/read `AutomationControllerBackup` and `AutomationControllerRestore` CRs
  - Create/Delete Pods and PVCs in the specified namespaces
  - Read StorageClass resources
- AAP Operator and CRDs installed:
  - `automationcontroller.ansible.com/v1beta1` for Backup/Restore on their respective clusters
- Optional: `rsync` (only if you choose the `rsync` copy method; otherwise script defaults to `tar`)


## How it works (high level)

1. Validates logins to source and destination clusters (prompts if not provided via CSV)
2. Creates an `AutomationControllerBackup` on the source cluster and waits for the CR status `Successful=True`
3. Determines backup directory path and source backup PVC
4. Ensures a compatible destination PVC exists (size, accessModes, volumeMode, StorageClass)
5. Launches ephemeral transfer pods on both clusters mounting their PVCs
6. Copies the entire backup directory from source to destination (method: `tar` or `rsync`)
7. Deletes the destination transfer pod, then creates an `AutomationControllerRestore` in the destination cluster and waits until `Successful=True` and `restoreComplete=true`
8. Performs final cleanup: deletes transfer pods and both PVCs (destructive)


## CSV inputs

The script reads two optional CSV files:

### PVC map CSV

Pass via `--pvc path/to/pvcs.csv`. The script reads only the first non-empty, non-comment data row.

Accepted headers (case/space-insensitive; spaces ignored):
- `source_namespace` (required)
- `dest_namespace` (required)
- `source_pvc` (optional)
- `dest_pvc` (optional)
- `source_path` (optional; default `/backups`)
- `dest_path` (optional; default `/backups`)
- `method` (optional: `tar` or `rsync`; default `tar`)
- `controller_name` (optional; will prompt if missing; default prompt value `controller`)

Example `pvcs.csv`:

```csv
source_namespace,source_pvc,dest_namespace,dest_pvc,source_path,dest_path,method,controller_name
source-aap,controller-backup-claim,dest-aap,controller-recovery-claim,/backups,/backups,tar,controller
```

Notes:
- `source_pvc` is not strictly required; the script reads the backup claim from the Backup CR status and falls back to `${controller_name}-backup-claim`.
- If `dest_pvc` is omitted, it defaults to `${controller_name}-recovery-claim`.

### Cluster credentials CSV

Pass via `--cred path/to/creds.csv`. If omitted, the script auto-searches `cluster-creds.csv` next to your PVC CSV file.

Headers (case/space-insensitive; spaces ignored):
- `label` — must be `source` or `destination` (or `dest`)
- `api_url`
- `token`
- `user`
- `pass`
- `insecure` — `true|false|y|n|1|0`

Example `creds.csv`:

```csv
label,api_url,token,user,pass,insecure
source,https://api.source.example:6443,sha256~xxxx,, ,false
destination,https://api.dest.example:6443,sha256~yyyy,, ,false
```

Notes:
- You may supply either `token` or `user`+`pass`. If both are missing, the script will prompt interactively.
- `insecure` toggles `--insecure-skip-tls-verify` for `oc login`.


## Usage

```bash
./pvc-migration.sh --pvc pvcs.csv [--cred creds.csv]
# or
./pvc-migration.sh pvcs.csv
```

During execution the script may prompt for:
- Cluster login details (if not fully provided via `--cred`)
- `Controller (deployment) name` if not in the PVC CSV (default prompt value: `controller`)
- `Ephemeral pod image` to use for transfer pods (default: `registry.redhat.io/ubi9:9.5`)


## Behavior details

- Backup CR name: `controller-backup` in source namespace
- Restore CR name: `aap-controller-restore` in destination namespace
- Backup path detection: reads `.status.backupDirectory` and `.status.backupClaim` from source `AutomationControllerBackup` CR
  - Defaults to `/backups` and `${controller_name}-backup-claim` if status fields are missing
- Destination PVC creation matches source backup PVC:
  - Size (`.spec.resources.requests.storage`) — defaults to `20Gi` if unreadable
  - AccessModes and VolumeMode
  - StorageClass: reuses source SC if present on destination; otherwise tries destination default SC; otherwise cluster default behavior
- Transfer pods mount at `/backups` inside the container
- Copy methods:
  - `tar` (default): streams tar from source pod to local, then `oc cp` to destination, then untars
  - `rsync`: uses `oc rsync` source→local→destination (requires `rsync` binary)
- Size verification: compares source vs destination `du -s` with tolerance; logs a warning if delta exceeds tolerance
- SELinux relabel: runs `restorecon -Rvv` on destination path if available


## Destructive cleanup

At the end of a successful run, the script removes:
- Source transfer pod
- Destination transfer pod
- Source backup PVC (`BACKUP_CLAIM`)
- Destination recovery PVC (`D_PVC`)

If you wish to retain any of these, comment out or remove the following section in `pvc-migration.sh`:

```bash
# ── Final cleanup: pods + PVCs (DESTRUCTIVE)
# ...
oc -n "$S_NS" delete pvc "$BACKUP_CLAIM" --ignore-not-found || true
oc -n "$D_NS" delete pvc "$D_PVC" --ignore-not-found || true
```

Alternatively, fork the repo and add a flag (e.g., `--keep-pvcs`) to skip deletion.


## Logging and artifacts

- A timestamped directory is created per run: `pvc-migrate-logs-YYYYMMDD-HHMMSS/`
- Contains:
  - `run-<timestamp>.log` — master log with all major steps and status updates
  - Temporary tar payload or rsync staging folder
  - Per-cluster kubeconfig files:
    - `kubeconfig-source-<timestamp>`
    - `kubeconfig-destination-<timestamp>`


## Security considerations

- Credentials provided via `--cred` are only used to run `oc login` to each cluster with a temporary per-run kubeconfig.
- Do not commit kubeconfig files or logs with sensitive information.
- Prefer service accounts or short-lived tokens where possible.


## Troubleshooting

- Backup CR never becomes Successful
  - Check AAP operator/controller logs in source cluster
  - Verify the controller deployment name matches `controller_name`
- Destination StorageClass mismatch
  - If source SC doesn’t exist on destination, script picks the default SC. Validate that the resulting PVC is mountable by the restore job
- Copy is slow or fails
  - Try `method=rsync` if available, or ensure network throughput is sufficient
  - Verify the ephemeral image has required tools; the default UBI image includes `bash`/`tar`
- Restore never completes
  - Inspect the `AutomationControllerRestore` CR and AAP operator logs on destination
  - Ensure the backup directory path on the destination PVC is `/backups/<dir-name>`


## FAQ

- Can I use this within the same cluster/namespace?
  - Yes, but ensure source/destination namespaces and PVCs do not conflict, and be mindful of the destructive cleanup section.

- Why are PVCs deleted at the end?
  - To avoid leaving behind large backup volumes. Modify the script if you want to keep them.

- Can I change the transfer pod image?
  - Yes, the script prompts for the image; default is `registry.redhat.io/ubi9:9.5`.


## Development notes

Key functions in `pvc-migration.sh`:
- `load_pvc_csv()` — reads the PVC map CSV (flexible headers, uses first data row)
- `load_creds_csv()` — reads cluster credentials (labels `source` and `destination`)
- `oc_login_try()` / `oc_login_prompt()` — logins/whoami verification into per-run kubeconfigs
- `make_pod_s()` / `make_pod_d()` — creates transfer pods
- `copy_backup_dir_tar()` / `copy_backup_dir_rsync()` — directory copy strategies
- `default_sc_d()` — attempts to determine destination default StorageClass
- `create_dest_pvc_if_missing()` — creates destination PVC that mirrors source backup PVC characteristics


## Example end-to-end

1. Prepare `pvcs.csv` and optionally `creds.csv`
2. Run the script:

```bash
./pvc-migration.sh --pvc pvcs.csv --cred creds.csv
```

3. Follow prompts if any (login, controller name, transfer image)
4. Wait for backup, copy, restore, and cleanup to complete


## License

Apache-2.0 (or your preferred license).
