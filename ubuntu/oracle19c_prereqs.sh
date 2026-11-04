#!/usr/bin/env bash
#
# oracle19c_prereqs.sh
# Prepares an Ubuntu 24.04 node for an Oracle Database 19c install
# (steps 1-7: prereq checks, packages, user/groups, kernel params,
# directories, hostname check, oracle user environment).
#
# Safe to re-run (idempotent).
#
# NOTE: Oracle 19c is not certified on Ubuntu. Use for dev/test only.
#
# Usage:
#   sudo ./oracle19c_prereqs.sh
#   sudo ORACLE_PASSWORD='S0mePassw0rd' ./oracle19c_prereqs.sh   # also sets oracle's password
#
# Optional overrides (environment variables):
#   ORACLE_SID        (default: ORCL)
#   ORACLE_BASE       (default: /u01/app/oracle)
#   ORACLE_HOME       (default: $ORACLE_BASE/product/19.0.0/dbhome_1)
#   ORACLE_DATA_DIR   (default: /u01/oradata)

set -euo pipefail

ORACLE_SID="${ORACLE_SID:-ORCL}"
ORACLE_BASE="${ORACLE_BASE:-/u01/app/oracle}"
ORACLE_HOME="${ORACLE_HOME:-$ORACLE_BASE/product/19.0.0/dbhome_1}"
ORACLE_DATA_DIR="${ORACLE_DATA_DIR:-/u01/oradata}"
# Must match db_inst*.rsp: INVENTORY_LOCATION=###ORACLE_BASE###/oraInventory
ORA_INVENTORY="${ORACLE_BASE}/oraInventory"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# Ensure $1 is a symlink to $2 (create or replace). No-op if already correct.
ensure_symlink() {
  local link=$1 target=$2
  if [[ -L "$link" ]]; then
    [[ "$(readlink -f "$link")" == "$(readlink -f "$target")" ]] && return 0
    ln -sfn "$target" "$link"
  elif [[ -e "$link" ]]; then
    die "Refusing to replace existing path with symlink: $link"
  else
    ln -s "$target" "$link"
  fi
}

# ---------------------------------------------------------------------------
# Step 1: Prerequisite checks
# ---------------------------------------------------------------------------
log "Step 1: Checking prerequisites"

[[ $EUID -eq 0 ]] || die "Run this script as root (use sudo)."

if [[ -r /etc/os-release ]]; then
  . /etc/os-release
  if [[ "${ID:-}" != "ubuntu" || "${VERSION_ID:-}" != "24.04" ]]; then
    warn "Expected Ubuntu 24.04, found ${PRETTY_NAME:-unknown}. Continuing anyway."
  fi
fi

mem_gb=$(awk '/MemTotal/ {printf "%.1f", $2/1024/1024}' /proc/meminfo)
swap_gb=$(awk '/SwapTotal/ {printf "%.1f", $2/1024/1024}' /proc/meminfo)
mkdir -p /u01
free_gb=$(df -BG --output=avail /u01 | tail -1 | tr -dc '0-9')
free_gb=${free_gb:-0}

echo "RAM: ${mem_gb} GB | Swap: ${swap_gb} GB | Free disk on /u01: ${free_gb} GB"

if awk -v m="$mem_gb" 'BEGIN{exit !(m < 2)}'; then
  warn "Less than 2 GB RAM (8 GB recommended)."
fi
if awk -v s="$swap_gb" 'BEGIN{exit !(s < 2)}'; then
  warn "Less than 2 GB swap."
fi
if [[ "$free_gb" -lt 12 ]]; then
  warn "Less than 12 GB free disk space on /u01."
fi

echo
echo "Reminder: download LINUX.X64_193000_db_home.zip from oracle.com manually"
echo "(login required). This script does not download it."

# ---------------------------------------------------------------------------
# Step 2: Install required packages + compatibility symlinks
# ---------------------------------------------------------------------------
log "Step 2: Installing required packages"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y \
  bc binutils libaio1t64 libaio-dev libnsl-dev libnsl2 libstdc++-13-dev \
  ksh make gcc g++ libc6-dev libelf-dev unixodbc-dev unzip net-tools \
  libmotif-common libxtst6 libxi6 libxrender1 libxcb1 libxext6 xauth

log "Creating compatibility symlinks (lib64, libaio.so.1, libnsl.so.1)"
LIBDIR=/usr/lib/x86_64-linux-gnu

# Oracle makefiles hardcode /usr/lib64 (RHEL layout). On Ubuntu the
# multiarch libs live under /usr/lib/x86_64-linux-gnu, so point lib64 there.
# Fixes: cannot find /usr/lib64/libc_nonshared.a (and crti.o, etc.)
if [[ -L /usr/lib64 || ! -e /usr/lib64 ]]; then
  ensure_symlink /usr/lib64 "$LIBDIR"
elif [[ -d /usr/lib64 ]]; then
  warn "/usr/lib64 exists as a real directory; linking individual objects instead."
  for f in libc_nonshared.a libpthread_nonshared.a crt1.o crti.o crtn.o; do
    if [[ -e "$LIBDIR/$f" ]]; then
      if [[ -L "/usr/lib64/$f" || ! -e "/usr/lib64/$f" ]]; then
        ensure_symlink "/usr/lib64/$f" "$LIBDIR/$f"
      fi
    fi
  done
else
  die "/usr/lib64 exists and is neither a directory nor a symlink"
fi

# glibc >= 2.34 may not ship libpthread_nonshared.a; Oracle still links it.
# Replace a broken symlink; leave an existing real file alone.
if [[ -L /usr/lib64/libpthread_nonshared.a && ! -e /usr/lib64/libpthread_nonshared.a ]]; then
  rm -f /usr/lib64/libpthread_nonshared.a
fi
if [[ ! -e /usr/lib64/libpthread_nonshared.a ]]; then
  ar cr /usr/lib64/libpthread_nonshared.a
  echo "Created empty /usr/lib64/libpthread_nonshared.a"
fi

if [[ -e "$LIBDIR/libaio.so.1t64" ]]; then
  ensure_symlink "$LIBDIR/libaio.so.1" "$LIBDIR/libaio.so.1t64"
else
  warn "$LIBDIR/libaio.so.1t64 not found; libaio.so.1 symlink not created."
fi

if [[ -e "$LIBDIR/libnsl.so.2" ]]; then
  ensure_symlink "$LIBDIR/libnsl.so.1" "$LIBDIR/libnsl.so.2"
else
  warn "$LIBDIR/libnsl.so.2 not found; libnsl.so.1 symlink not created."
fi
ldconfig

# ---------------------------------------------------------------------------
# Step 3: Oracle user and groups
# ---------------------------------------------------------------------------
log "Step 3: Creating Oracle groups and user"

getent group oinstall >/dev/null || groupadd -g 54321 oinstall
getent group dba      >/dev/null || groupadd -g 54322 dba
getent group oper     >/dev/null || groupadd -g 54323 oper

if id oracle >/dev/null 2>&1; then
  echo "User 'oracle' already exists; ensuring group membership."
  usermod -g oinstall -G dba,oper oracle
else
  useradd -m -u 54321 -g oinstall -G dba,oper -s /bin/bash oracle
fi

cat > /etc/sudoers.d/80-oracle-user <<'EOF'
# User rules for oracle
oracle ALL=(ALL) NOPASSWD:ALL
EOF
chmod 440 /etc/sudoers.d/80-oracle-user

if [[ -n "${ORACLE_PASSWORD:-}" ]]; then
  echo "oracle:${ORACLE_PASSWORD}" | chpasswd
  echo "Password set for user 'oracle'."
else
  echo "ORACLE_PASSWORD not set; skipping password. Run 'sudo passwd oracle' if you need one."
fi

# ---------------------------------------------------------------------------
# Step 4: Kernel parameters and limits
# ---------------------------------------------------------------------------
log "Step 4: Configuring kernel parameters and limits"

cat > /etc/sysctl.d/99-oracle.conf <<'EOF'
fs.file-max = 6815744
kernel.sem = 250 32000 100 128
kernel.shmmni = 4096
kernel.shmall = 1073741824
kernel.shmmax = 4398046511104
net.core.rmem_default = 262144
net.core.rmem_max = 4194304
net.core.wmem_default = 262144
net.core.wmem_max = 1048576
net.ipv4.ip_local_port_range = 9000 65500
fs.aio-max-nr = 1048576
EOF
sysctl --system >/dev/null

cat > /etc/security/limits.d/oracle.conf <<'EOF'
oracle soft nofile 1024
oracle hard nofile 65536
oracle soft nproc 16384
oracle hard nproc 16384
oracle soft stack 10240
oracle hard stack 32768
EOF

# ---------------------------------------------------------------------------
# Step 5: Directories
# ---------------------------------------------------------------------------
log "Step 5: Creating directories"

mkdir -p "$ORACLE_HOME" "$ORACLE_DATA_DIR"

# Central inventory must be empty for runInstaller (INS-32035). Create it
# fresh when missing; if a previous failed install left contents and the
# inventory was never registered (/etc/oraInst.loc absent), clear it.
if [[ -d "$ORA_INVENTORY" ]] && [[ -n "$(ls -A "$ORA_INVENTORY" 2>/dev/null || true)" ]]; then
  if [[ -f /etc/oraInst.loc ]]; then
    warn "Inventory $ORA_INVENTORY is not empty and /etc/oraInst.loc exists; leaving it alone."
  else
    warn "Removing stale (unregistered) inventory at $ORA_INVENTORY"
    rm -rf "$ORA_INVENTORY"
  fi
fi
mkdir -p "$ORA_INVENTORY"

chown -R oracle:oinstall /u01
chmod -R 775 /u01

# ---------------------------------------------------------------------------
# Step 6: Hostname resolution check
# ---------------------------------------------------------------------------
log "Step 6: Checking hostname resolution"

host_name=$(hostname)
resolved_ip=$(getent hosts "$host_name" | awk '{print $1}' | head -1 || true)

if [[ -z "$resolved_ip" ]]; then
  warn "Hostname '$host_name' does not resolve. Add a line like"
  warn "  <node-ip>  $host_name"
  warn "to /etc/hosts before running the installer."
elif [[ "$resolved_ip" == 127.* ]]; then
  warn "Hostname '$host_name' resolves to loopback ($resolved_ip)."
  warn "Map it to the node's real IP in /etc/hosts to avoid listener problems."
else
  echo "Hostname '$host_name' resolves to $resolved_ip. OK."
fi

# ---------------------------------------------------------------------------
# Step 7: Oracle user environment
# ---------------------------------------------------------------------------
log "Step 7: Setting oracle user environment"

BASHRC=/home/oracle/.bashrc
MARK_START="# >>> oracle 19c environment >>>"
MARK_END="# <<< oracle 19c environment <<<"

# Ensure bashrc exists, then replace any previous managed block
touch "$BASHRC"
if grep -qF "$MARK_START" "$BASHRC"; then
  sed -i "/$MARK_START/,/$MARK_END/d" "$BASHRC"
fi

cat >> "$BASHRC" <<EOF
$MARK_START
export ORACLE_BASE=$ORACLE_BASE
export ORACLE_HOME=$ORACLE_HOME
export ORACLE_SID=$ORACLE_SID
export PATH=\$ORACLE_HOME/bin:\$PATH
export LD_LIBRARY_PATH=\$ORACLE_HOME/lib:/lib:/usr/lib
export CV_ASSUME_DISTID=OEL8.0
export LANG=en_US.UTF-8
$MARK_END
EOF
chown oracle:oinstall "$BASHRC"

# ---------------------------------------------------------------------------
log "Done. Next steps (as the oracle user):"
cat <<EOF
  sudo su - oracle
  unzip -q /path/to/LINUX.X64_193000_db_home.zip -d \$ORACLE_HOME
  cd \$ORACLE_HOME && ./runInstaller
EOF
