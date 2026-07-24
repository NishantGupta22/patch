# cat schedule_patch.sh
#!/bin/bash
#
# PatchWarden Patch Scheduler (hardened)
#
set -euo pipefail

INVENTORY="/opt/patch-manager/ansible/host.ini"
PLAYBOOK="/opt/patch-manager/ansible/apply_patches.yml"
LOG_FILE="/var/log/patchwarden/scheduler.log"

log() {
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$(whoami)] $*" >> "$LOG_FILE" 2>/dev/null || true
}

echo
echo "========================================"
echo " ITSS Patch Scheduler"
echo "========================================"

# ---- Host input & validation ----------------------------------------------
read -rp "Enter Host IP: " HOST

# Strict IPv4 format check (prevents injection via shell metacharacters,
# and rejects hostnames/garbage if you specifically expect IPs).
if [[ ! "$HOST" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo "ERROR: Invalid IP address format"
    exit 1
fi
# Validate each octet is 0-255
IFS='.' read -r o1 o2 o3 o4 <<< "$HOST"
for octet in "$o1" "$o2" "$o3" "$o4"; do
    if (( octet > 255 )); then
        echo "ERROR: Invalid IP address (octet out of range)"
        exit 1
    fi
done

# Anchor the match to avoid partial matches (e.g. 10.0.0.1 matching 10.0.0.100)
if ! grep -E "(^|[[:space:]])${HOST}([[:space:]]|$)" "$INVENTORY" >/dev/null; then
    echo "ERROR: Host not found in host.ini"
    exit 1
fi
echo "✓ Host exists in inventory"

# ---- Connectivity check -----------------------------------------------------
if ! ansible "$HOST" -i "$INVENTORY" -m ping >/dev/null 2>&1; then
    echo "ERROR: Host unreachable"
    exit 1
fi
echo "✓ Host reachable"

# ---- Package input & validation ---------------------------------------------
read -rp "Enter Package Name: " PACKAGE

# Allow only safe package-name characters: letters, digits, dot, dash, underscore, plus
if [[ ! "$PACKAGE" =~ ^[A-Za-z0-9._+-]+$ ]]; then
    echo "ERROR: Invalid package name (allowed characters: letters, digits, . _ + -)"
    exit 1
fi

echo "Detecting target OS..."

OS_FAMILY=$(ansible "$HOST" -i "$INVENTORY" \
-m setup \
-a "filter=ansible_os_family" 2>/dev/null | \
grep ansible_os_family | \
awk -F'"' '{print $4}')

if [[ -z "$OS_FAMILY" ]]; then
    echo "ERROR: Could not determine target OS"
    exit 1
fi

echo "OS Family: $OS_FAMILY"

echo "Checking package on target host..."

if [[ "$OS_FAMILY" == "Debian" ]]; then

    if ! ansible "$HOST" -i "$INVENTORY" \
        -m shell \
        -a "dpkg-query -W $PACKAGE >/dev/null 2>&1" \
        -o >/dev/null 2>&1
    then
        echo "ERROR: Package not installed"
        exit 1
    fi

elif [[ "$OS_FAMILY" == "RedHat" ]]; then

    if ! ansible "$HOST" -i "$INVENTORY" \
        -m command \
        -a "rpm -q -- $PACKAGE" \
        -o >/dev/null 2>&1
    then
        echo "ERROR: Package not installed"
        exit 1
    fi

else

    echo "ERROR: Unsupported OS Family: $OS_FAMILY"
    exit 1

fi

echo "✓ Package installed"

# ---- Date/time input & validation --------------------------------------------
read -rp "Enter Patch Date (YYYY-MM-DD): " PATCH_DATE
if [[ ! "$PATCH_DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    echo "ERROR: Date must be in YYYY-MM-DD format"
    exit 1
fi

read -rp "Enter Patch Time (HH:MM AM/PM): " PATCH_TIME
if [[ ! "$PATCH_TIME" =~ ^(0?[1-9]|1[0-2]):[0-5][0-9][[:space:]]?(AM|PM|am|pm)$ ]]; then
    echo "ERROR: Time must be in HH:MM AM/PM format"
    exit 1
fi

SCHEDULE="${PATCH_DATE} ${PATCH_TIME}"

# Confirm it's a real, parseable calendar date/time AND not in the past.
# NOTE: we use `date -d` here purely for validation/epoch math. `at`'s own
# parser does NOT reliably accept the same "YYYY-MM-DD HH:MM AM/PM" string
# (it expects time before date, and is picky/version-dependent about
# YYYY-MM-DD). To avoid that mismatch, we convert to at's unambiguous
# numeric timestamp format (-t [[CC]YY]MMDDhhmm[.ss]) below instead of
# passing the human-readable string to `at` directly.
if ! PARSED_EPOCH=$(date -d "$SCHEDULE" +%s 2>/dev/null); then
    echo "ERROR: Invalid Date/Time"
    exit 1
fi
NOW_EPOCH=$(date +%s)
if (( PARSED_EPOCH <= NOW_EPOCH )); then
    echo "ERROR: Scheduled time must be in the future"
    exit 1
fi

# Build the unambiguous timestamp `at -t` expects: YYYYMMDDhhmm.ss (24h time)
AT_TIMESTAMP=$(date -d "@$PARSED_EPOCH" +%Y%m%d%H%M.%S)

# ---- Build job file safely ---------------------------------------------------
# Use mktemp to avoid predictable filenames / TOCTOU race, restrict permissions
# from creation time (umask), and avoid embedding raw user input as shell text
# by passing values through a safely-quoted heredoc with single-quoted EOF
# substitution done via printf %q.
umask 077
JOB_FILE=$(mktemp /tmp/patchwarden_job.XXXXXXXXXX) || { echo "ERROR: could not create job file"; exit 1; }

SAFE_HOST=$(printf '%q' "$HOST")
SAFE_PACKAGE=$(printf '%q' "$PACKAGE")
SAFE_INVENTORY=$(printf '%q' "$INVENTORY")
SAFE_PLAYBOOK=$(printf '%q' "$PLAYBOOK")

cat > "$JOB_FILE" <<EOF
#!/bin/bash
set -euo pipefail
ansible-playbook \\
  $SAFE_PLAYBOOK \\
  -i $SAFE_INVENTORY \\
  -e target_hosts=$SAFE_HOST \\
  -e '{"patches_to_apply":["'"$PACKAGE"'"]}'
EOF
chmod 700 "$JOB_FILE"

# Schedule it using -t with the numeric timestamp (unambiguous across at(1)
# implementations/locales, unlike free-form "YYYY-MM-DD HH:MM AM/PM" strings).
if ! echo "$JOB_FILE" | at -t "$AT_TIMESTAMP" 2>/tmp/at_err_$$; then
    echo "ERROR: Failed to schedule job via 'at'"
    cat /tmp/at_err_$$ 2>/dev/null
    rm -f /tmp/at_err_$$
    rm -f "$JOB_FILE"
    exit 1
fi
rm -f /tmp/at_err_$$

log "Scheduled patch job: host=$HOST package=$PACKAGE schedule='$SCHEDULE' job_file=$JOB_FILE"

echo
echo "========================================"
echo "PATCH SCHEDULED SUCCESSFULLY"
echo "========================================"
echo "Host      : $HOST"
echo "Package   : $PACKAGE"
echo "Date      : $PATCH_DATE"
echo "Time      : $PATCH_TIME"
echo
