#!/usr/bin/env bash
#
# oracle19c_instantclient.sh
# Installs Oracle Instant Client 19.3 (basic, sqlplus, devel) on RHEL 8.
#
# The OL8 Instant Client yum repo no longer publishes 19.3 (it starts at 19.9),
# so this downloads the 19.3 RPMs from Oracle's public otn_software site.
#
# Safe to re-run (idempotent).
#
# Usage:
#   sudo ./oracle19c_instantclient.sh
#
# Optional overrides:
#   IC_URL_BASE   Directory URL that contains the three 19.3 RPMs
#                 (default: Oracle otn_software instantclient/193000)

set -euo pipefail

IC_VER="19.3"
IC_REL="19.3.0.0.0-1"
IC_URL_BASE="${IC_URL_BASE:-https://download.oracle.com/otn_software/linux/instantclient/193000}"
IC_HOME="/usr/lib/oracle/${IC_VER}/client64"
PKGS=(basic sqlplus devel)

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

rpm_name() {
  echo "oracle-instantclient${IC_VER}-$1-${IC_REL}.x86_64.rpm"
}

pkg_installed() {
  rpm -q "oracle-instantclient${IC_VER}-$1" >/dev/null 2>&1
}

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

log "Installing OS dependencies (libaio, libnsl)"
$PKG -y install libaio libnsl curl

missing=()
for p in "${PKGS[@]}"; do
  if pkg_installed "$p"; then
    echo "oracle-instantclient${IC_VER}-${p} already installed."
  else
    missing+=("$p")
  fi
done

if [[ ${#missing[@]} -eq 0 ]]; then
  echo "Instant Client ${IC_VER} basic, sqlplus, and devel are already installed."
else
  work=$(mktemp -d /tmp/instantclient19.3.XXXXXX)
  trap 'rm -rf "$work"' EXIT

  log "Downloading Instant Client ${IC_VER} RPMs"
  rpms=()
  for p in "${missing[@]}"; do
    name=$(rpm_name "$p")
    echo "  $name"
    curl -fL --retry 3 --retry-delay 2 -o "${work}/${name}" "${IC_URL_BASE}/${name}" \
      || die "Failed to download ${IC_URL_BASE}/${name}"
    rpms+=("${work}/${name}")
  done

  log "Installing RPMs"
  if ! $PKG -y localinstall "${rpms[@]}"; then
    warn "Install with GPG check failed; retrying with --nogpgcheck."
    warn "The public 19.3 Instant Client RPMs are not signed for the OL8 key."
    $PKG -y localinstall --nogpgcheck "${rpms[@]}" \
      || die "Failed to install Instant Client ${IC_VER} RPMs."
  fi

  rm -rf "$work"
  trap - EXIT
fi

# The basic RPM registers its libraries with ldconfig. sqlplus is not on PATH.
profile=/etc/profile.d/oracle-instantclient19.3.sh
cat > "$profile" <<EOF
# Installed by oracle19c_instantclient.sh
if [[ -d ${IC_HOME}/bin ]]; then
  case ":\${PATH}:" in
    *":${IC_HOME}/bin:"*) ;;
    *) PATH="${IC_HOME}/bin:\${PATH}" ;;
  esac
  export PATH
fi
EOF
chmod 644 "$profile"

ldconfig

log "Installed Oracle Instant Client ${IC_VER}"
echo "  Libraries : ${IC_HOME}/lib"
echo "  sqlplus   : ${IC_HOME}/bin/sqlplus"
echo "  SDK       : ${IC_HOME}/sdk"
echo
echo "Open a new login shell so PATH includes sqlplus, then run: sqlplus -V"
