#!/usr/bin/env bash
# Retries creating one Always Free Arm VM (VM.Standard.A1.Flex) until Oracle has capacity.
# Needs only the OCI CLI (`oci`) and bash. Run from Git Bash:  ./grab-arm.sh
set -u
cd "$(dirname "$0")"

CONFIG="${1:-oci-arm.env}"
[ -f "$CONFIG" ] || { echo "Missing $CONFIG"; exit 1; }
# shellcheck disable=SC1090
source "$CONFIG"

# Free-tier guard: never launch anything bigger than the Always Free allowance.
MAX_OCPUS=2; MAX_MEMORY_GB=12; MAX_STORAGE_GB=200
if [ "$OCPUS" -gt "$MAX_OCPUS" ] || [ "$MEMORY_GB" -gt "$MAX_MEMORY_GB" ] || [ "$BOOT_GB" -gt "$MAX_STORAGE_GB" ]; then
  echo "Refusing to run: $OCPUS OCPU / $MEMORY_GB GB / $BOOT_GB GB is above the Always Free limit"
  echo "($MAX_OCPUS OCPU / $MAX_MEMORY_GB GB / $MAX_STORAGE_GB GB)."
  exit 1
fi

for var in COMPARTMENT_ID SUBNET_ID IMAGE_ID; do
  case "${!var}" in
    ""|PASTE_*) echo "Fill in $var in $CONFIG first."; exit 1 ;;
  esac
done
[ -f "$SSH_PUBLIC_KEY_FILE" ] || { echo "SSH public key not found: $SSH_PUBLIC_KEY_FILE"; exit 1; }
command -v oci >/dev/null || { echo "OCI CLI not found. Install it, then run: oci setup config"; exit 1; }

log() { echo "$(date '+%Y-%m-%d %H:%M:%S')  $*"; }

attempt=0
while true; do
  attempt=$((attempt + 1))
  existing=$(oci --no-retry compute instance list --region "$REGION" --compartment-id "$COMPARTMENT_ID" \
    --display-name "$DISPLAY_NAME" --query 'data[?"lifecycle-state"!=`TERMINATED`]|[0].id' --raw-output 2>/dev/null)
  case "$existing" in ocid1.instance.*)
    log "An instance named $DISPLAY_NAME already exists ($existing). Nothing to do."; exit 0 ;;
  esac

  out=$(oci --no-retry --connection-timeout 30 --read-timeout 300 compute instance launch \
    --region "$REGION" \
    --compartment-id "$COMPARTMENT_ID" \
    --availability-domain "$AVAILABILITY_DOMAIN" \
    --shape VM.Standard.A1.Flex \
    --shape-config "{\"ocpus\":$OCPUS,\"memoryInGBs\":$MEMORY_GB}" \
    --image-id "$IMAGE_ID" \
    --subnet-id "$SUBNET_ID" \
    --assign-public-ip true \
    --display-name "$DISPLAY_NAME" \
    --ssh-authorized-keys-file "$SSH_PUBLIC_KEY_FILE" \
    --boot-volume-size-in-gbs "$BOOT_GB" \
    --query 'data.id' --raw-output 2>&1)
  rc=$?

  if [ $rc -eq 0 ]; then
    log "SUCCESS after $attempt attempts. Instance: $out"
    log "Get its public IP in the console (Compute > Instances), or in a minute run:"
    log "  oci compute instance list-vnics --instance-id $out --query 'data[0].\"public-ip\"' --raw-output"
    exit 0
  elif echo "$out" | grep -qiE 'TooManyRequests|"status": 429|too many requests'; then
    log "Attempt $attempt: rate limited, cooling down ${COOLDOWN_SECONDS}s"
    sleep "$COOLDOWN_SECONDS"
  elif echo "$out" | grep -qiE 'capacity|InternalError|timed out|RequestException|ConnectTimeout'; then
    log "Attempt $attempt: out of capacity, retrying in ${RETRY_SECONDS}s"
    sleep "$RETRY_SECONDS"
  else
    log "Attempt $attempt: stopped on an error that retrying won't fix:"
    echo "$out"
    exit 1
  fi
done
