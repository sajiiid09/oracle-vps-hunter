#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# The retry loop. Attempts LaunchInstance on a polite cadence, rotating
# availability domains, until capacity appears or a fatal error stops it.
#
#   ./hunt.sh              loop until it wins
#   ./hunt.sh --once       one verbose attempt, no loop (config check)
#   ./hunt.sh --test-alert fire the success notification and exit
# ---------------------------------------------------------------------------
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"
[ -f ./config.env ] || { echo "config.env missing — run ./setup.sh first." >&2; exit 1; }
source ./config.env

LOG="$DIR/logs/hunt.log"
STATE="$DIR/logs/state"
mkdir -p "$DIR/logs"

MODE="loop"
case "${1:-}" in
  --once)       MODE="once" ;;
  --test-alert) MODE="testalert" ;;
  "")           ;;
  *) echo "unknown flag: $1" >&2; exit 2 ;;
esac

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG"; }
# Quiet variant: capacity misses go to the file only, so a --once run or a
# `ctl.sh log` tail stays readable across thousands of attempts.
logf() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }

# ---------------------------------------------------------------------------
alert() {
  local title="$1" msg="$2"
  for _ in $(seq 1 "$ALERT_REPEATS"); do
    osascript -e "display notification \"$msg\" with title \"$title\" sound name \"Glass\"" >/dev/null 2>&1
    [ -f "$ALERT_SOUND" ] && afplay "$ALERT_SOUND" >/dev/null 2>&1
    sleep 1
  done
}

if [ "$MODE" = "testalert" ]; then
  echo "Firing $ALERT_REPEATS notifications..."
  alert "A1 Hunter — test" "If you see and hear this, alerts work."
  exit 0
fi

[ -f ./resolved.env ] || { echo "resolved.env missing — run ./setup.sh first." >&2; exit 1; }
source ./resolved.env

# ---------------------------------------------------------------------------
# We drive the cadence ourselves, so disable the CLI's own hidden retry loop
# (it silently retries 429s and 500s, which would wreck our timing and mask
# throttling from the backoff logic).
# Capture first, then grep. Piping into `grep -q` under `set -o pipefail`
# makes the pipeline exit 141 (SIGPIPE) the moment grep matches and closes the
# pipe, which silently loses the flag and lets the CLI retry on its own.
NORETRY=""
OCI_HELP="$(oci --help 2>&1)"
grep -q -- '--no-retry' <<<"$OCI_HELP" && NORETRY="--no-retry"

OCI_BASE=(oci --profile "$OCI_PROFILE" --region "$HOME_REGION")
[ -n "$NORETRY" ] && OCI_BASE+=("$NORETRY")

launch_once() {
  local ad="$1"
  "${OCI_BASE[@]}" compute instance launch \
    --availability-domain "$ad" \
    --compartment-id "$COMPARTMENT_OCID" \
    --shape "$SHAPE" \
    --shape-config "{\"ocpus\":$OCPUS,\"memoryInGBs\":$MEMORY_GB}" \
    --image-id "$IMAGE_OCID" \
    --subnet-id "$SUBNET_OCID" \
    --boot-volume-size-in-gbs "$BOOT_VOLUME_GB" \
    --assign-public-ip true \
    --display-name "$INSTANCE_NAME" \
    --metadata "file://$METADATA_FILE" \
    --wait-for-state RUNNING \
    --wait-interval-seconds 10 \
    --max-wait-seconds 900 \
    --output json 2>&1
}

# Turns raw CLI output into one of: capacity | throttle | limit | auth |
# notfound | network | unknown
classify() {
  local out="$1"
  if   grep -qiE 'out of (host )?capacity|outofcapacity|out of capacity for shape' <<<"$out"; then echo capacity
  elif grep -qiE 'toomanyrequests|too many requests|"status": ?429|rate.?limit' <<<"$out"; then echo throttle
  elif grep -qiE 'limitexceeded|quotaexceeded|service limit|exceeded.*limit'      <<<"$out"; then echo limit
  elif grep -qiE 'notauthenticated|"status": ?401|invalid.*signature'             <<<"$out"; then echo auth
  elif grep -qiE 'notauthorizedornotfound|"status": ?404'                         <<<"$out"; then echo notfound
  elif grep -qiE 'connectionerror|max retries exceeded|could not connect|nodename nor servname|temporary failure in name resolution|timed out' <<<"$out"; then echo network
  else echo unknown
  fi
}

on_success() {
  local out="$1"
  local id ip
  # launch_once merges stderr, so the CLI's SyntaxWarning banner sits in front
  # of the JSON. Skip to the first brace and decode from there.
  id="$(python3 -c "
import sys, json
raw = sys.stdin.read()
i = raw.find('{')
print(json.JSONDecoder().raw_decode(raw[i:])[0]['data']['id'] if i >= 0 else '')
" <<<"$out" 2>/dev/null)"
  [ -n "$id" ] || { log "Launch reported success but no instance OCID came back; check the console."; return 1; }

  log "GOT IT — instance $id"
  ip="$("${OCI_BASE[@]}" compute instance list-vnics --instance-id "$id" --output json 2>/dev/null \
        | python3 -c "
import sys, json
raw = sys.stdin.read()
i = raw.find('{')
print(json.JSONDecoder().raw_decode(raw[i:])[0]['data'][0]['public-ip'] if i >= 0 else '')
" 2>/dev/null)"

  local keyfile="${SSH_PUBKEY_FILE/#\~/$HOME}"
  keyfile="${keyfile%.pub}"
  cat > "$DIR/SUCCESS.txt" <<EOF
Oracle Cloud A1 instance acquired
=================================
when       : $(date '+%Y-%m-%d %H:%M:%S %Z')
attempts   : $(cat "$STATE" 2>/dev/null || echo '?')
name       : $INSTANCE_NAME
shape      : $SHAPE  ${OCPUS} OCPU / ${MEMORY_GB} GB RAM / ${BOOT_VOLUME_GB} GB boot
region     : $HOME_REGION
image      : $IMAGE_NAME
instance   : $id
public IP  : ${ip:-<not assigned yet — check the console>}

connect:
  ssh -i $keyfile $SSH_LOGIN_USER@${ip:-<ip>}

Note: Oracle can reclaim an Always Free compute instance that sits completely
idle for 7 days. Run something on it.
EOF

  log "public IP ${ip:-unknown} — details in SUCCESS.txt"
  alert "Oracle A1 acquired!" "${ip:-instance created} — see SUCCESS.txt"
  return 0
}

fatal() {
  local kind="$1" out="$2"
  log "FATAL ($kind) — stopping."
  printf '%s\n' "$out" | head -40 >> "$LOG"
  case "$kind" in
    limit)    log "You have already used your Always Free ARM allowance (4 OCPU / 24 GB total). Terminate an existing A1 instance, or lower OCPUS/MEMORY_GB in config.env." ;;
    auth)     log "API key rejected. Regenerate the key in the console and re-run ./setup.sh" ;;
    notfound) log "An OCID is wrong or the resource was deleted. Re-run ./setup.sh to re-resolve." ;;
    unknown)  log "Unrecognised error — full output above." ;;
  esac
  alert "A1 Hunter stopped" "Fatal error: $kind. Check logs/hunt.log"
  exit 1
}

# ---------------------------------------------------------------------------
echo $$ > "$DIR/.hunt.pid"
trap 'rm -f "$DIR/.hunt.pid"' EXIT

read -r -a AD_LIST <<< "$ADS"
attempt=0
backoff=0
ad_index=0
interval=$BASE_INTERVAL   # self-tuning; see config.env
clean=0                   # consecutive non-throttled responses

log "hunt started (pid $$) — ${OCPUS} OCPU / ${MEMORY_GB} GB in $HOME_REGION across ${#AD_LIST[@]} AD(s), starting at ${interval}s cadence"
[ "$MODE" = "once" ] && log "single-attempt mode"

while :; do
  ad="${AD_LIST[$ad_index]}"
  ad_index=$(( (ad_index + 1) % ${#AD_LIST[@]} ))
  attempt=$(( attempt + 1 ))
  echo "$attempt" > "$STATE"

  out="$(launch_once "$ad")"
  rc=$?

  if [ $rc -eq 0 ] && grep -qE '"lifecycle-state":[[:space:]]*"RUNNING"' <<<"$out"; then
    on_success "$out" && exit 0
    kind=unknown
  else
    kind="$(classify "$out")"
  fi

  case "$kind" in
    capacity)
      backoff=0
      clean=$(( clean + 1 ))
      # Earned our way back toward the fast cadence.
      if [ "$clean" -ge "$CLEAN_RUN_TO_SPEED_UP" ] && [ "$interval" -gt "$BASE_INTERVAL" ]; then
        interval=$(( interval - INTERVAL_STEP / 2 ))
        [ "$interval" -lt "$BASE_INTERVAL" ] && interval=$BASE_INTERVAL
        clean=0
        log "cadence eased to ${interval}s after $CLEAN_RUN_TO_SPEED_UP clean attempts"
      fi
      logf "attempt $attempt  $ad  — out of capacity (every ${interval}s)"
      [ "$MODE" = "once" ] && { log "attempt $attempt  $ad  — out of capacity"; log "Config is correct; only capacity is missing. Start the loop with ./ctl.sh start"; exit 0; }
      ;;
    throttle)
      # Oracle is rate-limiting us. Doubling the wait is the only thing that
      # clears it; hammering through a 429 makes the throttle last longer.
      backoff=$(( backoff == 0 ? 120 : backoff * 2 ))
      [ "$backoff" -gt "$MAX_BACKOFF" ] && backoff=$MAX_BACKOFF
      # Sleeping off this one 429 is not enough — the steady cadence itself was
      # too fast for this tenancy, so raise it permanently until clean runs
      # earn it back.
      clean=0
      if [ "$interval" -lt "$MAX_INTERVAL" ]; then
        interval=$(( interval + INTERVAL_STEP ))
        [ "$interval" -gt "$MAX_INTERVAL" ] && interval=$MAX_INTERVAL
      fi
      log "attempt $attempt  $ad  — throttled (429), backing off ${backoff}s; cadence now ${interval}s"
      [ "$MODE" = "once" ] && exit 0
      ;;
    network)
      log "attempt $attempt  $ad  — network unreachable, retrying in ${interval}s"
      [ "$MODE" = "once" ] && exit 0
      ;;
    limit|auth|notfound|unknown)
      [ "$MODE" = "once" ] && { printf '%s\n' "$out" | head -40; }
      fatal "$kind" "$out"
      ;;
  esac

  sleep_for=$(( interval + RANDOM % (JITTER + 1) ))
  [ "$backoff" -gt 0 ] && sleep_for=$backoff
  sleep "$sleep_for"
done
