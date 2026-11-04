#!/usr/bin/env bash
#
# oracle19c_prereqs.sh
# Prepares an Ubuntu 24.04 node for an Oracle Database 19c install
# (steps 1-7: prereq checks, packages, user/groups, kernel params,
# directories, hostname check, oracle user environment).
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
ORA_INVENTORY="/u01/app/oraInventory"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

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

echo "RAM: ${mem_gb} GB | Swap: ${swap_gb} GB | Free disk on /u01: ${free_gb} GB"

awk -v m="$mem_gb" 'BEGIN{exit !(m < 2)}' && warn "Less than 2 GB RAM (8 GB recommended)."
awk -v s="$swap_gb" 'BEGIN{exit !(s < 2)}' && warn "Less than 2 GB swap."
[[ "$free_gb" -lt 12 ]] && warn "Less than 12 GB free disk space on /u01."

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

log "Creating compatibility symlinks (libaio.so.1, libnsl.so.1)"
LIBDIR=/usr/lib/x86_64-linux-gnu

if [[ -e "$LIBDIR/libaio.so.1t64" ]]; then
  ln -sf "$LIBDIR/libaio.so.1t64" "$LIBDIR/libaio.so.1"
else
  warn "$LIBDIR/libaio.so.1t64 not found; libaio.so.1 symlink not created."
fi

if [[ -e "$LIBDIR/libnsl.so.2" ]]; then
  ln -sf "$LIBDIR/libnsl.so.2" "$LIBDIR/libnsl.so.1"
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

mkdir -p "$ORACLE_HOME" "$ORA_INVENTORY" "$ORACLE_DATA_DIR"
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

# Remove any previous block so the script is safe to re-run
if grep -qF "$MARK_START" "$BASHRC" 2>/dev/null; then
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
