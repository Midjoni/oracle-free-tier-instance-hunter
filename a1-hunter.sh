#!/usr/bin/env bash
# a1-hunter — keep asking Oracle Cloud for an Always Free instance until one exists.
#
# Oracle's free ARM (VM.Standard.A1.Flex) capacity in popular regions is chronically
# exhausted; every launch returns "Out of host capacity". The only reliable answer is
# to keep asking, politely, until a host frees up. This does that.
#
# Usage:  ./a1-hunter.sh [path/to/config.env]
# Docs:   README.md

set -uo pipefail

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<'USAGE'
a1-hunter — keep asking Oracle Cloud for an Always Free instance until one exists.

  ./a1-hunter.sh [config-file]        run (default config: ./config.env)
  DRY_RUN=1 ./a1-hunter.sh            resolve config, print it, launch nothing
  CREATE_NETWORK=1 ./a1-hunter.sh     create a VCN + public subnet if none exists

Common overrides (or put them in config.env):
  OCI_PROFILE=DEFAULT  SHAPE=VM.Standard.A1.Flex  OCPUS=2  MEMORY_GB=12
  INTERVAL=60  DEADLINE_DAYS=0  SSH_KEY_FILE=~/.ssh/id_rsa.pub

Full documentation: https://github.com/ethereaglehq/oracle-free-tier-instance-hunter
USAGE
  exit 0
fi

CONFIG="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config.env}"
# shellcheck source=/dev/null  # config path is user-supplied by design
[[ -f "$CONFIG" ]] && . "$CONFIG"

OCI_BIN="${OCI_BIN:-oci}"
OCI_PROFILE="${OCI_PROFILE:-${OCI_CLI_PROFILE:-DEFAULT}}"
OCI_CONFIG_FILE="${OCI_CONFIG_FILE:-${OCI_CLI_CONFIG_FILE:-$HOME/.oci/config}}"
OCI_CONFIG_FILE="${OCI_CONFIG_FILE/#\~/$HOME}"  # a quoted "~/..." in config.env is not expanded by the shell

SHAPE="${SHAPE:-VM.Standard.A1.Flex}"
OCPUS="${OCPUS:-2}"
MEMORY_GB="${MEMORY_GB:-12}"
BOOT_VOLUME_GB="${BOOT_VOLUME_GB:-50}"
DISPLAY_NAME="${DISPLAY_NAME:-free-instance}"
OPERATING_SYSTEM="${OPERATING_SYSTEM:-Canonical Ubuntu}"
OS_VERSION="${OS_VERSION:-24.04}"
ASSIGN_PUBLIC_IP="${ASSIGN_PUBLIC_IP:-true}"
SSH_KEY_FILE="${SSH_KEY_FILE:-$HOME/.ssh/id_rsa.pub}"

INTERVAL="${INTERVAL:-120}"         # seconds between attempts; lowering this measurably hurts, see README
MAX_BACKOFF="${MAX_BACKOFF:-900}"   # ceiling for the 429 backoff
DEADLINE_DAYS="${DEADLINE_DAYS:-0}" # 0 = run forever
DRY_RUN="${DRY_RUN:-0}"             # 1 = resolve everything and exit without launching
CREATE_NETWORK="${CREATE_NETWORK:-0}" # 1 = build a VCN + public subnet if none found
LOG_FILE="${LOG_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/a1-hunter.log}"
RESULT_FILE="${RESULT_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/result.json}"

TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
WEBHOOK_URL="${WEBHOOK_URL:-}"

log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"; }
die() { log "FATAL: $*"; exit 1; }

oci_q() { "$OCI_BIN" "$@" --config-file "$OCI_CONFIG_FILE" --profile "$OCI_PROFILE" 2>&1; }

# Print KEY from the active profile of the OCI config, falling back to [DEFAULT] the way
# the oci CLI does. Accepts "key=value" (what `oci setup config` writes) and "key = value",
# CRLF line endings, indentation and comment lines.
oci_config_get() {
  awk -v want="$OCI_PROFILE" -v key="$1" '
    { sub(/\r$/, "") }
    /^[ \t]*([#;]|$)/ { next }
    /^[ \t]*\[/ { sec = $0; gsub(/^[ \t]*\[[ \t]*|[ \t]*\][ \t]*$/, "", sec); next }
    {
      eq = index($0, "="); if (!eq) next
      k = substr($0, 1, eq - 1); v = substr($0, eq + 1)
      gsub(/^[ \t]+|[ \t]+$/, "", k); gsub(/^[ \t]+|[ \t]+$/, "", v)
      if (k != key) next
      if (sec == want) found = v; else if (sec == "DEFAULT") dflt = v
    }
    END { print (found != "" ? found : dflt) }' "$OCI_CONFIG_FILE"
}

notify() {
  local msg="$1"
  if [[ -n "$TELEGRAM_BOT_TOKEN" && -n "$TELEGRAM_CHAT_ID" ]]; then
    curl -fsS -m 20 -X POST \
      "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      -d chat_id="${TELEGRAM_CHAT_ID}" -d text="$msg" >/dev/null 2>&1 \
      || log "warn: telegram notification failed"
  fi
  if [[ -n "$WEBHOOK_URL" ]]; then
    curl -fsS -m 20 -H 'Content-Type: application/json' \
      -d "$(printf '{"content":%s,"text":%s}' "$(printf '%s' "$msg" | jq -Rs .)" "$(printf '%s' "$msg" | jq -Rs .)")" \
      "$WEBHOOK_URL" >/dev/null 2>&1 || log "warn: webhook notification failed"
  fi
}

command -v "$OCI_BIN" >/dev/null || die "oci CLI not found (set OCI_BIN). See README."
[[ -f "$SSH_KEY_FILE" ]] || die "SSH public key not found: $SSH_KEY_FILE (generate one with: ssh-keygen -t ed25519)"
(( INTERVAL < 30 )) && log "warn: INTERVAL=${INTERVAL}s is below 30s — expect TooManyRequests, which will slow you down overall"

trap 'log "interrupted — exiting"; exit 130' INT TERM

# Create a minimal public network if the account has none. Opt-in via CREATE_NETWORK=1.
create_network() {
  log "CREATE_NETWORK=1 and no subnet found — building VCN, gateway, route and subnet"
  local vcn igw rt
  vcn=$(oci_q network vcn create --compartment-id "$COMPARTMENT_ID" \
        --cidr-blocks '["10.0.0.0/16"]' --display-name "a1-hunter-vcn" \
        --dns-label "a1hunter" --wait-for-state AVAILABLE \
        --query 'data.id' --raw-output) || die "VCN creation failed: $vcn"
  [[ "$vcn" == ocid1.vcn* ]] || die "VCN creation failed: $vcn"
  log "  vcn created"

  igw=$(oci_q network internet-gateway create --compartment-id "$COMPARTMENT_ID" \
        --vcn-id "$vcn" --is-enabled true --display-name "a1-hunter-igw" \
        --wait-for-state AVAILABLE --query 'data.id' --raw-output) || die "internet gateway creation failed: $igw"
  log "  internet gateway created"

  rt=$(oci_q network vcn get --vcn-id "$vcn" --query 'data."default-route-table-id"' --raw-output)
  oci_q network route-table update --rt-id "$rt" --force \
    --route-rules "[{\"destination\":\"0.0.0.0/0\",\"destinationType\":\"CIDR_BLOCK\",\"networkEntityId\":\"$igw\"}]" >/dev/null \
    || die "route table update failed"
  log "  default route -> internet gateway"

  SUBNET_ID=$(oci_q network subnet create --compartment-id "$COMPARTMENT_ID" \
    --vcn-id "$vcn" --cidr-block "10.0.0.0/24" --display-name "a1-hunter-public" \
    --prohibit-public-ip-on-vnic false --route-table-id "$rt" \
    --wait-for-state AVAILABLE --query 'data.id' --raw-output) || die "subnet creation failed: $SUBNET_ID"
  [[ "$SUBNET_ID" == ocid1.subnet* ]] || die "subnet creation failed: $SUBNET_ID"
  log "  public subnet created: ...${SUBNET_ID: -12}"
}

# ---------- discovery: fill in anything the user didn't configure ----------

if [[ -z "${COMPARTMENT_ID:-}" ]]; then
  # Default to the tenancy root — where Always Free resources normally live.
  [[ -f "$OCI_CONFIG_FILE" ]] || die "OCI config not found: $OCI_CONFIG_FILE (run: oci setup config, or set OCI_CONFIG_FILE)"
  COMPARTMENT_ID=$(oci_config_get tenancy)
  [[ "$COMPARTMENT_ID" == ocid1.tenancy* ]] \
    || die "could not read a tenancy OCID from $OCI_CONFIG_FILE for profile [$OCI_PROFILE] (got: '${COMPARTMENT_ID}')"
  log "discovered compartment (tenancy root): ...${COMPARTMENT_ID: -12}"
fi

if [[ -z "${AVAILABILITY_DOMAINS:-}" ]]; then
  AVAILABILITY_DOMAINS=$(oci_q iam availability-domain list --compartment-id "$COMPARTMENT_ID" \
    --query 'data[].name' --raw-output | tr -d '[]", ' | grep -v '^$' | paste -sd, -)
  [[ -n "$AVAILABILITY_DOMAINS" ]] || die "could not list availability domains"
  log "discovered ADs: $AVAILABILITY_DOMAINS"
fi

if [[ -z "${SUBNET_ID:-}" ]]; then
  SUBNET_ID=$(oci_q network subnet list --compartment-id "$COMPARTMENT_ID" --all \
    --query 'data[0].id' --raw-output)
  if [[ "$SUBNET_ID" != ocid1.subnet* ]]; then
    if [[ "$CREATE_NETWORK" == "1" ]]; then
      create_network
    else
      die "no subnet found. Either create a VCN with a public subnet in the console, or re-run with CREATE_NETWORK=1 to have this script build one."
    fi
  else
    log "discovered subnet: ...${SUBNET_ID: -12}"
  fi
fi

if [[ -z "${IMAGE_ID:-}" ]]; then
  IMAGE_ID=$(oci_q compute image list --compartment-id "$COMPARTMENT_ID" \
    --operating-system "$OPERATING_SYSTEM" --operating-system-version "$OS_VERSION" \
    --shape "$SHAPE" --sort-by TIMECREATED --sort-order DESC \
    --query 'data[0].id' --raw-output)
  [[ "$IMAGE_ID" == ocid1.image* ]] || die "no image found for $OPERATING_SYSTEM $OS_VERSION on $SHAPE"
  log "discovered image: ...${IMAGE_ID: -12}"
fi

# Flex shapes need a shape-config; fixed shapes (E2.1.Micro) must not get one.
SHAPE_ARGS=()
if [[ "$SHAPE" == *Flex ]]; then
  SHAPE_ARGS=(--shape-config "{\"ocpus\":${OCPUS},\"memoryInGBs\":${MEMORY_GB}}")
fi

IFS=',' read -r -a AD_LIST <<< "$AVAILABILITY_DOMAINS"

if [[ "$DRY_RUN" == "1" ]]; then
  log "DRY RUN — resolved configuration, launching nothing:"
  log "  profile:     $OCI_PROFILE"
  log "  shape:       $SHAPE ${OCPUS} OCPU / ${MEMORY_GB} GB, ${BOOT_VOLUME_GB} GB boot"
  log "  compartment: $COMPARTMENT_ID"
  log "  ADs:         ${AD_LIST[*]}"
  log "  subnet:      $SUBNET_ID"
  log "  image:       $IMAGE_ID"
  log "  ssh key:     $SSH_KEY_FILE"
  log "  pacing:      every ${INTERVAL}s, backoff cap ${MAX_BACKOFF}s, deadline ${DEADLINE_DAYS}d"
  existing=$(oci_q compute instance list --compartment-id "$COMPARTMENT_ID" --all \
    --query "data[?\"lifecycle-state\"!='TERMINATED'].\"display-name\"" --raw-output)
  if [[ -n "$existing" && "$existing" != "[]" ]]; then
    log "  existing:    $existing  (the real run would exit immediately)"
  else
    log "  existing:    none — the real run would start launching"
  fi
  exit 0
fi
DEADLINE=0
(( DEADLINE_DAYS > 0 )) && DEADLINE=$(( $(date +%s) + DEADLINE_DAYS * 86400 ))

log "=== a1-hunter starting — $SHAPE ${OCPUS}/${MEMORY_GB}GB, ${#AD_LIST[@]} AD(s), every ${INTERVAL}s ==="

backoff="$INTERVAL"
attempt=0

while :; do
  if (( DEADLINE > 0 )) && (( $(date +%s) >= DEADLINE )); then
    log "=== deadline reached after ${DEADLINE_DAYS}d — exiting without an instance ==="
    exit 0
  fi

  # Never create a second instance: if one already exists, we are done.
  existing=$(oci_q compute instance list --compartment-id "$COMPARTMENT_ID" --all \
    --query "data[?\"lifecycle-state\"!='TERMINATED'].\"display-name\"" --raw-output)
  if [[ -n "$existing" && "$existing" != "[]" ]]; then
    log "an instance already exists in this compartment: $existing — nothing to do"
    exit 0
  fi

  ad="${AD_LIST[$(( attempt % ${#AD_LIST[@]} ))]}"
  attempt=$(( attempt + 1 ))

  # Note: no --fault-domain. Letting Oracle choose materially improves the odds;
  # pinning one restricts you to a subset of hosts.
  out=$(oci_q compute instance launch \
      --compartment-id "$COMPARTMENT_ID" \
      --availability-domain "$ad" \
      --display-name "$DISPLAY_NAME" \
      --shape "$SHAPE" "${SHAPE_ARGS[@]}" \
      --image-id "$IMAGE_ID" \
      --subnet-id "$SUBNET_ID" \
      --assign-public-ip "$ASSIGN_PUBLIC_IP" \
      --boot-volume-size-in-gbs "$BOOT_VOLUME_GB" \
      --ssh-authorized-keys-file "$SSH_KEY_FILE")

  if grep -q '"lifecycle-state"' <<< "$out"; then
    printf '%s\n' "$out" > "$RESULT_FILE"
    log "SUCCESS on attempt $attempt in $ad — details written to $RESULT_FILE"
    notify "Oracle free instance created: $DISPLAY_NAME ($SHAPE ${OCPUS}/${MEMORY_GB}GB) in $ad after $attempt attempts."
    exit 0
  fi

  code=$(grep -o '"code": *"[^"]*"' <<< "$out" | head -1 | sed 's/.*: *"//;s/"//')
  msg=$(grep -o '"message": *"[^"]*"' <<< "$out" | head -1 | sed 's/.*: *"//;s/"//')

  case "$code" in
    TooManyRequests)
      backoff=$(( backoff * 2 )); (( backoff > MAX_BACKOFF )) && backoff=$MAX_BACKOFF
      log "attempt $attempt [$ad]: rate limited — waiting ${backoff}s" ;;
    InternalError|LimitExceeded|ServiceUnavailable)
      backoff="$INTERVAL"
      log "attempt $attempt [$ad]: ${msg:-$code}" ;;
    NotAuthenticated|NotAuthorizedOrNotFound)
      log "attempt $attempt [$ad]: ${msg:-$code}"
      die "authentication/authorization failed — check your profile, API key and compartment" ;;
    "")
      backoff="$INTERVAL"
      log "attempt $attempt [$ad]: ${msg:-no error code parsed; see log}" ;;
    *)
      backoff=$(( backoff * 2 )); (( backoff > MAX_BACKOFF )) && backoff=$MAX_BACKOFF
      log "attempt $attempt [$ad]: unexpected ($code) ${msg:-} — waiting ${backoff}s" ;;
  esac

  sleep $(( backoff + RANDOM % 15 ))
done
