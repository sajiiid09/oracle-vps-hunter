# Oracle Cloud A1 Capacity Hunter

Keeps asking Oracle for a free ARM VM until one is actually available, then grabs it
and shouts at you.

**Target:** `VM.Standard.A1.Flex` — **4 OCPU / 24 GB RAM / 100 GB boot**, Ubuntu 24.04 ARM.
That is the entire Always Free ARM allowance in one instance.

---

## Install

```bash
git clone <your-repo-url> oracle-vps
cd oracle-vps
```

Requires macOS with Homebrew. `setup.sh` installs the OCI CLI itself.

## Setup (one-time, ~5 minutes)

### 1. Create an API key in the Oracle Console

1. Sign in at <https://cloud.oracle.com>
2. Top-right **profile icon** → **My profile**
3. Left sidebar → **API keys** → **Add API key**
4. Leave **Generate API key pair** selected → click **Download private key**
   (lands in `~/Downloads` as something like `oracleidentitycloudservice_you-2026-09-04.pem`)
5. Click **Add**
6. A **Configuration file preview** panel appears — **copy the whole block.**

### 2. Put the two pieces in place

Move the private key and lock it down:

```bash
mkdir -p ~/.oci
mv ~/Downloads/*.pem ~/.oci/oci_api_key.pem
chmod 600 ~/.oci/oci_api_key.pem
```

Create `~/.oci/config` and paste the block you copied, with `key_file` pointing at
the key you just moved:

```ini
[DEFAULT]
user=ocid1.user.oc1..aaaa...
fingerprint=ab:cd:ef:...
tenancy=ocid1.tenancy.oc1..aaaa...
region=ap-mumbai-1
key_file=~/.oci/oci_api_key.pem
```

Then:

```bash
chmod 600 ~/.oci/config
```

That is everything. `setup.sh` reads the tenancy OCID straight out of this file and
discovers the rest (availability domains, image OCID, subnet) through the API.

---

## Running it

```bash
./setup.sh          # once: installs the CLI, seeds config.env, verifies auth, resolves OCIDs
./hunt.sh --once    # sanity check: one attempt, verbose
./ctl.sh start      # begin hunting in the background
```

`./hunt.sh --once` **should** end with `out of capacity`. That is the pass condition —
it proves your key, OCIDs, image, subnet and shape are all correct and the only
missing ingredient is capacity. A `401` or `404` there means the config is wrong.

### Day-to-day

| Command | Does |
|---|---|
| `./ctl.sh start` | starts the loop detached, survives closing the terminal |
| `./ctl.sh stop` | stops it |
| `./ctl.sh status` | running? uptime, attempt count, last log lines |
| `./ctl.sh log` | live tail of `logs/hunt.log` (Ctrl-C to exit the tail — it does **not** stop the hunt) |
| `./hunt.sh --test-alert` | check the success notification actually fires |

### Keep the Mac awake

`start` wraps the loop in `caffeinate -is`, which blocks idle and system sleep.
It cannot beat a closed lid on battery. **Leave it plugged in with the lid open.**

### When it wins

macOS banner + sound (three times), and a `SUCCESS.txt` appears with the public IP
and a ready-to-paste `ssh` line. The loop stops itself.

---

## How it behaves

One `LaunchInstance` call per cycle, rotating across every availability domain in
your home region (Singapore has only one, so there is no rotation there). Each
response is classified:

| Response | Reaction |
|---|---|
| out of capacity | normal — log a line, rotate AD, keep going |
| HTTP 429 throttled | back off 2 → 4 → 8 → 16 → 32 min, reset once it clears |
| network dropped | wait and retry |
| service limit exceeded | **stop** — you already own A1 instances |
| 401 / 404 | **stop** — credentials or an OCID is wrong |
| success | grab IP, alert, write `SUCCESS.txt`, exit |

### The cadence tunes itself

Rate limits differ per tenancy, so the loop discovers the right interval instead of
guessing. It starts at `BASE_INTERVAL` (60s). Every 429 pushes the interval up by
30s — sleeping off one throttle is not enough, since the steady pace itself was too
fast — up to `MAX_INTERVAL` (300s). Three clean attempts in a row walk it back down
15s at a time toward 60s. Cadence changes are logged, so `./ctl.sh log` shows where
it settled.

Going faster than this earns more 429s and makes the hunt *slower*, not quicker.

---

## Tuning

Everything lives in `config.env`. The useful knobs:

```bash
OCPUS=4              # smaller asks fill faster; 2/12 lands sooner than 4/24
MEMORY_GB=24
BOOT_VOLUME_GB=100   # Always Free gives 200 GB total block storage
BASE_INTERVAL=60     # floor of the self-tuning cadence
MAX_INTERVAL=300     # ceiling it backs off to under throttling
```

After changing `IMAGE_OS`, `IMAGE_OS_VERSION` or anything OCID-related, re-run
`./setup.sh`.

## Expectations

Free Tier accounts are served ARM capacity *after* paying accounts. This can take
hours or weeks depending on how saturated your home region is, and asking for the
full 4 OCPU / 24 GB is harder to fill than a smaller slice — a 4-core hole has to
open up all at once. If it drags on, dropping to `OCPUS=2` / `MEMORY_GB=12` in
`config.env` will land something much sooner, and you can claim the other half later.

Always Free resources exist **only in your home region**; the script cannot hunt
elsewhere.

---

## What is and isn't in this repo

Committed: the five scripts, `config.env.example`, this README. Nothing else.

Everything identifying is generated locally at runtime and gitignored:

| Not committed | Why |
|---|---|
| `config.env` | your working copy; may hold tenancy/compartment OCIDs |
| `resolved.env` | real tenancy, image and subnet OCIDs |
| `metadata.json` | your SSH public key |
| `SUCCESS.txt` | the acquired instance's OCID and public IP |
| `logs/` | attempt history |
| `*.pem`, `*.key`, `.oci/`, `.env` | credentials, defensively |

Your API private key and `~/.oci/config` live outside the project directory
entirely and are never touched by git.

Before your first push, confirm for yourself:

```bash
git status --short          # only scripts, config.env.example, README.md
git ls-files                # same list — nothing generated
```
