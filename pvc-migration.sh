#!/usr/bin/env bash
set -euo pipefail

need(){ command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing $1" >&2; exit 1; }; }
need oc
command -v rsync >/dev/null 2>&1 || echo "NOTE: rsync not found; will fallback to tar if chosen."

ts="$(date +%Y%m%d-%H%M%S)"
WORKDIR="$(pwd)"
LOGDIR="${WORKDIR}/pvc-migrate-logs-${ts}"
mkdir -p "$LOGDIR"
MASTER_LOG="${LOGDIR}/run-${ts}.log"
log(){ echo "[$(date +'%F %T')] $*" | tee -a "$MASTER_LOG" >&2; }

DEF_IMAGE="registry.redhat.io/ubi9:9.5"
DEF_METHOD="tar"
DEF_S_PATH="/backups"
DEF_D_PATH="/backups"

SRC_KC="${LOGDIR}/kubeconfig-source-${ts}"
DST_KC="${LOGDIR}/kubeconfig-destination-${ts}"
oc_s(){ KUBECONFIG="$SRC_KC" oc "$@"; }
oc_d(){ KUBECONFIG="$DST_KC" oc "$@"; }

prompt(){ local var="$1" msg="$2" def="${3:-}"; local v; if [ -n "$def" ]; then read -r -p "$msg [$def]: " v; v="${v:-$def}"; else read -r -p "$msg: " v; fi; eval "$var=\"\$v\""; }
prompt_secret(){ local var="$1" msg="$2"; local v; read -r -s -p "$msg (hidden): " v; echo; eval "$var=\"\$v\""; }
safe_name(){ echo "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9-.' '-' | sed -E 's/^-+//; s/-+$//'; }
lower_trim(){ tr -d '\r' | tr '[:upper:]' '[:lower:]' | tr -d ' '; }

# Listing helpers
list_pvcs_s(){ local ns="$1"; echo "PVCs in '${ns}' (source):"; oc_s -n "$ns" get pvc -o wide 2>&1 || oc_s -n "$ns" get pvc 2>&1 || echo "(failed)"; }
list_pvcs_d(){ local ns="$1"; echo "PVCs in '${ns}' (destination):"; oc_d -n "$ns" get pvc -o wide 2>&1 || oc_d -n "$ns" get pvc 2>&1 || echo "(failed)"; }

# Abort-capable prompt for PVC names
prompt_pvc_with_abort(){
  local which="$1" ns="$2" var="$3" msg="$4" def="${5:-}" v
  while true; do
    if [ -n "$def" ]; then read -r -p "$msg [$def] (type 'abort' to exit): " v; v="${v:-$def}"; else read -r -p "$msg (type 'abort' to exit): " v; fi
    case "$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')" in abort|q|quit) echo "Aborted by user."; exit 1;; esac
    if [ "$which" = "s" ]; then
      oc_s -n "$ns" get pvc "$v" >/dev/null 2>&1 && { eval "$var=\"\$v\""; break; }
      echo "PVC '$v' not found in '$ns' on source. Listing…"; list_pvcs_s "$ns"; def=""
    else
      oc_d -n "$ns" get pvc "$v" >/dev/null 2>&1 && { eval "$var=\"\$v\""; break; }
      echo "PVC '$v' not found in '$ns' on destination. Listing…"; list_pvcs_d "$ns"; def=""
    fi
  done
}

# ── CSV loaders ───────────────────────────────────────────────────────────────
load_pvc_csv(){
  local csv="$1"; [ -f "$csv" ] || { echo "PVC CSV not found: $csv" >&2; exit 1; }

  # Normalize header: strip BOM + CR, lower, remove spaces
  local header
  header="$(head -n1 "$csv" | sed '1 s/^\xEF\xBB\xBF//' | tr -d '\r' | tr '[:upper:]' '[:lower:]' | tr -d ' ')"
  IFS=',' read -r -a cols <<< "$header"

  index_of(){ local n="$1"; local i; for i in "${!cols[@]}"; do [ "${cols[$i]}" = "$n" ] && { echo "$i"; return; }; done; echo -1; }

  # Find indices (canonical + aliases)
  local i_src_ns i_src_pvc i_dst_ns i_dst_pvc i_src_path i_dst_path i_method i_ctrl
  i_src_ns=$(index_of "source_namespace"); [ $i_src_ns -lt 0 ] && i_src_ns=$(index_of "sourcenamespace")
  i_src_pvc=$(index_of "source_pvc");      [ $i_src_pvc -lt 0 ] && i_src_pvc=$(index_of "sourcepvc")
  i_dst_ns=$(index_of "dest_namespace");   [ $i_dst_ns -lt 0 ] && i_dst_ns=$(index_of "destnamespace")
  i_dst_pvc=$(index_of "dest_pvc");        [ $i_dst_pvc -lt 0 ] && i_dst_pvc=$(index_of "destpvc")
  i_src_path=$(index_of "source_path");    [ $i_src_path -lt 0 ] && i_src_path=$(index_of "sourcepath")
  i_dst_path=$(index_of "dest_path");      [ $i_dst_path -lt 0 ] && i_dst_path=$(index_of "destpath")
  i_method=$(index_of "method")
  i_ctrl=$(index_of "controller_name");    [ $i_ctrl -lt 0 ] && i_ctrl=$(index_of "controllername")

  # Required columns
  local missing=()
  [ $i_src_ns -lt 0 ] && missing+=("source_namespace")
  [ $i_dst_ns -lt 0 ] && missing+=("dest_namespace")
  if [ ${#missing[@]} -gt 0 ]; then
    echo "ERROR: Missing required column(s) in header: ${missing[*]}" >&2
    echo "Header seen: '$header'" >&2
    echo "Expected at least: source_namespace, dest_namespace [plus optional: source_pvc, dest_pvc, source_path, dest_path, method, controller_name]" >&2
    exit 1
  fi

  # First non-empty, non-comment data row
  local raw
  raw="$(tail -n +2 "$csv" | sed '/^[[:space:]]*#/d;/^[[:space:]]*$/d' | head -n1 || true)"
  [ -z "${raw:-}" ] && { echo "PVC CSV has no data row." >&2; exit 1; }
  IFS=',' read -r -a f <<< "$(echo "$raw" | tr -d '\r')"

  # Safe field getter
  getf(){ local idx="$1"; [ "${idx:-"-1"}" -ge 0 ] && printf '%s' "${f[$idx]:-}" || printf ''; }

  S_NS="$(getf "$i_src_ns")"
  S_PVC="$(getf "$i_src_pvc")"
  D_NS="$(getf "$i_dst_ns")"
  D_PVC="$(getf "$i_dst_pvc")"
  S_PATH="$(getf "$i_src_path")"
  D_PATH="$(getf "$i_dst_path")"
  METHOD="$(getf "$i_method" | tr '[:upper:]' '[:lower:]')"
  CONTROLLER_NAME="$(getf "$i_ctrl")"

  if [ -z "$S_NS" ] || [ -z "$D_NS" ]; then
    echo "ERROR: source_namespace or dest_namespace is empty in the first data row." >&2
    echo "Row: $raw" >&2
    exit 1
  fi
}

load_creds_csv(){
  local csv="$1"; [ -f "$csv" ] || { echo "Cred CSV not found: $csv" >&2; exit 1; }
  local header; header="$(head -n1 "$csv" | lower_trim)"; IFS=',' read -r -a cols <<< "$header"
  index_of(){ local n="$1"; local i; for i in "${!cols[@]}"; do [ "${cols[$i]}" = "$n" ] && { echo "$i"; return; }; done; echo -1; }
  local i_label i_api i_tok i_user i_pass i_insec
  i_label=$(index_of "label"); i_api=$(index_of "api_url"); [ $i_api -lt 0 ] && i_api=$(index_of "apiurl")
  i_tok=$(index_of "token"); i_user=$(index_of "user"); i_pass=$(index_of "pass"); i_insec=$(index_of "insecure")
  while IFS=',' read -r l api tok usr pss ins || [ -n "$l" ]; do
    [ -z "${l:-}" ] && continue
    l="$(echo "$l" | tr -d '\r' | tr '[:upper:]' '[:lower:]')"
    case "$l" in
      source)            S_API="$api"; S_TOKEN="$tok"; S_USER="$usr"; S_PASS="$pss"; S_INSECURE="$ins" ;;
      destination|dest)  D_API="$api"; D_TOKEN="$tok"; D_USER="$usr"; D_PASS="$pss"; D_INSECURE="$ins" ;;
    esac
  done < <(tail -n +2 "$csv" | awk -F, -v la="$i_label" -v aa="$i_api" -v tt="$i_tok" -v uu="$i_user" -v pp="$i_pass" -v ii="$i_insec" 'BEGIN{OFS=","} {print $la,$aa,$tt,$uu,$pp,$ii}')
}

# ── login helpers ─────────────────────────────────────────────────────────────
oc_login_try(){
  local which="$1" api="$2" token="$3" user="$4" pass="$5" insecure="${6:-false}"
  [ -z "${api:-}" ] && return 2
  local tls="--insecure-skip-tls-verify=false"
  local ins; ins="$(printf '%s' "$insecure" | tr '[:upper:]' '[:lower:]')"
  case "$ins" in 1|true|yes|y|on) tls="--insecure-skip-tls-verify=true" ;; esac
  if [ "$which" = "s" ]; then
    if [ -n "$token" ]; then KUBECONFIG="$SRC_KC" oc login "$api" --token "$token" $tls >/dev/null 2>&1 || return 1
    elif [ -n "$user" ] && [ -n "$pass" ]; then KUBECONFIG="$SRC_KC" oc login "$api" -u "$user" -p "$pass" $tls >/dev/null 2>&1 || return 1
    else return 2; fi
    oc_s whoami >/dev/null 2>&1 && oc_s api-resources >/dev/null 2>&1
  else
    if [ -n "$token" ]; then KUBECONFIG="$DST_KC" oc login "$api" --token "$token" $tls >/dev/null 2>&1 || return 1
    elif [ -n "$user" ] && [ -n "$pass" ]; then KUBECONFIG="$DST_KC" oc login "$api" -u "$user" -p "$pass" $tls >/dev/null 2>&1 || return 1
    else return 2; fi
    oc_d whoami >/dev/null 2>&1 && oc_d api-resources >/dev/null 2>&1
  fi
}

oc_login_prompt(){
  local which="$1" label; [ "$which" = "s" ] && label="source" || label="destination"
  while true; do
    echo "=== $label login ==="; echo "  1) Token"; echo "  2) Username/Password"; echo "  3) Abort"; read -r -p "Choose [1-3]: " m
    case "$m" in
      1) prompt api "API URL (e.g., https://api.cluster:6443)"; prompt_secret tok "Bearer token"
         read -r -p "Skip TLS verify? [y/N]: " yn; yn="${yn:-N}"
         if oc_login_try "$which" "$api" "$tok" "" "" "$([[ "$yn" =~ ^[Yy]$ ]] && echo true || echo false)"; then log "$label login validated."; break; else echo "Login failed."; fi ;;
      2) prompt api "API URL (e.g., https://api.cluster:6443)"; prompt user "Username"; prompt_secret pass "Password"
         read -r -p "Skip TLS verify? [y/N]: " yn; yn="${yn:-N}"
         if oc_login_try "$which" "$api" "" "$user" "$pass" "$([[ "$yn" =~ ^[Yy]$ ]] && echo true || echo false)"; then log "$label login validated."; break; else echo "Login failed."; fi ;;
      3) echo "Aborted."; exit 1;;
      *) echo "Invalid choice.";;
    esac
  done
}

ns_exists_s(){ oc_s get ns "$1" >/dev/null 2>&1; }
pvc_exists_s(){ oc_s -n "$1" get pvc "$2" >/dev/null 2>&1; }
ns_exists_d(){ oc_d get ns "$1" >/dev/null 2>&1; }
pvc_exists_d(){ oc_d -n "$1" get pvc "$2" >/dev/null 2>&1; }

# Pod creators
make_pod_s(){ local ns="$1" pod="$2" pvc="$3" img="$4"; cat <<YAML | oc_s -n "$ns" apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: { name: ${pod}, labels: { app: pvc-migrator } }
spec:
  restartPolicy: Never
  containers:
  - name: migrator
    image: ${img}
    command: ["bash","-lc","sleep infinity"]
    volumeMounts: [{ name: vol, mountPath: /backups }]
  volumes:
  - name: vol
    persistentVolumeClaim: { claimName: ${pvc} }
YAML
}
make_pod_d(){ local ns="$1" pod="$2" pvc="$3" img="$4"; cat <<YAML | oc_d -n "$ns" apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: { name: ${pod}, labels: { app: pvc-migrator } }
spec:
  restartPolicy: Never
  containers:
  - name: migrator
    image: ${img}
    command: ["bash","-lc","sleep infinity"]
    volumeMounts: [{ name: vol, mountPath: /backups }]
  volumes:
  - name: vol
    persistentVolumeClaim: { claimName: ${pvc} }
YAML
}
wait_ready_s(){ oc_s -n "$1" wait --for=condition=Ready "pod/$2" --timeout=300s >/dev/null; }
wait_ready_d(){ oc_d -n "$1" wait --for=condition=Ready "pod/$2" --timeout=300s >/dev/null; }
safe_del_s(){ oc_s -n "$1" delete pod "$2" --ignore-not-found >/dev/null 2>&1 || true; }
safe_del_d(){ oc_d -n "$1" delete pod "$2" --ignore-not-found >/dev/null 2>&1 || true; }

# Copy helpers (copy the folder itself)
copy_backup_dir_tar(){
  local sns="$1" spod="$2" src_parent="$3" dir_name="$4" dns="$5" dpod="$6" dpath="$7" tarf="$8"
  oc_s -n "$sns" exec "$spod" -- sh -lc "cd \"$src_parent\" && tar cf - \"$dir_name\" " > "$tarf"
  oc_d -n "$dns" cp "$tarf" "${dpod}:/tmp/payload.tar"
  oc_d -n "$dns" exec "$dpod" -- sh -lc "mkdir -p \"$dpath\" && tar xf /tmp/payload.tar -C \"$dpath\" && rm -f /tmp/payload.tar"
}
copy_backup_dir_rsync(){
  local sns="$1" spod="$2" src_parent="$3" dir_name="$4" dns="$5" dpod="$6" dpath="$7" tmp="$8"
  mkdir -p "$tmp"
  oc_s -n "$sns" rsync "${spod}:${src_parent}/${dir_name}" "$tmp/" >/dev/null
  oc_d -n "$dns" rsync "$tmp/${dir_name}" "${dpod}:${dpath}/" >/dev/null
  rm -rf "$tmp"
}

# PVC field getters (source)
pvc_field_s(){ oc_s -n "$1" get pvc "$2" -o "jsonpath=$3" 2>/dev/null || true; }
pvc_size_s(){ pvc_field_s "$1" "$2" '{.spec.resources.requests.storage}'; }
pvc_modes_s(){ pvc_field_s "$1" "$2" '{.spec.accessModes[*]}'; }
pvc_vmode_s(){ pvc_field_s "$1" "$2" '{.spec.volumeMode}'; }
pvc_sc_s(){ pvc_field_s "$1" "$2" '{.spec.storageClassName}'; }

# StorageClass helpers (destination)
default_sc_d(){
  # best-effort default SC detection
  oc_d get sc -o json 2>/dev/null | awk -v RS= '{if ($0 ~ /"is-default-class":"true"/) {match($0,/"name":"([^"]+)"/,m); if(m[1]!=""){print m[1]; exit}}}'
}
sc_exists_d(){ oc_d get sc "$1" >/dev/null 2>&1; }

# Cleanup trap
SRC_NS=""; SRC_POD=""; DST_NS=""; DST_POD=""
cleanup(){ [ -n "$SRC_NS" ] && [ -n "$SRC_POD" ] && safe_del_s "$SRC_NS" "$SRC_POD" || true
           [ -n "$DST_NS" ] && [ -n "$DST_POD" ] && safe_del_d "$DST_NS" "$DST_POD" || true; }
trap cleanup EXIT INT

# Args
PVC_FILE=""; CRED_FILE=""
usage(){ cat <<EOF
Usage:
  $0 --pvc pvc-map.csv [--cred cluster-creds.csv]
  $0 pvc-map.csv
EOF
}
[ $# -eq 0 ] && { usage; exit 1; }
while [ $# -gt 0 ]; do
  case "$1" in
    --pvc)  PVC_FILE="${2:-}"; shift 2 ;;
    --cred) CRED_FILE="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) if [ -z "$PVC_FILE" ]; then PVC_FILE="$1"; shift; else echo "Unknown arg: $1"; usage; exit 1; fi ;;
  esac
done
[ -n "$PVC_FILE" ] || { echo "ERROR: pvc-map CSV is required."; usage; exit 1; }
[ -f "$PVC_FILE" ] || { echo "PVC CSV not found: $PVC_FILE"; exit 1; }
[ -z "$CRED_FILE" ] && [ -f "$(dirname "$PVC_FILE")/cluster-creds.csv" ] && CRED_FILE="$(dirname "$PVC_FILE")/cluster-creds.csv"

# Load inputs
S_API=""; S_TOKEN=""; S_USER=""; S_PASS=""; S_INSECURE=""
D_API=""; D_TOKEN=""; D_USER=""; D_PASS=""; D_INSECURE=""
S_NS=""; S_PVC=""; S_PATH=""
D_NS=""; D_PVC=""; D_PATH=""
METHOD=""; IMAGE="$DEF_IMAGE"; CONTROLLER_NAME=""

load_pvc_csv "$PVC_FILE"
[ -n "${S_PATH:-}" ] || S_PATH="$DEF_S_PATH"
[ -n "${D_PATH:-}" ] || D_PATH="$DEF_D_PATH"
[ -n "${METHOD:-}" ] || METHOD="$DEF_METHOD"
[ -n "$CRED_FILE" ] && load_creds_csv "$CRED_FILE"

log "Logs at: $LOGDIR"

# Logins
echo "Validating source cluster login…"
if ! oc_login_try s "${S_API:-}" "${S_TOKEN:-}" "${S_USER:-}" "${S_PASS:-}" "${S_INSECURE:-false}"; then echo "CSV login for source failed or incomplete."; oc_login_prompt s; else log "source login validated."; fi
echo "Validating destination cluster login…"
if ! oc_login_try d "${D_API:-}" "${D_TOKEN:-}" "${D_USER:-}" "${D_PASS:-}" "${D_INSECURE:-false}"; then echo "CSV login for destination failed or incomplete."; oc_login_prompt d; else log "destination login validated."; fi

# Required fields
[ -n "$S_NS" ] || prompt S_NS "Source namespace"
[ -n "$D_NS" ] || prompt D_NS "Destination namespace"
[ -n "$CONTROLLER_NAME" ] || prompt CONTROLLER_NAME "Controller (deployment) name" "controller"

ns_exists_s "$S_NS" || { echo "Source namespace '$S_NS' not found."; exit 1; }
ns_exists_d "$D_NS" || { echo "Destination namespace '$D_NS' not found."; exit 1; }

# ── Create AutomationControllerBackup on source & wait Successful ─────────────
BACKUP_NAME="controller-backup"
log "Creating AutomationControllerBackup '$BACKUP_NAME' in '$S_NS' for deployment '$CONTROLLER_NAME'…"
oc_s -n "$S_NS" get automationcontrollerbackup "$BACKUP_NAME" >/dev/null 2>&1 && oc_s -n "$S_NS" delete automationcontrollerbackup "$BACKUP_NAME" --wait=true >/dev/null 2>&1 || true
cat <<YAML | oc_s -n "$S_NS" apply -f - >/dev/null
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

log "Waiting for backup to complete (Successful)…"
BACKUP_DIR=""; BACKUP_CLAIM=""
START_TS=$(date +%s); TIMEOUT=$((30*60)); SLEEP=10
while true; do
  reason="$(oc_s -n "$S_NS" get automationcontrollerbackup "$BACKUP_NAME" -o jsonpath='{.status.conditions[?(@.type=="Successful")].reason}' 2>/dev/null || true)"
  status_succ="$(oc_s -n "$S_NS" get automationcontrollerbackup "$BACKUP_NAME" -o jsonpath='{.status.conditions[?(@.type=="Successful")].status}' 2>/dev/null || true)"
  BACKUP_DIR="$(oc_s -n "$S_NS" get automationcontrollerbackup "$BACKUP_NAME" -o jsonpath='{.status.backupDirectory}' 2>/dev/null || true)"
  BACKUP_CLAIM="$(oc_s -n "$S_NS" get automationcontrollerbackup "$BACKUP_NAME" -o jsonpath='{.status.backupClaim}' 2>/dev/null || true)"
  log "Backup status: Successful.status='${status_succ:-}', Successful.reason='${reason:-}', dir='${BACKUP_DIR:-}', claim='${BACKUP_CLAIM:-}'"
  [ "${status_succ:-}" = "True" ] && [ "${reason:-}" = "Successful" ] && break
  [ $(( $(date +%s) - START_TS )) -ge $TIMEOUT ] && { echo "ERROR: Timed out waiting for backup."; exit 1; }
  sleep "$SLEEP"
done

# Source backup claim + path
[ -n "$BACKUP_CLAIM" ] || BACKUP_CLAIM="${CONTROLLER_NAME}-backup-claim"
[ -n "$BACKUP_DIR" ] || BACKUP_DIR="$DEF_S_PATH"
BACKUP_PARENT="$(dirname "$BACKUP_DIR")"
BACKUP_DIR_NAME="$(basename "$BACKUP_DIR")"
log "Using source PVC='${BACKUP_CLAIM}', backup dir='${BACKUP_DIR}', dir name='${BACKUP_DIR_NAME}'."

# ── Ensure destination PVC exists & matches source size/modes ────────────────
# Get source PVC spec bits
SRC_SIZE="$(pvc_size_s "$S_NS" "$BACKUP_CLAIM")"
SRC_MODES="$(pvc_modes_s "$S_NS" "$BACKUP_CLAIM")"
SRC_VMODE="$(pvc_vmode_s "$S_NS" "$BACKUP_CLAIM")"
SRC_SC="$(pvc_sc_s "$S_NS" "$BACKUP_CLAIM")"

DEFAULT_DEST_PVC="${CONTROLLER_NAME}-recovery-claim"
[ -n "${D_PVC:-}" ] || D_PVC="$DEFAULT_DEST_PVC"

DEST_SC=""
if [ -n "$SRC_SC" ] && sc_exists_d "$SRC_SC"; then DEST_SC="$SRC_SC"; else DEST_SC="$(default_sc_d)"; fi
[ -n "$DEST_SC" ] || log "WARNING: could not detect default StorageClass on destination; PVC will use cluster default."

# AccessModes normalization and YAML list rendering
# shellcheck disable=SC2206
AM_ARR=($SRC_MODES)
[ ${#AM_ARR[@]} -eq 0 ] && AM_ARR=("ReadWriteOnce")
am_yaml=""
for m in "${AM_ARR[@]}"; do
  if [ -n "$am_yaml" ]; then am_yaml="$am_yaml, $m"; else am_yaml="$m"; fi
done

create_dest_pvc_if_missing(){
  local ns="$1" pvc="$2" size="$3" vmode="$4" sc="$5"
  if pvc_exists_d "$ns" "$pvc"; then
    log "Destination PVC '$pvc' already exists in '$ns'. Skipping creation."
    return 0
  fi
  log "Creating destination PVC '$pvc' in '$ns' (size=$size, modes=[${am_yaml}], volumeMode=${vmode:-Filesystem}, sc=${sc:-<cluster-default>})…"

  {
    cat <<YAML
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${pvc}
spec:
  accessModes: [${am_yaml}]
  resources:
    requests:
      storage: ${size}
  volumeMode: ${vmode:-Filesystem}
YAML
    if [ -n "$sc" ]; then
      echo "  storageClassName: ${sc}"
    fi
  } | oc_d -n "$ns" apply -f - >/dev/null
  log "Destination PVC '$pvc' is Created."
}

[ -n "$SRC_SIZE" ] || { log "WARNING: could not read source PVC size; defaulting to 20Gi."; SRC_SIZE="20Gi"; }
create_dest_pvc_if_missing "$D_NS" "$D_PVC" "$SRC_SIZE" "$SRC_VMODE" "$DEST_SC"

# ── Create transfer pods ─────────────────────────────────────────────────────
SRC_NS="$S_NS"; DST_NS="$D_NS"
SRC_POD="$(safe_name "pvc-src-${ts}")"; DST_POD="$(safe_name "pvc-dst-${ts}")"
prompt IMAGE "Ephemeral pod image" "$DEF_IMAGE"
if [ "$METHOD" = "rsync" ] && ! command -v rsync >/dev/null 2>&1; then echo "rsync not available; switching to tar."; METHOD="tar"; fi
echo "Copy method: $METHOD"

log "Creating source pod in '$S_NS' on PVC '$BACKUP_CLAIM'…"; make_pod_s "$S_NS" "$SRC_POD" "$BACKUP_CLAIM" "$IMAGE"; wait_ready_s "$S_NS" "$SRC_POD"
log "Creating destination pod in '$D_NS' on PVC '$D_PVC'…"; make_pod_d "$D_NS" "$DST_POD" "$D_PVC" "$IMAGE"; wait_ready_d "$D_NS" "$DST_POD"
oc_d -n "$D_NS" exec "$DST_POD" -- sh -lc "mkdir -p \"$DEF_D_PATH\"" >/dev/null

# ── Copy the backup directory (preserve folder name) ─────────────────────────
SRC_H="$(oc_s -n "$S_NS" exec "$SRC_POD" -- sh -lc "du -sh \"$BACKUP_DIR\" 2>/dev/null | awk '{print \$1}'" || echo 0)"
SRC_B="$(oc_s -n "$S_NS" exec "$SRC_POD" -- sh -lc "du -s \"$BACKUP_DIR\" 2>/dev/null | awk '{print \$1}'" || echo 0)"
log "Source backup dir size: $SRC_H (${SRC_B:-0} blocks)"

if [ "$METHOD" = "rsync" ]; then
  copy_backup_dir_rsync "$S_NS" "$SRC_POD" "$BACKUP_PARENT" "$BACKUP_DIR_NAME" "$D_NS" "$DST_POD" "$DEF_D_PATH" "${LOGDIR}/tmp_copy"
else
  copy_backup_dir_tar   "$S_NS" "$SRC_POD" "$BACKUP_PARENT" "$BACKUP_DIR_NAME" "$D_NS" "$DST_POD" "$DEF_D_PATH" "${LOGDIR}/payload.tar"
fi

DST_DIR_PATH="${DEF_D_PATH}/${BACKUP_DIR_NAME}"
oc_d -n "$D_NS" exec "$DST_POD" -- sh -lc "command -v restorecon >/dev/null 2>&1 && restorecon -Rvv \"$DST_DIR_PATH\" || true" >/dev/null || true
DST_H="$(oc_d -n "$D_NS" exec "$DST_POD" -- sh -lc "du -sh \"$DST_DIR_PATH\" 2>/dev/null | awk '{print \$1}'" || echo 0)"
DST_B="$(oc_d -n "$D_NS" exec "$DST_POD" -- sh -lc "du -s \"$DST_DIR_PATH\" 2>/dev/null | awk '{print \$1}'" || echo 0)"
log "Destination backup dir size: $DST_H (${DST_B:-0} blocks)"

if [[ "${SRC_B:-0}" =~ ^[0-9]+$ && "${DST_B:-0}" =~ ^[0-9]+$ && "$SRC_B" -gt 0 ]]; then
  TOL=$(( SRC_B/100 + 16 )); DIFF=$(( DST_B - SRC_B )); [ "$DIFF" -lt 0 ] && DIFF=$(( -DIFF ))
  [ "$DIFF" -le "$TOL" ] && log "Size check PASSED (Δ=${DIFF} ≤ ${TOL})." || log "WARNING: Size Δ=${DIFF} (> ${TOL})."
else
  log "Skipping size delta check; empty/unmeasurable."
fi

# ── Delete destination transfer pod before restore ───────────────────────────
log "Deleting destination transfer pod '$DST_POD' before restore…"
safe_del_d "$D_NS" "$DST_POD"
DST_POD=""

# ── Create AutomationControllerRestore on destination & wait ─────────────────
RESTORE_NAME="aap-controller-restore"
BACKUP_DIR_FOR_RESTORE="$BACKUP_DIR_NAME"    # folder name only
BACKUP_PVC_FOR_RESTORE="$D_PVC"              # the PVC we created/used

oc_d -n "$D_NS" get automationcontrollerrestore "$RESTORE_NAME" >/dev/null 2>&1 && oc_d -n "$D_NS" delete automationcontrollerrestore "$RESTORE_NAME" --wait=true >/dev/null 2>&1 || true
log "Creating AutomationControllerRestore '$RESTORE_NAME' in '$D_NS'…"
cat <<YAML | oc_d -n "$D_NS" apply -f - >/dev/null
apiVersion: automationcontroller.ansible.com/v1beta1
kind: AutomationControllerRestore
metadata:
  name: ${RESTORE_NAME}
  namespace: ${D_NS}
spec:
  backup_dir: /backups/${BACKUP_DIR_FOR_RESTORE}
  backup_pvc: ${BACKUP_PVC_FOR_RESTORE}
  backup_source: PVC
  deployment_name: ${CONTROLLER_NAME}
  force_drop_db: false
  image_pull_policy: IfNotPresent
  no_log: true
  set_self_labels: true
YAML

log "Waiting for restore to complete (Successful + restoreComplete=true)…"
START_TS=$(date +%s); TIMEOUT=$((30*60)); SLEEP=10
while true; do
  r_reason="$(oc_d -n "$D_NS" get automationcontrollerrestore "$RESTORE_NAME" -o jsonpath='{.status.conditions[?(@.type=="Successful")].reason}' 2>/dev/null || true)"
  r_status="$(oc_d -n "$D_NS" get automationcontrollerrestore "$RESTORE_NAME" -o jsonpath='{.status.conditions[?(@.type=="Successful")].status}' 2>/dev/null || true)"
  r_complete="$(oc_d -n "$D_NS" get automationcontrollerrestore "$RESTORE_NAME" -o jsonpath='{.status.restoreComplete}' 2>/dev/null || true)"
  log "Restore status: Successful.status='${r_status:-}', Successful.reason='${r_reason:-}', restoreComplete='${r_complete:-}'"
  [ "${r_status:-}" = "True" ] && [ "${r_reason:-}" = "Successful" ] && [ "${r_complete:-}" = "true" ] && break
  [ $(( $(date +%s) - START_TS )) -ge $TIMEOUT ] && { echo "ERROR: Timed out waiting for restore."; exit 1; }
  sleep "$SLEEP"
done
log "Restore completed successfully."

# ── Final cleanup: pods + PVCs (DESTRUCTIVE) ─────────────────────────────────
log "Cleaning up transfer pods and PVCs…"
safe_del_s "$S_NS" "$SRC_POD"       # source transfer pod
safe_del_d "$D_NS" "$DST_POD" || true  # already deleted, OK

# Delete PVCs as requested (destructive)
log "Deleting source backup PVC '$BACKUP_CLAIM' in '$S_NS'…"
oc_s -n "$S_NS" delete pvc "$BACKUP_CLAIM" --ignore-not-found || true

log "Deleting destination recovery PVC '$D_PVC' in '$D_NS'…"
oc_d -n "$D_NS" delete pvc "$D_PVC" --ignore-not-found || true

log "All done."
exit 0
