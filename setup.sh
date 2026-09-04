#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# One-time preflight for the A1 capacity hunter.
# Installs the OCI CLI, verifies auth, and resolves every OCID the loop needs.
# Safe to re-run: it re-resolves and rewrites resolved.env.
# ---------------------------------------------------------------------------
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

# config.env is gitignored and machine-local; seed it from the tracked template
# on a fresh clone.
if [ ! -f ./config.env ]; then
  cp ./config.env.example ./config.env
  echo "created config.env from config.env.example"
fi
source ./config.env

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '\033[32m  ok\033[0m  %s\n' "$*"; }
warn() { printf '\033[33m  !!\033[0m  %s\n' "$*"; }
die()  { printf '\033[31m FAIL\033[0m  %s\n' "$*" >&2; exit 1; }

# Pull a value out of OCI CLI JSON without needing jq.
# The CLI sprays Python SyntaxWarnings and pagination notices around its output,
# so skip to the first brace and decode just the JSON object that follows.
jget() { python3 -c "
import sys, json
raw = sys.stdin.read()
i = raw.find('{')
d = json.JSONDecoder().raw_decode(raw[i:])[0] if i >= 0 else {}
print($1)
" 2>/dev/null; }

# ---------------------------------------------------------------------------
bold "1/6  OCI CLI"
# ---------------------------------------------------------------------------
if ! command -v oci >/dev/null 2>&1; then
  # Homebrew's formula bundles its own Python, which sidesteps the fact that
  # Oracle's install script does not support the Python 3.14 on this machine.
  command -v brew >/dev/null 2>&1 || die "Homebrew not found; install it first."
  echo "  installing oci-cli via Homebrew (this takes a few minutes)..."
  brew install oci-cli || die "brew install oci-cli failed"
fi
ok "$(oci --version 2>/dev/null | head -1) at $(command -v oci)"

# ---------------------------------------------------------------------------
bold "2/6  Credentials"
# ---------------------------------------------------------------------------
[ -f "$HOME/.oci/config" ] || die "No ~/.oci/config. See README.md step 1."

KEY_FILE="$(awk -v p="[$OCI_PROFILE]" '
  $0==p {inp=1; next} /^\[/ {inp=0}
  inp && /^ *key_file *=/ {sub(/^ *key_file *= */,""); print; exit}' "$HOME/.oci/config")"
KEY_FILE="${KEY_FILE/#\~/$HOME}"
[ -n "$KEY_FILE" ] && [ -f "$KEY_FILE" ] || die "key_file in ~/.oci/config points at a missing file: '$KEY_FILE'"

PERMS="$(stat -f '%Lp' "$KEY_FILE")"
if [ "$PERMS" != "600" ]; then
  chmod 600 "$KEY_FILE" && ok "tightened $KEY_FILE to 600 (was $PERMS)"
fi
ok "private key $KEY_FILE"

# Fill tenancy from the config file if config.env left it blank.
if [ -z "${TENANCY_OCID:-}" ]; then
  TENANCY_OCID="$(awk -v p="[$OCI_PROFILE]" '
    $0==p {inp=1; next} /^\[/ {inp=0}
    inp && /^ *tenancy *=/ {sub(/^ *tenancy *= */,""); print; exit}' "$HOME/.oci/config")"
fi
[ -n "$TENANCY_OCID" ] || die "TENANCY_OCID is empty and ~/.oci/config has no tenancy line."
COMPARTMENT_OCID="${COMPARTMENT_OCID:-$TENANCY_OCID}"
[ -n "$COMPARTMENT_OCID" ] || COMPARTMENT_OCID="$TENANCY_OCID"
ok "tenancy     $TENANCY_OCID"
ok "compartment $COMPARTMENT_OCID"

# ---------------------------------------------------------------------------
bold "3/6  Auth smoke test"
# ---------------------------------------------------------------------------
# This is the cheapest call that proves key + fingerprint + OCIDs are all good.
# Failing here means the loop would have failed forever, so we stop now.
REGION_JSON="$(oci iam region-subscription list --profile "$OCI_PROFILE" --output json 2>&1)"
if [ $? -ne 0 ] || ! grep -q '"data"' <<<"$REGION_JSON"; then
  echo "$REGION_JSON" | head -20 >&2
  die "Authentication failed. Re-check the API key and OCIDs (README.md step 1)."
fi
HOME_REGION="$(printf '%s' "$REGION_JSON" | jget "[r['region-name'] for r in d['data'] if r['is-home-region']][0]")"
[ -n "$HOME_REGION" ] || die "Could not determine home region."
ok "authenticated; home region is $HOME_REGION"
warn "Always Free resources exist ONLY in $HOME_REGION. The hunt cannot cross regions."

# ---------------------------------------------------------------------------
bold "4/6  Availability domains"
# ---------------------------------------------------------------------------
AD_JSON="$(oci iam availability-domain list --compartment-id "$TENANCY_OCID" \
            --profile "$OCI_PROFILE" --region "$HOME_REGION" --output json 2>/dev/null)"
ADS="$(printf '%s' "$AD_JSON" | jget "' '.join(a['name'] for a in d['data'])")"
[ -n "$ADS" ] || { echo "$AD_JSON" | head -20 >&2; die "Could not list availability domains."; }
for a in $ADS; do ok "AD $a"; done

# ---------------------------------------------------------------------------
bold "5/6  ARM image"
# ---------------------------------------------------------------------------
# --shape guarantees an aarch64 build; without it you get x86 images that
# launch fine and then never boot on A1 hardware.
IMG_JSON="$(oci compute image list --compartment-id "$COMPARTMENT_OCID" \
             --shape "$SHAPE" \
             --operating-system "$IMAGE_OS" \
             --operating-system-version "$IMAGE_OS_VERSION" \
             --sort-by TIMECREATED --sort-order DESC --limit 1 \
             --profile "$OCI_PROFILE" --region "$HOME_REGION" --output json 2>/dev/null)"
IMAGE_OCID="$(printf '%s' "$IMG_JSON" | jget "d['data'][0]['id']")"
IMAGE_NAME="$(printf '%s' "$IMG_JSON" | jget "d['data'][0]['display-name']")"
[ -n "$IMAGE_OCID" ] || { echo "$IMG_JSON" | head -20 >&2; die "No $IMAGE_OS $IMAGE_OS_VERSION image found for $SHAPE."; }
ok "$IMAGE_NAME"
ok "$IMAGE_OCID"

# ---------------------------------------------------------------------------
bold "6/6  Networking"
# ---------------------------------------------------------------------------
SUBNET_JSON="$(oci network subnet list --compartment-id "$COMPARTMENT_OCID" \
                --profile "$OCI_PROFILE" --region "$HOME_REGION" --output json 2>/dev/null)"
SUBNET_OCID="$(printf '%s' "$SUBNET_JSON" | jget "[s['id'] for s in d.get('data') or [] if not s['prohibit-public-ip-on-vnic']][0]")"

if [ -n "$SUBNET_OCID" ]; then
  SUBNET_NAME="$(printf '%s' "$SUBNET_JSON" | jget "[s['display-name'] for s in d['data'] if s['id']=='$SUBNET_OCID'][0]")"
  ok "reusing public subnet '$SUBNET_NAME'"
  ok "$SUBNET_OCID"
else
  warn "No public subnet found in this compartment."
  echo
  echo "  To launch a reachable instance I need to create, in your Oracle account:"
  echo "    - a VCN            10.0.0.0/16   (named a1-hunter-vcn)"
  echo "    - an internet gateway"
  echo "    - a route rule     0.0.0.0/0 -> that gateway"
  echo "    - a public subnet  10.0.0.0/24"
  echo "    - an ingress rule allowing TCP 22 from 0.0.0.0/0 (SSH)"
  echo
  echo "  These are free and can be deleted later. Nothing else in your account is touched."
  read -r -p "  Create them now? [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]] || die "Declined. Create a public subnet yourself, then re-run ./setup.sh"

  OCI="oci --profile $OCI_PROFILE --region $HOME_REGION"

  echo "  creating VCN..."
  VCN_OCID="$($OCI network vcn create --compartment-id "$COMPARTMENT_OCID" \
      --cidr-blocks '["10.0.0.0/16"]' --display-name a1-hunter-vcn \
      --dns-label a1hunter --wait-for-state AVAILABLE --output json 2>&1 | jget "d['data']['id']")"
  [ -n "$VCN_OCID" ] || die "VCN creation failed."
  ok "vcn $VCN_OCID"

  echo "  creating internet gateway..."
  IGW_OCID="$($OCI network internet-gateway create --compartment-id "$COMPARTMENT_OCID" \
      --vcn-id "$VCN_OCID" --is-enabled true --display-name a1-hunter-igw \
      --wait-for-state AVAILABLE --output json 2>&1 | jget "d['data']['id']")"
  [ -n "$IGW_OCID" ] || die "Internet gateway creation failed."
  ok "igw $IGW_OCID"

  echo "  routing 0.0.0.0/0 through the gateway..."
  RT_OCID="$($OCI network route-table list --compartment-id "$COMPARTMENT_OCID" \
      --vcn-id "$VCN_OCID" --output json 2>&1 | jget "d['data'][0]['id']")"
  $OCI network route-table update --rt-id "$RT_OCID" --force \
      --route-rules "[{\"destination\":\"0.0.0.0/0\",\"destinationType\":\"CIDR_BLOCK\",\"networkEntityId\":\"$IGW_OCID\"}]" \
      >/dev/null 2>&1 || die "Route table update failed."
  ok "route table $RT_OCID"

  echo "  opening TCP 22..."
  SL_OCID="$($OCI network security-list list --compartment-id "$COMPARTMENT_OCID" \
      --vcn-id "$VCN_OCID" --output json 2>&1 | jget "d['data'][0]['id']")"
  $OCI network security-list update --security-list-id "$SL_OCID" --force \
      --egress-security-rules '[{"destination":"0.0.0.0/0","protocol":"all","isStateless":false}]' \
      --ingress-security-rules '[{"source":"0.0.0.0/0","protocol":"6","isStateless":false,"tcpOptions":{"destinationPortRange":{"min":22,"max":22}}}]' \
      >/dev/null 2>&1 || die "Security list update failed."
  ok "security list $SL_OCID"

  echo "  creating public subnet..."
  SUBNET_OCID="$($OCI network subnet create --compartment-id "$COMPARTMENT_OCID" \
      --vcn-id "$VCN_OCID" --cidr-block 10.0.0.0/24 --display-name a1-hunter-subnet \
      --dns-label a1sub --prohibit-public-ip-on-vnic false \
      --wait-for-state AVAILABLE --output json 2>&1 | jget "d['data']['id']")"
  [ -n "$SUBNET_OCID" ] || die "Subnet creation failed."
  ok "subnet $SUBNET_OCID"
fi

# ---------------------------------------------------------------------------
# Instance metadata (SSH key) — written to a file so the JSON never has to
# survive a trip through shell quoting.
# ---------------------------------------------------------------------------
PUBKEY_PATH="${SSH_PUBKEY_FILE/#\~/$HOME}"
[ -f "$PUBKEY_PATH" ] || die "SSH public key not found at $PUBKEY_PATH"
python3 -c "
import json,sys
key=open('$PUBKEY_PATH').read().strip()
json.dump({'ssh_authorized_keys':key}, open('$DIR/metadata.json','w'))
" || die "Could not write metadata.json"
ok "ssh key $PUBKEY_PATH"

# ---------------------------------------------------------------------------
cat > "$DIR/resolved.env" <<EOF
# Generated by setup.sh on $(date '+%Y-%m-%d %H:%M:%S'). Do not edit by hand.
TENANCY_OCID="$TENANCY_OCID"
COMPARTMENT_OCID="$COMPARTMENT_OCID"
HOME_REGION="$HOME_REGION"
ADS="$ADS"
IMAGE_OCID="$IMAGE_OCID"
IMAGE_NAME="$IMAGE_NAME"
SUBNET_OCID="$SUBNET_OCID"
METADATA_FILE="$DIR/metadata.json"
EOF

echo
bold "Ready."
echo "  region      $HOME_REGION"
echo "  ADs         $ADS"
echo "  shape       $SHAPE  ${OCPUS} OCPU / ${MEMORY_GB} GB / ${BOOT_VOLUME_GB} GB boot"
echo "  image       $IMAGE_NAME"
echo "  subnet      $SUBNET_OCID"
echo
echo "  Next:  ./hunt.sh --once     (expect 'out of capacity' — that means it works)"
echo "  Then:  ./ctl.sh start"
