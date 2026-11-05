#!/usr/bin/env bash
#
# oracle19c_instantclient.sh
# On RHEL 8:
#   - installs oracle-database-preinstall-19c
#   - copies the invoking sudo user's ~/.ssh/authorized_keys to oracle
#   - installs the latest Oracle Instant Client 19c (basic, sqlplus, devel)
#     published in the OL8 Instant Client yum repo
#
# Safe to re-run (idempotent).
#
# Usage:
#   sudo ./oracle19c_instantclient.sh
#
# Optional overrides:
#   PREINSTALL_RPM_URL   URL for oracle-database-preinstall-19c
#   IC_REPO_BASE         OL8 Instant Client repository base URL

set -euo pipefail

PREINSTALL_RPM_URL="${PREINSTALL_RPM_URL:-https://yum.oracle.com/repo/OracleLinux/OL8/appstream/x86_64/getPackage/oracle-database-preinstall-19c-1.0-2.el8.x86_64.rpm}"
IC_REPO_BASE="${IC_REPO_BASE:-https://yum.oracle.com/repo/OracleLinux/OL8/oracle/instantclient}"
IC_GPG_URL="${IC_GPG_URL:-https://yum.oracle.com/RPM-GPG-KEY-oracle-ol8}"
IC_REPO_FILE=/etc/yum.repos.d/ol8-oracle-instantclient.repo
IC_GPG_FILE=/etc/pki/rpm-gpg/RPM-GPG-KEY-oracle-ol8

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
log "Checking prerequisites"

[[ $EUID -eq 0 ]] || die "Run this script as root (use sudo)."

if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}" in
    rhel|redhat|centos|rocky|almalinux|ol|oraclelinux) ;;
    *) warn "Expected a RHEL 8 family OS, found ${PRETTY_NAME:-unknown}. Continuing anyway." ;;
  esac
  major="${VERSION_ID%%.*}"
  if [[ "${major:-}" != "8" ]]; then
    warn "Expected major version 8, found ${VERSION_ID:-unknown}. Continuing anyway."
  fi
fi

if command -v dnf >/dev/null 2>&1; then
  PKG=dnf
elif command -v yum >/dev/null 2>&1; then
  PKG=yum
else
  die "Neither dnf nor yum found."
fi

$PKG -y install curl

# ---------------------------------------------------------------------------
log "Installing oracle-database-preinstall-19c"

if rpm -q oracle-database-preinstall-19c >/dev/null 2>&1; then
  echo "oracle-database-preinstall-19c already installed."
else
  if $PKG -y install oracle-database-preinstall-19c; then
    echo "Installed from configured repositories."
  else
    warn "Package not in local repos; installing from $PREINSTALL_RPM_URL"
    tmp_rpm=$(mktemp /tmp/oracle-database-preinstall-19c-XXXXXX.rpm)
    curl -fsSL -o "$tmp_rpm" "$PREINSTALL_RPM_URL" \
      || die "Failed to download preinstall RPM from $PREINSTALL_RPM_URL"
    $PKG -y localinstall "$tmp_rpm" \
      || die "Failed to install oracle-database-preinstall-19c"
    rm -f "$tmp_rpm"
  fi
fi

# ---------------------------------------------------------------------------
log "Copying SSH authorized_keys to the oracle account"

if ! id oracle >/dev/null 2>&1; then
  echo "User oracle does not exist; skipping authorized_keys copy."
else
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
      ogroup=oinstall
      getent group oinstall >/dev/null || ogroup=oracle
      install -d -m 700 -o oracle -g "$ogroup" "$dst_ssh"
      if [[ -f "$dst_keys" ]] && cmp -s "$src_keys" "$dst_keys"; then
        echo "oracle authorized_keys already matches $src_user."
      else
        install -m 600 -o oracle -g "$ogroup" "$src_keys" "$dst_keys"
        echo "Copied authorized_keys from $src_user to oracle."
      fi
    fi
  fi
fi

# ---------------------------------------------------------------------------
log "Enabling the OL8 Instant Client repository"

install -d -m 755 /etc/pki/rpm-gpg
if [[ ! -f "$IC_GPG_FILE" ]]; then
  curl -fsSL -o "$IC_GPG_FILE" "$IC_GPG_URL" \
    || die "Failed to download Oracle GPG key from $IC_GPG_URL"
fi
rpm --import "$IC_GPG_FILE" 2>/dev/null || true

cat > "$IC_REPO_FILE" <<EOF
[ol8_oracle_instantclient]
name=Oracle Instant Client for Oracle Linux 8 (\$basearch)
baseurl=${IC_REPO_BASE}/\$basearch/
gpgkey=file://${IC_GPG_FILE}
gpgcheck=1
enabled=1
EOF
chmod 644 "$IC_REPO_FILE"

# ---------------------------------------------------------------------------
log "Selecting the latest Instant Client 19c for RHEL 8"

IC_MINOR=""
while read -r minor; do
  [[ -n "$minor" ]] && IC_MINOR=$minor
done < <(
  $PKG repoquery -q --qf '%{name}' 'oracle-instantclient19.*-basic' 2>/dev/null \
    | sed -n 's/^oracle-instantclient19\.\([0-9][0-9]*\)-basic$/\1/p' \
    | sort -n -u
)

[[ -n "$IC_MINOR" ]] || die "No oracle-instantclient19.*-basic packages found in ${IC_REPO_BASE}."
IC_VER="19.${IC_MINOR}"
IC_HOME="/usr/lib/oracle/${IC_VER}/client64"

echo "Latest Instant Client 19c in the repo: ${IC_VER}"

log "Installing Instant Client ${IC_VER} (basic, sqlplus, devel)"
$PKG -y install \
  "oracle-instantclient${IC_VER}-basic" \
  "oracle-instantclient${IC_VER}-sqlplus" \
  "oracle-instantclient${IC_VER}-devel"

# sqlplus is not on the default PATH. Point at the version just installed.
profile=/etc/profile.d/oracle-instantclient19.sh
cat > "$profile" <<EOF
# Installed by oracle19c_instantclient.sh (${IC_VER})
if [[ -d ${IC_HOME}/bin ]]; then
  case ":\${PATH}:" in
    *":${IC_HOME}/bin:"*) ;;
    *) PATH="${IC_HOME}/bin:\${PATH}" ;;
  esac
  export PATH
fi
EOF
chmod 644 "$profile"
rm -f /etc/profile.d/oracle-instantclient19.3.sh

ldconfig

log "Installed Oracle Instant Client ${IC_VER}"
echo "  Libraries : ${IC_HOME}/lib"
echo "  sqlplus   : ${IC_HOME}/bin/sqlplus"
echo "  SDK       : ${IC_HOME}/sdk"
echo
echo "Open a new login shell so PATH includes sqlplus, then run: sqlplus -V"
