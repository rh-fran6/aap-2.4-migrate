# Manual AAP PVC Migration Guide

This guide walks you through migrating an Ansible Automation Platform (AWX/Automation Controller) instance between OpenShift clusters or namespaces manually, step by step. It mirrors the behavior of `pvc-migration.sh` for users who prefer explicit control.

Use these commands on Ubuntu, macOS, or RHEL terminals.


## Prerequisites

- `oc` CLI installed and reachable to both clusters
- Permissions on both clusters to:
  - Login (`oc login`)
  - Create/read `AutomationControllerBackup` and `AutomationControllerRestore` CRs
  - Create/delete Pods and PVCs in target namespaces
  - Read StorageClass resources
- AAP Operator and CRDs installed on the relevant clusters
- Network path and permissions to use `oc cp` or `oc rsync`


## Variables and defaults

```bash
# Working directory and timestamp
WORKDIR="$(pwd)"
TS="$(date +%Y%m%d-%H%M%S)"

# Separate kubeconfigs (recommended to avoid context mixing)
SRC_KC="$WORKDIR/kubeconfig-source-$TS"
DST_KC="$WORKDIR/kubeconfig-destination-$TS"

# Namespaces and controller deployment name
S_NS="<source-namespace>"          # e.g., aap
D_NS="<dest-namespace>"            # e.g., aap
CONTROLLER_NAME="<controller>"     # e.g., controller

# Script-aligned defaults
DEF_IMAGE="registry.redhat.io/ubi9:9.5"
DEF_S_PATH="/backups"
DEF_D_PATH="/backups"

# Backup/Restore CR names
BACKUP_NAME="controller-backup"
RESTORE_NAME="aap-controller-restore"
```

Replace the values in angle brackets with your actual environment values.


## 1) Login to both clusters

Use token (recommended) or username/password.

```bash
# Source cluster login
KUBECONFIG="$SRC_KC" oc login https://api.<source-cluster>:6443 \
  --token="<source-token>" --insecure-skip-tls-verify=false
# or
# KUBECONFIG="$SRC_KC" oc login https://api.<source-cluster>:6443 \
#   -u "<user>" -p "<pass>" --insecure-skip-tls-verify=false

KUBECONFIG="$SRC_KC" oc whoami
KUBECONFIG="$SRC_KC" oc api-resources >/dev/null

# Destination cluster login
KUBECONFIG="$DST_KC" oc login https://api.<dest-cluster>:6443 \
  --token="<dest-token>" --insecure-skip-tls-verify=false
# or
# KUBECONFIG="$DST_KC" oc login https://api.<dest-cluster>:6443 \
#   -u "<user>" -p "<pass>" --insecure-skip-tls-verify=false

KUBECONFIG="$DST_KC" oc whoami
KUBECONFIG="$DST_KC" oc api-resources >/dev/null
```

Verify namespaces:
```bash
KUBECONFIG="$SRC_KC" oc get ns "$S_NS"
KUBECONFIG="$DST_KC" oc get ns "$D_NS"
```


## 2) Create the AutomationControllerBackup on source

```bash
KUBECONFIG="$SRC_KC" oc -n "$S_NS" delete automationcontrollerbackup "$BACKUP_NAME" \
  --ignore-not-found --wait=true

cat <<YAML | KUBECONFIG="$SRC_KC" oc -n "$S_NS" apply -f -
apiVersion: automationcontroller.ansible.com/v1beta1
kind: AutomationControllerBackup
metadata:
  name: ${BACKUP_NAME}
  namespace: ${S_NS}
spec:
  no_log: true
  image_pull_policy: IfNotPresent
  set_self_labels: true
  deployment_name: ${CONTROLLER_NAME}
YAML
```


## 3) Wait for the backup to be Successful

Poll until `Successful=True` and reason `Successful`, then read backup directory and claim.

```bash
while true; do
  reason="$(KUBECONFIG="$SRC_KC" oc -n "$S_NS" get automationcontrollerbackup "$BACKUP_NAME" \
    -o jsonpath='{.status.conditions[?(@.type=="Successful")].reason}' 2>/dev/null || true)"
  status="$(KUBECONFIG="$SRC_KC" oc -n "$S_NS" get automationcontrollerbackup "$BACKUP_NAME" \
    -o jsonpath='{.status.conditions[?(@.type=="Successful")].status}' 2>/dev/null || true)"
  echo "Backup status: status='${status:-}', reason='${reason:-}'"
  [ "$status" = "True" ] && [ "$reason" = "Successful" ] && break
  sleep 10
done

BACKUP_DIR="$(KUBECONFIG="$SRC_KC" oc -n "$S_NS" get automationcontrollerbackup "$BACKUP_NAME" -o jsonpath='{.status.backupDirectory}' 2>/dev/null || true)"
BACKUP_CLAIM="$(KUBECONFIG="$SRC_KC" oc -n "$S_NS" get automationcontrollerbackup "$BACKUP_NAME" -o jsonpath='{.status.backupClaim}' 2>/dev/null || true)"
[ -n "$BACKUP_DIR" ] || BACKUP_DIR="$DEF_S_PATH"
[ -n "$BACKUP_CLAIM" ] || BACKUP_CLAIM="${CONTROLLER_NAME}-backup-claim"

BACKUP_PARENT="$(dirname "$BACKUP_DIR")"
BACKUP_DIR_NAME="$(basename "$BACKUP_DIR")"

echo "Using source backup PVC='$BACKUP_CLAIM', dir='$BACKUP_DIR' (name='$BACKUP_DIR_NAME')"
```


## 4) Ensure destination PVC exists and matches source spec

```bash
# Read spec from source backup PVC
SRC_SIZE="$(KUBECONFIG="$SRC_KC" oc -n "$S_NS" get pvc "$BACKUP_CLAIM" -o jsonpath='{.spec.resources.requests.storage}')"
SRC_MODES="$(KUBECONFIG="$SRC_KC" oc -n "$S_NS" get pvc "$BACKUP_CLAIM" -o jsonpath='{.spec.accessModes[*]}')"
SRC_VMODE="$(KUBECONFIG="$SRC_KC" oc -n "$S_NS" get pvc "$BACKUP_CLAIM" -o jsonpath='{.spec.volumeMode}')"
SRC_SC="$(KUBECONFIG="$SRC_KC" oc -n "$S_NS" get pvc "$BACKUP_CLAIM" -o jsonpath='{.spec.storageClassName}')"

[ -n "$SRC_SIZE" ] || SRC_SIZE="20Gi"
AM_CSV="$(echo "$SRC_MODES" | sed 's/ /, /g')"; [ -n "$AM_CSV" ] || AM_CSV="ReadWriteOnce"

# Choose destination PVC name (default mirrors the script)
D_PVC="${D_PVC:-${CONTROLLER_NAME}-recovery-claim}"

# Select destination StorageClass
DEST_SC=""
if [ -n "$SRC_SC" ] && KUBECONFIG="$DST_KC" oc get sc "$SRC_SC" >/dev/null 2>&1; then
  DEST_SC="$SRC_SC"
else
  DEST_SC="$(KUBECONFIG="$DST_KC" oc get sc -o json 2>/dev/null | \
    awk -v RS= '{if ($0 ~ /"is-default-class":"true"/) {match($0,/"name":"([^"]+)"/,m); if(m[1] != ""){print m[1]; exit}}}')"
fi

# Create PVC on destination if missing
if ! KUBECONFIG="$DST_KC" oc -n "$D_NS" get pvc "$D_PVC" >/dev/null 2>&1; then
  echo "Creating destination PVC '$D_PVC' in '$D_NS'…"
  {
    cat <<YAML
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${D_PVC}
spec:
  accessModes: [${AM_CSV}]
  resources:
    requests:
      storage: ${SRC_SIZE}
  volumeMode: ${SRC_VMODE:-Filesystem}
YAML
    if [ -n "$DEST_SC" ]; then
      echo "  storageClassName: ${DEST_SC}"
    fi
  } | KUBECONFIG="$DST_KC" oc -n "$D_NS" apply -f -
else
  echo "Destination PVC '$D_PVC' already exists in '$D_NS'."
fi
```


## 5) Create transfer pods (source and destination)

```bash
SRC_POD="pvc-src-$TS"
DST_POD="pvc-dst-$TS"

# Source transfer pod
cat <<YAML | KUBECONFIG="$SRC_KC" oc -n "$S_NS" apply -f -
apiVersion: v1
kind: Pod
metadata: { name: ${SRC_POD}, labels: { app: pvc-migrator } }
spec:
  restartPolicy: Never
  containers:
  - name: migrator
    image: ${DEF_IMAGE}
    command: ["bash","-lc","sleep infinity"]
    volumeMounts: [{ name: vol, mountPath: /backups }]
  volumes:
  - name: vol
    persistentVolumeClaim: { claimName: ${BACKUP_CLAIM} }
YAML

# Destination transfer pod
cat <<YAML | KUBECONFIG="$DST_KC" oc -n "$D_NS" apply -f -
apiVersion: v1
kind: Pod
metadata: { name: ${DST_POD}, labels: { app: pvc-migrator } }
spec:
  restartPolicy: Never
  containers:
  - name: migrator
    image: ${DEF_IMAGE}
    command: ["bash","-lc","sleep infinity"]
    volumeMounts: [{ name: vol, mountPath: /backups }]
  volumes:
  - name: vol
    persistentVolumeClaim: { claimName: ${D_PVC} }
YAML

# Wait for readiness
KUBECONFIG="$SRC_KC" oc -n "$S_NS" wait --for=condition=Ready "pod/$SRC_POD" --timeout=300s
KUBECONFIG="$DST_KC" oc -n "$D_NS" wait --for=condition=Ready "pod/$DST_POD" --timeout=300s

# Ensure destination directory exists
KUBECONFIG="$DST_KC" oc -n "$D_NS" exec "$DST_POD" -- sh -lc "mkdir -p \"$DEF_D_PATH\""
```


## 6) Copy the backup directory from source to destination

### Method A: tar (default, no rsync needed)
```bash
# Create local tarball from source pod
KUBECONFIG="$SRC_KC" oc -n "$S_NS" exec "$SRC_POD" -- sh -lc \
  "cd \"$BACKUP_PARENT\" && tar cf - \"$BACKUP_DIR_NAME\"" > "$WORKDIR/payload-$TS.tar"

# Copy tar to destination pod and extract
KUBECONFIG="$DST_KC" oc -n "$D_NS" cp "$WORKDIR/payload-$TS.tar" "${DST_POD}:/tmp/payload.tar"
KUBECONFIG="$DST_KC" oc -n "$D_NS" exec "$DST_POD" -- sh -lc \
  "mkdir -p \"$DEF_D_PATH\" && tar xf /tmp/payload.tar -C \"$DEF_D_PATH\" && rm -f /tmp/payload.tar"

# Optional SELinux relabel
DST_DIR_PATH="${DEF_D_PATH}/${BACKUP_DIR_NAME}"
KUBECONFIG="$DST_KC" oc -n "$D_NS" exec "$DST_POD" -- sh -lc \
  "command -v restorecon >/dev/null 2>&1 && restorecon -Rvv \"$DST_DIR_PATH\" || true"
```

### Method B: rsync (if available)
```bash
TMP_COPY="$WORKDIR/tmp_copy-$TS"
mkdir -p "$TMP_COPY"

# Source -> local
KUBECONFIG="$SRC_KC" oc -n "$S_NS" rsync "${SRC_POD}:${BACKUP_PARENT}/${BACKUP_DIR_NAME}" "$TMP_COPY/"

# Local -> destination
KUBECONFIG="$DST_KC" oc -n "$D_NS" rsync "$TMP_COPY/${BACKUP_DIR_NAME}" "${DST_POD}:${DEF_D_PATH}/"

# Optional SELinux relabel
DST_DIR_PATH="${DEF_D_PATH}/${BACKUP_DIR_NAME}"
KUBECONFIG="$DST_KC" oc -n "$D_NS" exec "$DST_POD" -- sh -lc \
  "command -v restorecon >/dev/null 2>&1 && restorecon -Rvv \"$DST_DIR_PATH\" || true"

rm -rf "$TMP_COPY"
```

Optional: size sanity-check
```bash
SRC_H="$(KUBECONFIG="$SRC_KC" oc -n "$S_NS" exec "$SRC_POD" -- sh -lc "du -sh \"$BACKUP_DIR\" 2>/dev/null | awk '{print \$1}'" || echo 0)"
SRC_B="$(KUBECONFIG="$SRC_KC" oc -n "$S_NS" exec "$SRC_POD" -- sh -lc "du -s \"$BACKUP_DIR\" 2>/dev/null | awk '{print \$1}'" || echo 0)"
echo "Source size: $SRC_H ($SRC_B blocks)"

DST_H="$(KUBECONFIG="$DST_KC" oc -n "$D_NS" exec "$DST_POD" -- sh -lc "du -sh \"$DST_DIR_PATH\" 2>/dev/null | awk '{print \$1}'" || echo 0)"
DST_B="$(KUBECONFIG="$DST_KC" oc -n "$D_NS" exec "$DST_POD" -- sh -lc "du -s \"$DST_DIR_PATH\" 2>/dev/null | awk '{print \$1}'" || echo 0)"
echo "Destination size: $DST_H ($DST_B blocks)"
```


## 7) Delete destination transfer pod before restore

```bash
KUBECONFIG="$DST_KC" oc -n "$D_NS" delete pod "$DST_POD" --ignore-not-found
```


## 8) Create the AutomationControllerRestore on destination

```bash
cat <<YAML | KUBECONFIG="$DST_KC" oc -n "$D_NS" apply -f -
apiVersion: automationcontroller.ansible.com/v1beta1
kind: AutomationControllerRestore
metadata:
  name: ${RESTORE_NAME}
  namespace: ${D_NS}
spec:
  backup_dir: /backups/${BACKUP_DIR_NAME}
  backup_pvc: ${D_PVC}
  backup_source: PVC
  deployment_name: ${CONTROLLER_NAME}
  force_drop_db: false
  image_pull_policy: IfNotPresent
  no_log: true
  set_self_labels: true
YAML
```


## 9) Wait for restore to complete

```bash
while true; do
  r_reason="$(KUBECONFIG="$DST_KC" oc -n "$D_NS" get automationcontrollerrestore "$RESTORE_NAME" \
    -o jsonpath='{.status.conditions[?(@.type=="Successful")].reason}' 2>/dev/null || true)"
  r_status="$(KUBECONFIG="$DST_KC" oc -n "$D_NS" get automationcontrollerrestore "$RESTORE_NAME" \
    -o jsonpath='{.status.conditions[?(@.type=="Successful")].status}' 2>/dev/null || true)"
  r_complete="$(KUBECONFIG="$DST_KC" oc -n "$D_NS" get automationcontrollerrestore "$RESTORE_NAME" \
    -o jsonpath='{.status.restoreComplete}' 2>/dev/null || true)"
  echo "Restore status: status='${r_status:-}', reason='${r_reason:-}', restoreComplete='${r_complete:-}'"
  [ "$r_status" = "True" ] && [ "$r_reason" = "Successful" ] && [ "$r_complete" = "true" ] && break
  sleep 10
done

echo "Restore completed successfully."
```


## 10) Cleanup (optional / destructive)

Run these only if you want to remove transfer pods and PVCs. Be sure you no longer need them.

```bash
# Source transfer pod
KUBECONFIG="$SRC_KC" oc -n "$S_NS" delete pod "$SRC_POD" --ignore-not-found

# Source backup PVC (DESTRUCTIVE)
KUBECONFIG="$SRC_KC" oc -n "$S_NS" delete pvc "$BACKUP_CLAIM" --ignore-not-found

# Destination transfer pod (may already be deleted)
KUBECONFIG="$DST_KC" oc -n "$D_NS" delete pod "$DST_POD" --ignore-not-found

# Destination recovery PVC (DESTRUCTIVE)
KUBECONFIG="$DST_KC" oc -n "$D_NS" delete pvc "$D_PVC" --ignore-not-found
```


## Troubleshooting

- Backup CR not Successful:
  - Check operator/controller pods in source: `oc -n "$S_NS" get pods`, then `oc logs` the relevant pods
- Restore not completing:
  - Inspect the restore CR: `oc -n "$D_NS" get automationcontrollerrestore "$RESTORE_NAME" -o yaml`
  - Check operator/controller pods in destination
- StorageClass mismatch:
  - If the source SC is not present on destination, the default SC is used; ensure restore jobs can mount it
- Copy slow/failing:
  - Use rsync method if available, or verify network throughput
  - The UBI image contains `bash` and `tar` by default


## Notes

- These steps mirror the `pvc-migration.sh` script flow but give you full control per stage.
- Consider versioning only template files (e.g., `parameters/*.template.csv`) and keep real credentials/data in ignored local files.
