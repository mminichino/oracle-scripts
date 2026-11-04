#!/usr/bin/env bash
#
# oracle19c_prereqs.sh
# Prepares a RHEL 8 (or compatible) node for Oracle Database 19.3 so
# db-install.sh can run: packages/preinstall RPM, oracle user, kernel
# params, directories, and environment.
#
# Safe to re-run (idempotent).
#
# Usage:
#   sudo ./oracle19c_prereqs.sh
#   sudo ORACLE_PASSWORD='S0mePassw0rd' ./oracle19c_prereqs.sh
#
# Optional overrides (environment variables):
#   ORACLE_SID        (default: ORCL)
#   ORACLE_BASE       (default: /u01/app/oracle)
#   ORACLE_HOME       (default: $ORACLE_BASE/product/19.0.0/dbhome_1)
#   ORACLE_DATA_DIR   (default: /u01/oradata)
#   PREINSTALL_RPM_URL  Override URL for oracle-database-preinstall-19c

set -euo pipefail

ORACLE_SID="${ORACLE_SID:-ORCL}"
ORACLE_BASE="${ORACLE_BASE:-/u01/app/oracle}"
ORACLE_HOME="${ORACLE_HOME:-$ORACLE_BASE/product/19.0.0/dbhome_1}"
ORACLE_DATA_DIR="${ORACLE_DATA_DIR:-/u01/oradata}"
# Must match db_inst*.rsp: INVENTORY_LOCATION=###ORACLE_BASE###/oraInventory
ORA_INVENTORY="${ORACLE_BASE}/oraInventory"

# OL8 appstream package used on RHEL 8 / Rocky / Alma when local repos lack it
PREINSTALL_RPM_URL="${PREINSTALL_RPM_URL:-https://yum.oracle.com/repo/OracleLinux/OL8/appstream/x86_64/getPackage/oracle-database-preinstall-19c-1.0-2.el8.x86_64.rpm}"

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
  # RHEL 8 and binary-compatible clones (Rocky, Alma, CentOS Stream 8, OL8)
  case "${ID:-}" in
    rhel|redhat|centos|rocky|almalinux|ol|oraclelinux)
      ;;
    *)
      warn "Expected RHEL 8 family, found ${PRETTY_NAME:-unknown}. Continuing anyway."
      ;;
  esac
  major=${VERSION_ID%%.*}
  if [[ "$major" != "8" ]]; then
    warn "Expected major version 8, found ${VERSION_ID:-unknown}. Continuing anyway."
  fi
else
  warn "/etc/os-release not readable; cannot verify OS."
fi

mem_gb=$(awk '/MemTotal/ {printf "%.1f", $2/1024/1024}' /proc/meminfo)
swap_gb=$(awk '/SwapTotal/ {printf "%.1f", $2/1024/1024}' /proc/meminfo)
mkdir -p /u01
free_gb=$(df -BG --output=avail /u01 2>/dev/null | tail -1 | tr -dc '0-9')
free_gb=${free_gb:-0}

echo "OS: ${PRETTY_NAME:-unknown}"
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
# Step 2: Packages (preinstall RPM + documented deps)
# ---------------------------------------------------------------------------
log "Step 2: Installing Oracle 19c preinstall RPM and dependencies"

if command -v dnf >/dev/null 2>&1; then
  PKG=dnf
elif command -v yum >/dev/null 2>&1; then
  PKG=yum
else
  die "Neither dnf nor yum found"
fi

$PKG -y install curl unzip tar wget >/dev/null

if rpm -q oracle-database-preinstall-19c >/dev/null 2>&1; then
  echo "oracle-database-preinstall-19c already installed."
else
  echo "Installing oracle-database-preinstall-19c..."
  if $PKG -y install oracle-database-preinstall-19c; then
    echo "Installed from configured repositories."
  else
    warn "Package not in local repos; installing from Oracle Linux yum: $PREINSTALL_RPM_URL"
    tmp_rpm=$(mktemp /tmp/oracle-database-preinstall-19c-XXXXXX.rpm)
    curl -fsSL -o "$tmp_rpm" "$PREINSTALL_RPM_URL" \
      || die "Failed to download preinstall RPM from $PREINSTALL_RPM_URL"
    $PKG -y localinstall "$tmp_rpm" \
      || die "Failed to install oracle-database-preinstall-19c"
    rm -f "$tmp_rpm"
  fi
fi

# Documented RHEL 8 package set (safe if already satisfied by the preinstall RPM)
$PKG -y install \
  bc binutils elfutils-libelf elfutils-libelf-devel \
  gcc gcc-c++ glibc glibc-devel ksh \
  libaio libaio-devel libgcc libnsl \
  libX11 libXau libXi libXrender libXtst libxcb \
  libibverbs librdmacm \
  libstdc++ libstdc++-devel \
  make \
  policycoreutils policycoreutils-python-utils \
  smartmontools sysstat \
  net-tools

# ---------------------------------------------------------------------------
# Step 3: Oracle user and groups (preinstall usually creates these)
# ---------------------------------------------------------------------------
log "Step 3: Ensuring Oracle groups and user"

getent group oinstall >/dev/null || groupadd -g 54321 oinstall
getent group dba      >/dev/null || groupadd -g 54322 dba
getent group oper     >/dev/null || groupadd -g 54323 oper

if id oracle >/dev/null 2>&1; then
  echo "User 'oracle' already exists; ensuring group membership."
  # -a preserves groups from the preinstall RPM (backupdba, dgdba, etc.)
  usermod -g oinstall oracle
  usermod -a -G dba,oper oracle
else
  useradd -m -u 54321 -g oinstall -G dba,oper -s /bin/bash oracle
fi

cat > /etc/sudoers.d/80-oracle-user <<'EOF'
# User rules for oracle (db-install.sh runs orainstRoot.sh / root.sh via sudo)
oracle ALL=(ALL) NOPASSWD:ALL
EOF
chmod 440 /etc/sudoers.d/80-oracle-user

if [[ -n "${ORACLE_PASSWORD:-}" ]]; then
  echo "oracle:${ORACLE_PASSWORD}" | chpasswd
  echo "Password set for user 'oracle'."
else
  echo "ORACLE_PASSWORD not set; skipping password. Run 'passwd oracle' if you need one."
fi

# Copy SSH authorized_keys from the user who invoked sudo (idempotent sync).
src_user="${SUDO_USER:-}"
if [[ -z "$src_user" || "$src_user" == "root" ]]; then
  echo "No SUDO_USER (or ran as root); skipping authorized_keys copy."
elif [[ "$src_user" == "oracle" ]]; then
  echo "SUDO_USER is oracle; skipping authorized_keys copy."
else
  src_home=$(getent passwd "$src_user" | cut -d: -f6)
  src_keys="${src_home}/.ssh/authorized_keys"
  dst_ssh=/home/oracle/.ssh
  dst_keys="$dst_ssh/authorized_keys"
  if [[ -z "$src_home" || ! -f "$src_keys" ]]; then
    echo "No authorized_keys for $src_user; skipping."
  else
    install -d -m 700 -o oracle -g oinstall "$dst_ssh"
    if [[ -f "$dst_keys" ]] && cmp -s "$src_keys" "$dst_keys"; then
      echo "oracle authorized_keys already matches $src_user."
    else
      install -m 600 -o oracle -g oinstall "$src_keys" "$dst_keys"
      echo "Copied authorized_keys from $src_user to oracle."
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Step 4: Kernel parameters and limits
# ---------------------------------------------------------------------------
log "Step 4: Verifying kernel parameters and limits"

# Prefer preinstall RPM settings; only add a fallback file if missing.
if [[ ! -f /etc/sysctl.d/99-oracle-database-preinstall-19c.conf ]] \
   && [[ ! -f /etc/sysctl.d/99-oracle.conf ]]; then
  warn "Preinstall sysctl file not found; writing /etc/sysctl.d/99-oracle.conf"
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
fi
sysctl --system >/dev/null

if [[ ! -f /etc/security/limits.d/oracle-database-preinstall-19c.conf ]] \
   && [[ ! -f /etc/security/limits.d/oracle.conf ]]; then
  warn "Preinstall limits file not found; writing /etc/security/limits.d/oracle.conf"
  cat > /etc/security/limits.d/oracle.conf <<'EOF'
oracle soft nofile 1024
oracle hard nofile 65536
oracle soft nproc 16384
oracle hard nproc 16384
oracle soft stack 10240
oracle hard stack 32768
EOF
fi

# ---------------------------------------------------------------------------
# Step 5: Directories
# ---------------------------------------------------------------------------
log "Step 5: Creating directories"

mkdir -p "$ORACLE_HOME" "$ORACLE_DATA_DIR"

# Central inventory must be empty for runInstaller (INS-32035).
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
# Step 7: Oracle user environment (for db-install.sh)
# ---------------------------------------------------------------------------
log "Step 7: Setting oracle user environment"

BASHRC=/home/oracle/.bashrc
MARK_START="# >>> oracle 19c environment >>>"
MARK_END="# <<< oracle 19c environment <<<"

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
export LANG=en_US.UTF-8
$MARK_END
EOF
chown oracle:oinstall "$BASHRC"

# ---------------------------------------------------------------------------
log "Done. Next steps (as the oracle user):"
SCRIPT_ROOT=$(cd "$(dirname "$0")/.." && pwd)
cat <<EOF
  # 1. Unzip 19.3 media into ORACLE_HOME
  sudo su - oracle
  unzip -q /path/to/LINUX.X64_193000_db_home.zip -d \$ORACLE_HOME

  # 2. Silent software install (from this repo)
  cd $SCRIPT_ROOT
  ./db-install.sh -v 193

  # Or with explicit paths:
  # ./db-install.sh -b $ORACLE_BASE -o $ORACLE_HOME -v 193
EOF
