#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# Production server disaster-recovery backup.
# Auto-detects OS, installs missing tools, loads local backup.conf, 
# and prompts interactively for usernames (with Enter for default) and passwords.
# Run as root.

SCRIPT_VERSION="1.7.0"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
CONFIG_FILE="${CONFIG_FILE:-${SCRIPT_DIR}/backup.conf}"

log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
warn(){ log "WARNING: $*"; ERRORS=$((ERRORS+1)); }
die(){ log "FATAL: $*"; exit 1; }
need_root(){ [[ $EUID -eq 0 ]] || die "Run as root."; }
cmd(){ command -v "$1" >/dev/null 2>&1; }

need_root

# Load local config if present
if [[ -f "$CONFIG_FILE" ]]; then
  log "Loading configuration from: $CONFIG_FILE"
  # shellcheck source=/dev/null
  . "$CONFIG_FILE"
else
  log "No config file found at $CONFIG_FILE (using defaults/prompts)"
fi
BACKUP_USER="${SUDO_USER:-$USER}"
BACKUP_HOME="$(getent passwd "$BACKUP_USER" | cut -d: -f6)"

[[ -n "$BACKUP_HOME" && -d "$BACKUP_HOME" ]] ||
    die "Could not determine home directory for user: $BACKUP_USER"

BACKUP_ROOT="${BACKUP_ROOT:-$BACKUP_HOME/server-backups}"
BACKUP_ROOT="${BACKUP_ROOT%/}"

RETENTION="${RETENTION:-8}"

STAMP="$(date +%Y-%m-%d_%H%M%S)"
HOST="$(hostname -s 2>/dev/null || hostname)"

WORK="${BACKUP_ROOT}/.work-${HOST}-${STAMP}"
TREE="${WORK}/server-backup"
ARCHIVE="${BACKUP_ROOT}/server-backup-${HOST}-${STAMP}.tar.gz"
LOG="${WORK}/backup.log"
ERRORS=0

mkdir -p "$TREE" "$BACKUP_ROOT"

exec > >(tee -a "$LOG") 2>&1
copy_if_exists() {
  local src="$1" dst="$2"
  [[ -e "$src" ]] || return 0
  mkdir -p "$(dirname "$TREE/$dst")"
  cp -a "$src" "$TREE/$dst"
}
# ---------- Package repository / signing-key backup ----------
backup_package_sources_and_keys() {
  mkdir -p "$TREE/APT" "$TREE/APT/sources.list.d" "$TREE/APT/keyrings" \
           "$TREE/APT/trusted.gpg.d" "$TREE/APT/preferences.d" \
           "$TREE/APT/postgresql-common-pgdg"

  # Capture the exact repository definitions used by APT. This is important
  # for vendor repositories such as Microsoft SQL Server, PostgreSQL PGDG,
  # MongoDB, Nginx and CrowdSec, where the distro repository may not contain
  # the same major/minor version later.
  copy_if_exists /etc/apt/sources.list APT/sources.list
  if [[ -d /etc/apt/sources.list.d ]]; then
    cp -a /etc/apt/sources.list.d/. "$TREE/APT/sources.list.d/" 2>/dev/null || true
  fi
  if [[ -d /etc/apt/keyrings ]]; then
    cp -a /etc/apt/keyrings/. "$TREE/APT/keyrings/" 2>/dev/null || true
  fi
  if [[ -d /usr/share/keyrings ]]; then
    # Keep vendor/distribution signing key files available for restore.
    cp -a /usr/share/keyrings/. "$TREE/APT/keyrings/" 2>/dev/null || true
  fi
  # PGDG stores its signing key outside the normal APT keyring directories.
  # Preserve it separately so PostgreSQL repositories can be used before
  # postgresql-common itself is installed during disaster recovery.
  if [[ -d /usr/share/postgresql-common/pgdg ]]; then
    cp -a /usr/share/postgresql-common/pgdg/. \
      "$TREE/APT/postgresql-common-pgdg/" 2>/dev/null || true
  fi
  if [[ -d /etc/apt/trusted.gpg.d ]]; then
    cp -a /etc/apt/trusted.gpg.d/. "$TREE/APT/trusted.gpg.d/" 2>/dev/null || true
  fi
  if [[ -f /etc/apt/trusted.gpg ]]; then
    cp -a /etc/apt/trusted.gpg "$TREE/APT/trusted.gpg"
  fi
  if [[ -d /etc/apt/preferences.d ]]; then
    cp -a /etc/apt/preferences.d/. "$TREE/APT/preferences.d/" 2>/dev/null || true
  fi
  # Intentionally do NOT copy /etc/apt/auth.conf or auth.conf.d: those files
  # may contain private repository credentials. Repository definitions and
  # signing keys are sufficient for normal public vendor repositories.

  # Human-readable and machine-readable repository inventory.
  {
    echo "=== APT SOURCES ==="
    [[ -f /etc/apt/sources.list ]] && cat /etc/apt/sources.list
    find /etc/apt/sources.list.d -maxdepth 1 -type f \
      \( -name '*.list' -o -name '*.sources' \) -print -exec sh -c 'echo; echo "### $1"; cat "$1"' _ {} \; 2>/dev/null || true
    echo
    echo "=== APT POLICY FOR IMPORTANT PACKAGES ==="
    for pkg in postgresql postgresql-common postgresql-client mssql-server mongodb-org mongodb-org-server mongodb-database-tools nginx crowdsec crowdsec-firewall-bouncer; do
      echo
      echo "### $pkg"
      apt-cache policy "$pkg" 2>/dev/null || true
    done
  } > "$TREE/APT/repositories-and-package-policy.txt"

  # Export the complete legacy trusted keyring too, when apt-key exists.
  # Do not fail the backup on newer systems where apt-key has been removed.
  if cmd apt-key; then
    apt-key exportall > "$TREE/APT/apt-key-exportall.gpg" 2>/dev/null || true
  fi

  # List all key files so restore can verify that the expected signing keys exist.
  find "$TREE/APT/keyrings" "$TREE/APT/trusted.gpg.d" -maxdepth 1 -type f \
    -printf '%P\t%p\n' 2>/dev/null | sort > "$TREE/APT/key-files.txt" || true

  # Capture exact versions of packages that are important for deterministic
  # disaster recovery. This includes versioned PostgreSQL packages (for
  # example postgresql-18), MongoDB, MSSQL, Nginx, CrowdSec and their tools.
  if cmd dpkg-query; then
    dpkg-query -W -f='${Package}\t${Version}\n' 2>/dev/null | awk -F '\t' '
      $1 ~ /^(postgresql(-[0-9]+)?|postgresql-client(-[0-9]+)?|postgresql-common|mssql-server|mssql-tools18|mongodb-org($|-)|mongodb-database-tools|nginx($|-)|crowdsec($|-)|crowdsec-firewall-bouncer|fail2ban($|-)|docker(-ce)?($|-)|docker.io($|-)|containerd($|-)|runc($|-)|curl|ca-certificates|gnupg|rsync)$/ {print}
    ' | sort > "$TREE/APT/exact-important-packages.txt" || true
  fi

  # Record checksums for source/key files. This makes accidental corruption
  # or a changed key obvious before restore.
  find "$TREE/APT" -type f \
    \( -name '*.list' -o -name '*.sources' -o -name '*.gpg' -o -name '*.asc' -o -name '*.key' \) \
    -print0 2>/dev/null | xargs -0 -r sha256sum > "$TREE/APT/source-key-sha256.txt" || true
}

# ---------- Version / restore metadata helpers ----------
record_tool_metadata() {
  mkdir -p "$TREE/METADATA"
  {
    echo "backup_script_version=$SCRIPT_VERSION"
    echo "backup_timestamp=$(date --iso-8601=seconds)"
    echo "hostname=$HOST"
    echo "os_id=${ID:-unknown}"
    echo "os_version=${VERSION_ID:-unknown}"
    echo "os_pretty_name=${PRETTY_NAME:-unknown}"
    echo "kernel=$(uname -r)"
    echo "architecture=$(uname -m)"
    echo
    echo "[tools]"
    for tool in nginx psql pg_dump pg_dumpall pg_isready mongodump mongorestore mongosh mongod sqlcmd cscli docker dotnet node npm python3 java sshd ufw fail2ban; do
      if cmd "$tool"; then
        case "$tool" in
          nginx) ver="$(nginx -v 2>&1 | sed 's/^nginx version: //')" ;;
          psql|pg_dump|pg_dumpall|pg_isready) ver="$("$tool" --version 2>&1)" ;;
          mongodump|mongorestore|mongod) ver="$("$tool" --version 2>&1 | head -n 1)" ;;
          mongosh) ver="$(mongosh --version 2>&1)" ;;
          sqlcmd) ver="$(sqlcmd --version 2>&1 | head -n 1)" ;;
          cscli) ver="$(cscli version 2>&1 | head -n 1)" ;;
          docker) ver="$(docker --version 2>&1)" ;;
          dotnet) ver="$(dotnet --version 2>&1)" ;;
          node) ver="$(node --version 2>&1)" ;;
          npm) ver="$(npm --version 2>&1)" ;;
          python3) ver="$(python3 --version 2>&1)" ;;
          java) ver="$(java -version 2>&1 | head -n 1)" ;;
          sshd) ver="$(sshd -V 2>&1 | head -n 1)" ;;
          ufw) ver="$(ufw version 2>&1 | head -n 1)" ;;
          fail2ban) ver="$(fail2ban-client --version 2>&1 | head -n 1)" ;;
        esac
        printf '%s\t%s\n' "$tool" "$ver"
      else
        printf '%s\tNOT-INSTALLED\n' "$tool"
      fi
    done
    echo
    echo "[packages]"
    if cmd dpkg-query; then
      for pkg in nginx nginx-common postgresql postgresql-common postgresql-client mssql-server mongodb-org mongodb-org-server mongodb-database-tools crowdsec crowdsec-firewall-bouncer fail2ban docker-ce docker.io; do
        dpkg-query -W -f='${Package}\t${Version}\n' "$pkg" 2>/dev/null || true
      done
    elif cmd pacman; then
      for pkg in nginx postgresql mongodb-tools crowdsec fail2ban docker; do
        pacman -Q "$pkg" 2>/dev/null || true
      done
    fi
  } > "$TREE/METADATA/tool-versions.txt"

  {
    printf 'BACKUP_SCRIPT_VERSION=%q\n' "$SCRIPT_VERSION"
    printf 'BACKUP_TIMESTAMP=%q\n' "$(date --iso-8601=seconds)"
    printf 'HOSTNAME=%q\n' "$HOST"
    printf 'OS_ID=%q\n' "${ID:-unknown}"
    printf 'OS_VERSION=%q\n' "${VERSION_ID:-unknown}"
    printf 'OS_PRETTY_NAME=%q\n' "${PRETTY_NAME:-unknown}"
    printf 'KERNEL=%q\n' "$(uname -r)"
    printf 'ARCH=%q\n' "$(uname -m)"
    if cmd nginx; then printf 'NGINX_VERSION=%q\n' "$(nginx -v 2>&1 | sed 's/^nginx version: //')"; fi
    if cmd psql; then printf 'PSQL_VERSION=%q\n' "$(psql --version 2>&1)"; fi
    if cmd mongosh; then printf 'MONGOSH_VERSION=%q\n' "$(mongosh --version 2>&1)"; fi
    if cmd cscli; then printf 'CROWDSEC_VERSION=%q\n' "$(cscli version 2>&1 | head -n 1)"; fi
    if cmd sqlcmd; then printf 'SQLCMD_VERSION=%q\n' "$(sqlcmd --version 2>&1 | head -n 1)"; fi
    if cmd apt-get; then printf 'APT_VERSION=%q\n' "$(apt-get --version 2>&1 | head -n 1)"; fi
    if cmd dpkg; then printf 'DPKG_VERSION=%q\n' "$(dpkg --version 2>&1 | head -n 1)"; fi
  } > "$TREE/METADATA/tool-versions.env"
}
is_port_open() {
  local host="$1" port="$2"
  (exec 3<>"/dev/tcp/${host}/${port}") >/dev/null 2>&1 && { exec 3>&-; exec 3<&-; return 0; } || return 1
}

# Prompt for username/text with Enter = default value
prompt_with_default() {
  local var_name="$1"
  local prompt_label="$2"
  local default_val="$3"
  local current_val="${!var_name:-$default_val}"

  if [[ -t 0 ]]; then
    local prompt_msg="[PROMPT] Enter ${prompt_label}"
    if [[ -n "$default_val" ]]; then
      prompt_msg+=" [default: ${default_val}]"
    else
      prompt_msg+=" [press ENTER for none]"
    fi
    prompt_msg+=": "

    read -rp "$prompt_msg" user_input
    if [[ -z "$user_input" ]]; then
      export "$var_name"="$default_val"
    else
      export "$var_name"="$user_input"
    fi
  else
    export "$var_name"="$current_val"
  fi
}

# Prompt for password securely (masked)
prompt_password_if_empty() {
  local var_name="$1"
  local prompt_label="$2"
  local current_val="${!var_name:-}"

  if [[ -z "$current_val" ]]; then
    if [[ -t 0 ]]; then
      read -rsp "[PROMPT] Enter password for ${prompt_label}: " user_input
      echo "" >&2
      export "$var_name"="$user_input"
    else
      warn "Running non-interactively and ${var_name} is unset. Authentication may fail."
    fi
  fi
}

# ========================================================
# 1. OS Detection and Dependency Provisioning
# ========================================================
DETECTED_OS="unknown"
if [[ -f /etc/os-release ]]; then
  # shellcheck source=/dev/null
  . /etc/os-release
  case "${ID:-}" in
    ubuntu|debian|pop|linuxmint)
      DETECTED_OS="debian-like"
      ;;
    arch|manjaro|endeavouros)
      DETECTED_OS="arch"
      ;;
    *)
      if [[ "${ID_LIKE:-}" =~ (ubuntu|debian) ]]; then
        DETECTED_OS="debian-like"
      elif [[ "${ID_LIKE:-}" =~ arch ]]; then
        DETECTED_OS="arch"
      fi
      ;;
  esac
fi

log "Detected OS profile: ${DETECTED_OS} (${PRETTY_NAME:-Linux})"

install_standalone_sqlcmd() {
  if cmd sqlcmd; then return 0; fi
  log "Installing standalone go-sqlcmd binary..."
  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64)  arch="amd64" ;;
    aarch64) arch="arm64" ;;
    *) warn "Unsupported architecture for sqlcmd: $arch"; return 1 ;;
  esac

  mkdir -p /usr/local/bin
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  if curl -fsSL "https://github.com/microsoft/go-sqlcmd/releases/latest/download/sqlcmd-linux-${arch}.tar.bz2" -o "${tmp_dir}/sqlcmd.tar.bz2"; then
    tar -xjf "${tmp_dir}/sqlcmd.tar.bz2" -C /usr/local/bin sqlcmd 2>/dev/null || tar -xjf "${tmp_dir}/sqlcmd.tar.bz2" -C "${tmp_dir}"
    [[ -f "${tmp_dir}/sqlcmd" ]] && mv "${tmp_dir}/sqlcmd" /usr/local/bin/sqlcmd
    chmod +x /usr/local/bin/sqlcmd
    hash -r 2>/dev/null || true
    log "sqlcmd installed successfully"
  else
    warn "Failed to download standalone sqlcmd release"
  fi
  rm -rf "$tmp_dir"
}

install_standalone_mongodump() {
  if cmd mongodump; then return 0; fi
  log "Installing MongoDB Database Tools via official archive..."
  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64)  arch="x86_64" ;;
    aarch64) arch="arm64" ;;
    *) warn "Unsupported architecture for mongodump: $arch"; return 1 ;;
  esac

  mkdir -p /usr/local/bin
  local tmp_dir
  tmp_dir="$(mktemp -d)"
  local url="https://fastdl.mongodb.org/tools/db/mongodb-database-tools-ubuntu2204-${arch}-100.10.0.tgz"

  if curl -fsSL "$url" -o "${tmp_dir}/tools.tgz"; then
    tar -xzf "${tmp_dir}/tools.tgz" -C "${tmp_dir}"
    find "${tmp_dir}" -type f -name "mongodump" -exec cp {} /usr/local/bin/ \;
    find "${tmp_dir}" -type f -name "mongorestore" -exec cp {} /usr/local/bin/ \; 2>/dev/null || true
    chmod +x /usr/local/bin/mongodump /usr/local/bin/mongorestore 2>/dev/null || true
    hash -r 2>/dev/null || true
    log "mongodump installed successfully"
  else
    warn "Failed to download standalone MongoDB tools archive"
  fi
  rm -rf "$tmp_dir"
}

# ---------- APT repositories, vendor sources and signing keys ----------
if [[ "$DETECTED_OS" == "debian-like" ]] && cmd apt-get; then
  backup_package_sources_and_keys
fi

ensure_dependencies() {
  log "Verifying system requirements and database CLI tools..."

  local need_pg=0 need_mongo=0 need_mssql=0
  if systemctl is-active --quiet postgresql 2>/dev/null || [[ -d /etc/postgresql ]]; then
    need_pg=1
  fi
  if systemctl is-active --quiet mongod 2>/dev/null || systemctl is-active --quiet mongodb 2>/dev/null || [[ -f /etc/mongod.conf ]]; then
    need_mongo=1
  fi
  if systemctl is-active --quiet mssql-server 2>/dev/null || [[ -d /var/opt/mssql ]]; then
    need_mssql=1
  fi

  if ! cmd curl || ! cmd tar || ! cmd bzip2; then
    if [[ "$DETECTED_OS" == "debian-like" ]]; then
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y && apt-get install -y --no-install-recommends curl tar bzip2 ca-certificates
    elif [[ "$DETECTED_OS" == "arch" ]]; then
      pacman -Sy --noconfirm --needed curl tar bzip2 ca-certificates
    fi
  fi

  # PostgreSQL client tools
  if (( need_pg )) && (! cmd psql || ! cmd pg_dump || ! cmd pg_dumpall || ! cmd pg_isready); then
    log "PostgreSQL detected. Installing client tools..."
    if [[ "$DETECTED_OS" == "debian-like" ]]; then
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y && apt-get install -y --no-install-recommends postgresql-client
    elif [[ "$DETECTED_OS" == "arch" ]]; then
      # Arch provides the PostgreSQL client utilities in the postgresql package.
      pacman -Sy --noconfirm --needed postgresql
    else
      die "Unsupported OS for automatic PostgreSQL client installation."
    fi
  fi

  if (( need_pg )) && (! cmd psql || ! cmd pg_dump || ! cmd pg_dumpall || ! cmd pg_isready); then
    die "PostgreSQL client tools are incomplete. Required: psql, pg_dump, pg_dumpall, pg_isready."
  fi

  # MongoDB tools
  if (( need_mongo )) && ! cmd mongodump; then
    log "MongoDB detected. Installing tools..."
    if [[ "$DETECTED_OS" == "debian-like" ]]; then
      export DEBIAN_FRONTEND=noninteractive
      if ! apt-get install -y --no-install-recommends mongodb-org-tools 2>/dev/null && \
         ! apt-get install -y --no-install-recommends mongodb-database-tools 2>/dev/null; then
        install_standalone_mongodump
      fi
    elif [[ "$DETECTED_OS" == "arch" ]]; then
      pacman -Sy --noconfirm --needed mongodb-tools 2>/dev/null || install_standalone_mongodump
    else
      install_standalone_mongodump
    fi
  fi

  # MSSQL sqlcmd
  if (( need_mssql )) && ! cmd sqlcmd; then
    log "MSSQL Server detected. Installing sqlcmd..."
    if [[ "$DETECTED_OS" == "debian-like" ]]; then
      export DEBIAN_FRONTEND=noninteractive
      apt-get install -y --no-install-recommends sqlcmd 2>/dev/null || install_standalone_sqlcmd
    else
      install_standalone_sqlcmd
    fi
  fi
}

ensure_dependencies

# Refresh repository/key/package-version capture after dependency provisioning.
# The first capture happens before installation so the original source state is
# preserved; this second capture records the final installed package versions.
if [[ "$DETECTED_OS" == "debian-like" ]] && cmd apt-get; then
  backup_package_sources_and_keys
fi

# ========================================================
# 2. Main Backup Execution
# ========================================================
log "Starting server backup v${SCRIPT_VERSION}"
log "Host: $HOST"
log "Backup root: $BACKUP_ROOT"
log "Archive: $ARCHIVE"

# ---------- System inventory ----------
mkdir -p "$TREE/SYSTEM" "$TREE/NETWORK" "$TREE/PACKAGES" "$TREE/SERVICES" \
         "$TREE/SYSTEMD" "$TREE/SECURITY" "$TREE/CRON" "$TREE/SSH" "$TREE/DOCKER"

cat /etc/os-release > "$TREE/SYSTEM/os-release.txt" 2>/dev/null || true
uname -a > "$TREE/SYSTEM/kernel.txt" 2>/dev/null || true
hostnamectl > "$TREE/SYSTEM/hostnamectl.txt" 2>/dev/null || hostname > "$TREE/SYSTEM/hostname.txt" || true
lscpu > "$TREE/SYSTEM/lscpu.txt" 2>/dev/null || true
free -h > "$TREE/SYSTEM/memory.txt" 2>/dev/null || true
lsblk -a -f > "$TREE/SYSTEM/lsblk.txt" 2>/dev/null || true
df -hT > "$TREE/SYSTEM/df.txt" 2>/dev/null || true
findmnt > "$TREE/SYSTEM/findmnt.txt" 2>/dev/null || true
timedatectl > "$TREE/SYSTEM/timedatectl.txt" 2>/dev/null || true
sysctl -a > "$TREE/SYSTEM/sysctl.txt" 2>/dev/null || true
dmesg > "$TREE/SYSTEM/dmesg.txt" 2>/dev/null || true

ip addr > "$TREE/NETWORK/ip-address.txt" 2>/dev/null || true
ip route > "$TREE/NETWORK/routes.txt" 2>/dev/null || true
ss -tulpn > "$TREE/NETWORK/listening-ports.txt" 2>/dev/null || true
cat /etc/hosts > "$TREE/NETWORK/hosts.txt" 2>/dev/null || true
cat /etc/resolv.conf > "$TREE/NETWORK/resolv.conf" 2>/dev/null || true

# ---------- Packages ----------
if cmd dpkg; then
  dpkg-query -W -f='${binary:Package}\t${Version}\n' | sort > "$TREE/PACKAGES/dpkg-packages.txt" || true
  dpkg --get-selections > "$TREE/PACKAGES/dpkg-selections.txt" || true
fi
if cmd pacman; then
  pacman -Qe > "$TREE/PACKAGES/pacman-explicit.txt" 2>/dev/null || true
  pacman -Q > "$TREE/PACKAGES/pacman-all.txt" 2>/dev/null || true
fi
if cmd apt-mark; then apt-mark showmanual > "$TREE/PACKAGES/apt-manual.txt" || true; fi
if cmd snap; then snap list > "$TREE/PACKAGES/snap-list.txt" || true; fi
if cmd flatpak; then flatpak list > "$TREE/PACKAGES/flatpak-list.txt" || true; fi
if cmd dotnet; then
  dotnet --info > "$TREE/PACKAGES/dotnet-info.txt" 2>&1 || true
  dotnet --list-runtimes > "$TREE/PACKAGES/dotnet-runtimes.txt" 2>&1 || true
  dotnet --list-sdks > "$TREE/PACKAGES/dotnet-sdks.txt" 2>&1 || true
fi
if cmd node; then node --version > "$TREE/PACKAGES/node-version.txt" 2>&1 || true; fi
if cmd python3; then python3 --version > "$TREE/PACKAGES/python-version.txt" 2>&1 || true; fi
if cmd java; then java -version > "$TREE/PACKAGES/java-version.txt" 2>&1 || true; fi

# ---------- Nginx ----------
if cmd nginx; then
  mkdir -p "$TREE/NGINX"
  nginx -V > "$TREE/NGINX/nginx-version.txt" 2>&1 || true
  nginx -T > "$TREE/NGINX/nginx-full-config.txt" 2>&1 || true
  cp -a /etc/nginx "$TREE/NGINX/etc-nginx"
  nginx -t > "$TREE/NGINX/nginx-test.txt" 2>&1 || true
fi

# ---------- Firewall ----------
if cmd ufw; then
  mkdir -p "$TREE/FIREWALL"
  ufw status verbose > "$TREE/FIREWALL/ufw-status.txt" 2>&1 || true
  ufw status numbered > "$TREE/FIREWALL/ufw-numbered.txt" 2>&1 || true
  copy_if_exists /etc/ufw FIREWALL/etc-ufw
fi
if cmd nft; then
  mkdir -p "$TREE/FIREWALL"
  nft list ruleset > "$TREE/FIREWALL/nftables-ruleset.txt" 2>&1 || true
fi
if cmd iptables-save; then
  mkdir -p "$TREE/FIREWALL"
  iptables-save > "$TREE/FIREWALL/iptables.rules" 2>/dev/null || true
  ip6tables-save > "$TREE/FIREWALL/ip6tables.rules" 2>/dev/null || true
fi

# ---------- CrowdSec ----------
if cmd cscli || [[ -d /etc/crowdsec ]]; then
  mkdir -p "$TREE/CROWDSEC"
  copy_if_exists /etc/crowdsec CROWDSEC/etc-crowdsec
  copy_if_exists /var/lib/crowdsec CROWDSEC/var-lib-crowdsec
  if cmd cscli; then
    cscli version > "$TREE/CROWDSEC/version.txt" 2>&1 || true
    cscli hub list > "$TREE/CROWDSEC/hub-list.txt" 2>&1 || true
    cscli collections list > "$TREE/CROWDSEC/collections.txt" 2>&1 || true
    cscli parsers list > "$TREE/CROWDSEC/parsers.txt" 2>&1 || true
    cscli scenarios list > "$TREE/CROWDSEC/scenarios.txt" 2>&1 || true
    cscli bouncers list > "$TREE/CROWDSEC/bouncers.txt" 2>&1 || true
    cscli decisions list -o json > "$TREE/CROWDSEC/decisions.json" 2>&1 || true
  fi
fi

# ---------- SSH ----------
mkdir -p "$TREE/SSH"
copy_if_exists /etc/ssh SSH/etc-ssh
sshd -T > "$TREE/SSH/sshd-effective-config.txt" 2>&1 || true

# ---------- systemd ----------
systemctl list-unit-files --no-pager > "$TREE/SYSTEMD/unit-files.txt" 2>&1 || true
systemctl list-units --all --no-pager > "$TREE/SYSTEMD/units.txt" 2>&1 || true
systemctl list-timers --all --no-pager > "$TREE/SYSTEMD/timers.txt" 2>&1 || true
systemctl list-sockets --all --no-pager > "$TREE/SYSTEMD/sockets.txt" 2>&1 || true
systemctl --failed --no-pager > "$TREE/SYSTEMD/failed-units.txt" 2>&1 || true
mkdir -p "$TREE/SYSTEMD"
copy_if_exists /etc/systemd/system SYSTEMD/etc-systemd-system
copy_if_exists /usr/lib/systemd/system SYSTEMD/usr-lib-systemd-system
copy_if_exists /lib/systemd/system SYSTEMD/lib-systemd-system
copy_if_exists /etc/systemd/user SYSTEMD/etc-systemd-user

systemctl list-units --type=service --all --no-legend 2>/dev/null |
awk '{print $1}' | while read -r svc; do
  systemctl status "$svc" --no-pager --full > "$TREE/SERVICES/${svc//\//_}.txt" 2>&1 || true
done

# ---------- Cron ----------
copy_if_exists /etc/cron.d CRON/etc-cron.d
copy_if_exists /etc/cron.daily CRON/etc-cron.daily
copy_if_exists /etc/cron.hourly CRON/etc-cron.hourly
copy_if_exists /etc/cron.weekly CRON/etc-cron.weekly
copy_if_exists /etc/cron.monthly CRON/etc-cron.monthly
copy_if_exists /var/spool/cron CRON/var-spool-cron
crontab -l > "$TREE/CRON/root-crontab.txt" 2>/dev/null || true

# ---------- PostgreSQL ----------
if cmd psql || cmd pg_dump || cmd pg_dumpall || [[ -d /etc/postgresql ]]; then
  mkdir -p "$TREE/POSTGRES/databases"
  copy_if_exists /etc/postgresql POSTGRES/etc-postgresql
  copy_if_exists /etc/postgresql-common POSTGRES/etc-postgresql-common

  PG_HOST="${PG_HOST:-127.0.0.1}"
  PG_PORT="${PG_PORT:-5432}"

  if ! cmd psql || ! cmd pg_dump || ! cmd pg_dumpall; then
    die "PostgreSQL backup requested but required tools are missing (psql/pg_dump/pg_dumpall)."
  fi

  if is_port_open "$PG_HOST" "$PG_PORT" || (cmd pg_isready && pg_isready -h "$PG_HOST" -p "$PG_PORT" -q 2>/dev/null); then
    prompt_with_default "PG_USER" "PostgreSQL username" "${PG_USER:-postgres}"
    prompt_password_if_empty "PG_PASSWORD" "PostgreSQL user '${PG_USER}'"

    export PGHOST="$PG_HOST"
    export PGPORT="$PG_PORT"
    export PGUSER="$PG_USER"
    export PGDATABASE="${PG_DATABASE:-postgres}"
    [[ -n "${PG_PASSWORD:-}" ]] && export PGPASSWORD="$PG_PASSWORD"

    log "Testing PostgreSQL connection..."
    if ! psql -AtX -d "$PGDATABASE" -c "SELECT 1;" >/dev/null; then
      die "PostgreSQL authentication/connection failed for user '$PG_USER' using database '$PGDATABASE'. Aborting backup."
    fi

    psql -AtX -d "$PGDATABASE" -c "SHOW server_version;" > "$TREE/POSTGRES/server-version.txt"
    psql -AtX -d "$PGDATABASE" -c "SELECT current_setting('server_version_num');" > "$TREE/POSTGRES/server-version-num.txt"

    # Record the default PostgreSQL account and enable LOGIN if necessary.
    # The original state is retained for restoration.
    PG_DEFAULT_ROLE_FILE="$TREE/POSTGRES/postgres-role-state.txt"
    if psql -AtX -d "$PGDATABASE" -c "SELECT 1 FROM pg_roles WHERE rolname='postgres';" | grep -q '^1$'; then
      PG_POSTGRES_CANLOGIN="$(psql -AtX -d "$PGDATABASE" -c "SELECT rolcanlogin FROM pg_roles WHERE rolname='postgres';")"
      PG_POSTGRES_SUPERUSER="$(psql -AtX -d "$PGDATABASE" -c "SELECT rolsuper FROM pg_roles WHERE rolname='postgres';")"
      {
        echo "role=postgres"
        echo "original_rolcanlogin=$PG_POSTGRES_CANLOGIN"
        echo "rolsuper=$PG_POSTGRES_SUPERUSER"
        echo "backup_changed_rolcanlogin=no"
      } > "$PG_DEFAULT_ROLE_FILE"
      if [[ "$PG_POSTGRES_CANLOGIN" != "t" ]]; then
        log "PostgreSQL default role 'postgres' is disabled for LOGIN; enabling it for disaster recovery."
        psql -AtX -d "$PGDATABASE" -c "ALTER ROLE postgres LOGIN;" >/dev/null
        echo "backup_changed_rolcanlogin=yes" >> "$PG_DEFAULT_ROLE_FILE"
      fi
    else
      {
        echo "role=postgres"
        echo "status=NOT_PRESENT"
      } > "$PG_DEFAULT_ROLE_FILE"
    fi

    log "Dumping ALL PostgreSQL database names..."
    if ! psql -AtX -d "$PGDATABASE" \
      -c 'SELECT datname FROM pg_database WHERE datallowconn AND NOT datistemplate ORDER BY 1;' \
      > "$TREE/POSTGRES/database-list.txt"; then
      die "PostgreSQL database-list query failed. Aborting backup."
    fi

    log "Dumping PostgreSQL globals..."
    if ! pg_dumpall --globals-only > "$TREE/POSTGRES/globals.sql" 2>"$TREE/POSTGRES/globals.err"; then
      die "PostgreSQL globals dump failed. Aborting backup."
    fi

    while IFS= read -r db; do
      [[ -n "$db" ]] || continue
      safe="${db//[^A-Za-z0-9_.-]/_}"

      log "PostgreSQL: dumping database '$db'..."
      if ! pg_dump -Fc --no-owner --no-acl -d "$db" \
        > "$TREE/POSTGRES/databases/${safe}.dump" \
        2> "$TREE/POSTGRES/databases/${safe}.err"; then
        die "PostgreSQL database dump failed: $db. Aborting backup."
      fi

      [[ -s "$TREE/POSTGRES/databases/${safe}.dump" ]] ||
        die "PostgreSQL dump is empty: $db. Aborting backup."

      # Remove empty error files to keep the archive clean.
      [[ ! -s "$TREE/POSTGRES/databases/${safe}.err" ]] &&
        rm -f "$TREE/POSTGRES/databases/${safe}.err" || true
    done < "$TREE/POSTGRES/database-list.txt"

    unset PGPASSWORD PGHOST PGPORT PGUSER PGDATABASE
  else
    die "PostgreSQL is detected but is not listening on ${PG_HOST}:${PG_PORT}. Aborting backup."
  fi
fi

# ---------- MongoDB ----------
if cmd mongodump || cmd mongosh || [[ -d /etc/mongod.conf.d ]] || [[ -f /etc/mongod.conf ]]; then
  mkdir -p "$TREE/MONGODB"
  copy_if_exists /etc/mongod.conf MONGODB/mongod.conf
  copy_if_exists /etc/mongod.conf.d MONGODB/mongod.conf.d

  MONGO_HOST="${MONGO_HOST:-127.0.0.1}"
  MONGO_PORT="${MONGO_PORT:-27017}"

  if is_port_open "$MONGO_HOST" "$MONGO_PORT"; then
    # Prompt for MongoDB username (Enter = empty / no auth)
    prompt_with_default "MONGO_USER" "MongoDB username" "${MONGO_USER:-}"

    if [[ -n "${MONGO_USER:-}" ]]; then
      prompt_password_if_empty "MONGO_PASSWORD" "MongoDB user '${MONGO_USER}'"
      AUTH_STR="${MONGO_USER}:${MONGO_PASSWORD}@"
      AUTH_DB_STR="?authSource=${MONGO_AUTH_DB:-admin}"
    else
      AUTH_STR=""
      AUTH_DB_STR=""
    fi
    MONGO_URI="mongodb://${AUTH_STR}${MONGO_HOST}:${MONGO_PORT}/${AUTH_DB_STR}"

    log "Dumping MongoDB databases..."
    if cmd mongodump; then
      if ! mongodump --uri="$MONGO_URI" --archive="$TREE/MONGODB/mongodb.archive.gz" --gzip; then
        warn "MongoDB dump failed"
      fi
    fi
    if cmd mongosh; then
      mongosh "$MONGO_URI" --quiet --eval 'db.version()' \
        > "$TREE/MONGODB/server-version.txt" 2>/dev/null || true
      mongosh "$MONGO_URI" --quiet --eval 'db.adminCommand({getCmdLineOpts:1}).parsed.security || {}' \
        > "$TREE/MONGODB/security-config.txt" 2>/dev/null || true
      mongosh "$MONGO_URI" --quiet --eval 'db.adminCommand({listDatabases:1}).databases.map(x=>x.name).join("\n")' \
        > "$TREE/MONGODB/database-list.txt" 2>/dev/null || true

      # MongoDB has no single built-in default account. Back up every user's
      # roles/privileges so accounts can be recreated on the new server.
      : > "$TREE/MONGODB/users.json"
      while IFS= read -r mdb; do
        [[ -n "$mdb" ]] || continue
        printf '\n===== DATABASE: %s =====\n' "$mdb" >> "$TREE/MONGODB/users.json"
        mongosh "mongodb://${AUTH_STR}${MONGO_HOST}:${MONGO_PORT}/${mdb}${AUTH_DB_STR}" \
          --quiet --eval 'EJSON.stringify(db.getUsers({showCredentials:false}), null, 2)' \
          >> "$TREE/MONGODB/users.json" 2>/dev/null || true
      done < "$TREE/MONGODB/database-list.txt"
    fi
  else
    log "MongoDB is not listening on ${MONGO_HOST}:${MONGO_PORT}. Skipping live dump."
  fi
fi

# ---------- Microsoft SQL Server ----------
if cmd sqlcmd || systemctl list-unit-files 2>/dev/null | grep -q '^mssql-server\.service'; then
  mkdir -p "$TREE/MSSQL"
  systemctl status mssql-server --no-pager --full > "$TREE/MSSQL/service-status.txt" 2>&1 || true
  copy_if_exists /var/opt/mssql/MSSQL/MSSQL.conf MSSQL/MSSQL.conf
  copy_if_exists /etc/systemd/system/mssql-server.service.d MSSQL/mssql-systemd-override

  MSSQL_SERVER="${MSSQL_SERVER:-127.0.0.1,1433}"
  MSSQL_HOST_CLEAN="${MSSQL_SERVER%%,*}"
  MSSQL_HOST_CLEAN="${MSSQL_HOST_CLEAN%%:*}"
  MSSQL_PORT="${MSSQL_PORT:-1433}"

  if ! cmd sqlcmd; then
    die "MSSQL backup requested but sqlcmd is not installed."
  fi

  if ! is_port_open "$MSSQL_HOST_CLEAN" "$MSSQL_PORT"; then
    die "MSSQL is detected but is not listening on ${MSSQL_HOST_CLEAN}:${MSSQL_PORT}. Aborting backup."
  fi

  prompt_with_default "MSSQL_USER" "MSSQL username" "${MSSQL_USER:-sa}"
  [[ -n "${MSSQL_USER:-}" ]] && prompt_password_if_empty "MSSQL_PASSWORD" "MSSQL user '${MSSQL_USER}'"

  SQLCMD_ARGS=(-S "$MSSQL_SERVER" -b -C)
  [[ -n "${MSSQL_USER:-}" ]] && SQLCMD_ARGS+=(-U "$MSSQL_USER" -P "${MSSQL_PASSWORD:-}")

  log "Testing MSSQL connection..."
  if ! sqlcmd "${SQLCMD_ARGS[@]}" -Q "SELECT @@SERVERNAME AS server_name, @@VERSION AS version;" \
      > "$TREE/MSSQL/version.txt" 2>&1; then
    die "MSSQL connection/authentication failed. Aborting backup."
  fi

  # Record the built-in SQL Server 'sa' login and enable it for recovery if disabled.
  # Original state is retained so restore can put it back.
  SA_STATE="$(sqlcmd "${SQLCMD_ARGS[@]}" -h -1 -W -Q \
    "SET NOCOUNT ON; SELECT CAST(is_disabled AS int) FROM sys.sql_logins WHERE name = N'sa';" \
    2>/dev/null | sed '/^[[:space:]]*$/d' | head -n 1 | tr -d '[:space:]')"
  {
    echo "login=sa"
    echo "original_is_disabled=${SA_STATE:-UNKNOWN}"
    echo "backup_changed_is_disabled=no"
  } > "$TREE/MSSQL/sa-login-state.txt"
  if [[ "$SA_STATE" == "1" ]]; then
    log "MSSQL built-in 'sa' login is disabled; enabling it for disaster recovery."
    sqlcmd "${SQLCMD_ARGS[@]}" -Q "ALTER LOGIN [sa] ENABLE;" >/dev/null
    echo "backup_changed_is_disabled=yes" >> "$TREE/MSSQL/sa-login-state.txt"
  fi

  # Export server login state. Database users/roles are preserved by the .bak files.
  sqlcmd "${SQLCMD_ARGS[@]}" -h -1 -W -Q "SET NOCOUNT ON; SELECT name, type_desc, is_disabled FROM sys.server_principals WHERE type IN ('S','U') ORDER BY name;" \
    > "$TREE/MSSQL/server-logins.txt" 2>/dev/null || true
  sqlcmd "${SQLCMD_ARGS[@]}" -h -1 -W -Q "SET NOCOUNT ON; SELECT r.name AS server_role, m.name AS member_name FROM sys.server_role_members srm JOIN sys.server_principals r ON r.principal_id=srm.role_principal_id JOIN sys.server_principals m ON m.principal_id=srm.member_principal_id ORDER BY r.name,m.name;" \
    > "$TREE/MSSQL/server-role-members.txt" 2>/dev/null || true

  # SQL Server Express does not support BACKUP DATABASE ... COMPRESSION.
  # Detect the edition once and choose a compatible BACKUP option set.
  MSSQL_EDITION="$(sqlcmd "${SQLCMD_ARGS[@]}" -h -1 -W -Q \
    "SET NOCOUNT ON; SELECT CAST(SERVERPROPERTY('Edition') AS nvarchar(256));" \
    2>>"$TREE/MSSQL/version.txt" | sed '/^[[:space:]]*$/d' | head -n 1 | sed 's/[[:space:]]*$//')"

  [[ -n "$MSSQL_EDITION" ]] ||
    die "Could not determine SQL Server edition. Aborting backup."

  printf '%s\\n' "$MSSQL_EDITION" > "$TREE/MSSQL/edition.txt"
  log "MSSQL edition: $MSSQL_EDITION"

  if [[ "$MSSQL_EDITION" == *"Express Edition"* ]]; then
    MSSQL_BACKUP_OPTIONS="INIT, CHECKSUM, STATS=5"
    log "SQL Server Express detected: backup compression disabled."
  else
    MSSQL_BACKUP_OPTIONS="INIT, CHECKSUM, COMPRESSION, STATS=5"
    log "SQL Server backup compression enabled."
  fi

  log "Getting MSSQL database list..."
  if ! sqlcmd "${SQLCMD_ARGS[@]}" -h -1 -W -Q \
      "SET NOCOUNT ON;
       SELECT name
       FROM sys.databases
       WHERE database_id > 4
         AND state_desc = 'ONLINE'
         AND source_database_id IS NULL
       ORDER BY name;" \
      2> "$TREE/MSSQL/database-list.err" |
      sed '/^[[:space:]]*$/d' |
      sed 's/[[:space:]]*$//' > "$TREE/MSSQL/database-list.txt"; then
    die "MSSQL database-list query failed. Aborting backup."
  fi

  [[ -s "$TREE/MSSQL/database-list.txt" ]] ||
    die "No online user MSSQL databases were found. Aborting backup."

  # SQL Server itself must be able to write this directory.
  MSSQL_BACKUP_DIR="${MSSQL_BACKUP_DIR:-/var/opt/mssql/backup}"
  mkdir -p "$MSSQL_BACKUP_DIR"
  chown mssql:mssql "$MSSQL_BACKUP_DIR" 2>/dev/null || true
  chmod 700 "$MSSQL_BACKUP_DIR" 2>/dev/null || true

  mkdir -p "$TREE/MSSQL/bak"

  while IFS= read -r db; do
    [[ -n "$db" ]] || continue

    safe="${db//[^A-Za-z0-9_.-]/_}"
    # Escape SQL Server identifier closing bracket: ] -> ]]
    qdb="${db//]/]]}"
    bakpath="${MSSQL_BACKUP_DIR}/${safe}-${STAMP}.bak"

    log "MSSQL: backing up database '$db'..."

    BACKUP_LOG="$TREE/MSSQL/${safe}-backup.log"

    # First verify that SQL Server's service account can write to the
    # configured backup directory. The backup is executed by SQL Server,
    # not by the root shell running this script.
    if command -v sudo >/dev/null 2>&1 && id mssql >/dev/null 2>&1; then
      if ! sudo -u mssql test -w "$MSSQL_BACKUP_DIR"; then
        {
          echo "SQL Server service account 'mssql' cannot write to:"
          echo "$MSSQL_BACKUP_DIR"
          echo
          echo "Fix with:"
          echo "  chown mssql:mssql '$MSSQL_BACKUP_DIR'"
          echo "  chmod 700 '$MSSQL_BACKUP_DIR'"
        } > "$BACKUP_LOG"
        die "MSSQL backup directory is not writable by the mssql service account: $MSSQL_BACKUP_DIR. See $BACKUP_LOG"
      fi
    fi

    log "Executing SQL Server BACKUP DATABASE for '$db'..."
    if ! sqlcmd "${SQLCMD_ARGS[@]}" -Q \
      "BACKUP DATABASE [$qdb]
       TO DISK = N'$bakpath'
       WITH $MSSQL_BACKUP_OPTIONS;" \
      > "$BACKUP_LOG" 2>&1; then
      echo "----- MSSQL ERROR: $db -----" >&2
      cat "$BACKUP_LOG" >&2 || true
      echo "----- END MSSQL ERROR -----" >&2
      die "MSSQL database backup failed: $db. Aborting backup. Full error: $BACKUP_LOG"
    fi

    [[ -s "$bakpath" ]] ||
      die "MSSQL backup file is missing or empty: $bakpath"

    log "Verifying MSSQL backup: '$db'..."
    if ! sqlcmd "${SQLCMD_ARGS[@]}" -Q \
      "RESTORE VERIFYONLY FROM DISK = N'$bakpath';" \
      >> "$BACKUP_LOG" 2>&1; then
      echo "----- MSSQL VERIFY ERROR: $db -----" >&2
      cat "$BACKUP_LOG" >&2 || true
      echo "----- END MSSQL VERIFY ERROR -----" >&2
      die "MSSQL backup verification failed: $db. Aborting backup."
    fi

    cp -a "$bakpath" "$TREE/MSSQL/bak/" ||
      die "Failed to copy MSSQL backup into archive tree: $db"

    rm -f "$bakpath" ||
      die "Failed to remove temporary MSSQL backup file: $bakpath"
  done < "$TREE/MSSQL/database-list.txt"

  unset MSSQL_PASSWORD
fi

# ---------- Consolidated restore metadata ----------
record_tool_metadata

if [[ -f "$TREE/POSTGRES/postgres-role-state.txt" ]]; then
  {
    echo
    echo "[postgresql_restore_state]"
    cat "$TREE/POSTGRES/postgres-role-state.txt"
  } >> "$TREE/METADATA/tool-versions.txt"
fi
if [[ -f "$TREE/MSSQL/version.txt" ]]; then
  {
    echo
    echo "[mssql_server]"
    sed -n '1,3p' "$TREE/MSSQL/version.txt"
    [[ -f "$TREE/MSSQL/edition.txt" ]] && echo "edition=$(cat "$TREE/MSSQL/edition.txt")"
  } >> "$TREE/METADATA/tool-versions.txt"
fi
if [[ -f "$TREE/POSTGRES/server-version.txt" ]]; then
  {
    echo
    echo "[postgresql_server]"
    echo "server_version=$(cat "$TREE/POSTGRES/server-version.txt")"
    echo "server_version_num=$(cat "$TREE/POSTGRES/server-version-num.txt")"
  } >> "$TREE/METADATA/tool-versions.txt"
fi
if [[ -f "$TREE/MONGODB/server-version.txt" ]]; then
  {
    echo
    echo "[mongodb_server]"
    echo "server_version=$(cat "$TREE/MONGODB/server-version.txt")"
  } >> "$TREE/METADATA/tool-versions.txt"
fi

# ---------- Docker ----------
if cmd docker; then
  docker version > "$TREE/DOCKER/docker-version.txt" 2>&1 || true
  docker ps -a --no-trunc > "$TREE/DOCKER/containers.txt" 2>&1 || true
  docker images --digests > "$TREE/DOCKER/images.txt" 2>&1 || true
  docker network ls > "$TREE/DOCKER/networks.txt" 2>&1 || true
  docker volume ls > "$TREE/DOCKER/volumes.txt" 2>&1 || true
  docker compose version > "$TREE/DOCKER/compose-version.txt" 2>&1 || true
  docker ps -aq | xargs -r docker inspect > "$TREE/DOCKER/container-inspect.json" 2>/dev/null || true
  docker volume ls -q | xargs -r docker volume inspect > "$TREE/DOCKER/volume-inspect.json" 2>/dev/null || true
  mkdir -p "$TREE/DOCKER/volumes"
  while IFS= read -r vol; do
    [[ -n "$vol" ]] || continue
    mountpoint="$(docker volume inspect -f '{{.Mountpoint}}' "$vol" 2>/dev/null || true)"
    [[ -d "$mountpoint" ]] || { warn "Docker volume mountpoint unavailable: $vol"; continue; }
    safe="${vol//[^A-Za-z0-9_.-]/_}"
    tar --acls --xattrs --numeric-owner -czf "$TREE/DOCKER/volumes/${safe}.tar.gz" \
      -C "$mountpoint" . || warn "Docker volume backup failed: $vol"
  done < <(docker volume ls -q)
fi

# ---------- Web/application data ----------
mkdir -p "$TREE/WWW"
if [[ -d /var/www ]]; then
  tar --acls --xattrs --numeric-owner -czf "$TREE/WWW/var-www.tar.gz" -C /var www \
    || warn "/var/www backup failed"
fi

for p in /opt /srv; do
  if [[ -d "$p" ]]; then
    base="$(basename "$p")"
    parent="$(dirname "$p")"
    tar --acls --xattrs --numeric-owner -czf "$TREE/SYSTEM/${base}.tar.gz" \
      --exclude='*/node_modules/*' --exclude='*/.git/*' -C "$parent" "$base" \
      || warn "$p backup failed"
  fi
done

# ---------- Environment/config inventory ----------
copy_if_exists /etc/apt APT/etc-apt
copy_if_exists /etc/pacman.conf SYSTEM/pacman.conf
copy_if_exists /etc/pacman.d SYSTEM/pacman.d
copy_if_exists /etc/environment SYSTEM/etc-environment
copy_if_exists /etc/profile.d SYSTEM/etc-profile.d
copy_if_exists /etc/sysctl.d SYSTEM/etc-sysctl.d
copy_if_exists /etc/NetworkManager NETWORK/etc-NetworkManager
copy_if_exists /etc/letsencrypt SECURITY/etc-letsencrypt
copy_if_exists /etc/ssl SECURITY/etc-ssl
copy_if_exists /etc/fail2ban SECURITY/etc-fail2ban
copy_if_exists "$CONFIG_FILE" SYSTEM/backup.conf

# ---------- Git metadata ----------
find /var/www /opt /srv -type d -name .git -prune -print 2>/dev/null |
  sed 's#/.git$##' > "$TREE/SYSTEM/git-repositories.txt" || true

# ---------- Service/package facts ----------
{
  echo "Backup version: $SCRIPT_VERSION"
  echo "Timestamp: $(date --iso-8601=seconds)"
  echo "Hostname: $HOST"
  echo "OS Profile: $DETECTED_OS"
  echo "Kernel: $(uname -r)"
  echo "UID: $EUID"
  if [[ -f "$TREE/MSSQL/edition.txt" ]]; then
    echo "MSSQL Edition: $(cat "$TREE/MSSQL/edition.txt")"
  fi
  echo
  echo "Consolidated restore metadata: METADATA/tool-versions.txt"
  echo "Machine-readable metadata: METADATA/tool-versions.env"
  echo
  echo "Detected commands:"
  for x in nginx psql pg_dump pg_dumpall pg_isready mongodump mongosh sqlcmd docker cscli ufw dotnet pacman dpkg; do
    printf '%-12s %s\n' "$x" "$(command -v "$x" 2>/dev/null || echo NOT-INSTALLED)"
  done
} > "$TREE/backup-info.txt"

# ---------- Restore helper ----------
mkdir -p "$TREE/RESTORE"
cat > "$TREE/RESTORE/README.txt" <<'EOF_README'
DISASTER RECOVERY RESTORE GUIDE

1. Read METADATA/tool-versions.txt first. It contains the exact installed tool/package versions captured during backup.
2. Install the required major versions before restoring data. For PostgreSQL use the captured PostgreSQL server major version, not the Ubuntu default repository version.
3. Restore PostgreSQL roles first from POSTGRES/globals.sql, then restore each POSTGRES/databases/*.dump with pg_restore.
4. Restore MSSQL server login state from MSSQL/server-logins.txt as required, then restore MSSQL/bak/*.bak. The original sa enabled/disabled state is in MSSQL/sa-login-state.txt.
5. Restore MongoDB configuration and database data. MongoDB users/roles are in MONGODB/users.json. Passwords are intentionally not stored in clear text; recreate/reset user passwords during restore.
6. Restore Nginx from NGINX/etc-nginx and validate with nginx -t before starting it.
7. Restore CrowdSec from CROWDSEC/etc-crowdsec and validate cscli configuration before starting it.

IMPORTANT: Do not blindly enable built-in accounts on the restored production server. If this backup had to enable postgres or sa for collection, restore the original state recorded in their state files after recovery and verification.
EOF_README

cat > "$TREE/RESTORE/check-versions.sh" <<'EOF_CHECK'
#!/usr/bin/env bash
set -Eeuo pipefail
BASE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
META="$BASE/METADATA/tool-versions.env"
[[ -f "$META" ]] || { echo "Missing $META" >&2; exit 1; }
# shellcheck disable=SC1090
. "$META"
echo "Backup OS: $OS_PRETTY_NAME ($OS_ID $OS_VERSION)"
echo "Backup kernel: $KERNEL / $ARCH"
echo
printf '%-18s %-32s %s\n' TOOL EXPECTED INSTALLED
printf '%-18s %-32s %s\n' "----" "--------" "---------"
check_cmd(){
  local name="$1" expected="$2" cmd_name="${3:-$1}" got
  if command -v "$cmd_name" >/dev/null 2>&1; then
    got="$($cmd_name --version 2>&1 | head -n1 || true)"
  else
    got="NOT-INSTALLED"
  fi
  printf '%-18s %-32s %s\n' "$name" "$expected" "$got"
}
check_cmd nginx "${NGINX_VERSION:-unknown}" nginx
check_cmd postgres-client "${PSQL_VERSION:-unknown}" psql
check_cmd mongodb-shell "${MONGOSH_VERSION:-unknown}" mongosh
check_cmd crowdsec "${CROWDSEC_VERSION:-unknown}" cscli
check_cmd sqlcmd "${SQLCMD_VERSION:-unknown}" sqlcmd
EOF_CHECK
chmod 700 "$TREE/RESTORE/check-versions.sh"


cat > "$TREE/RESTORE/restore-apt-sources.sh" <<'EOF_APT_RESTORE'
#!/usr/bin/env bash
set -Eeuo pipefail
BASE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
APT_BACKUP="$BASE/APT"
[[ -d "$APT_BACKUP" ]] || { echo "No APT metadata in this backup." >&2; exit 1; }
[[ $EUID -eq 0 ]] || { echo "Run as root." >&2; exit 1; }

mkdir -p /etc/apt/sources.list.d /etc/apt/keyrings /etc/apt/trusted.gpg.d /etc/apt/preferences.d /usr/share/keyrings

# Preserve the new machine's current configuration before replacing it.
STAMP="$(date +%Y%m%d_%H%M%S)"
if [[ -f /etc/apt/sources.list ]]; then cp -a /etc/apt/sources.list "/etc/apt/sources.list.pre-restore-$STAMP"; fi
if [[ -d /etc/apt/sources.list.d ]]; then cp -a /etc/apt/sources.list.d "/etc/apt/sources.list.d.pre-restore-$STAMP"; fi

[[ ! -f "$APT_BACKUP/sources.list" ]] || cp -a "$APT_BACKUP/sources.list" /etc/apt/sources.list
if [[ -d "$APT_BACKUP/sources.list.d" ]]; then
  find /etc/apt/sources.list.d -maxdepth 1 -type f \
    \( -name '*.list' -o -name '*.sources' \) -delete 2>/dev/null || true
  cp -a "$APT_BACKUP/sources.list.d/." /etc/apt/sources.list.d/
fi
if [[ -d "$APT_BACKUP/keyrings" ]]; then cp -a "$APT_BACKUP/keyrings/." /usr/share/keyrings/; cp -a "$APT_BACKUP/keyrings/." /etc/apt/keyrings/ 2>/dev/null || true; fi
if [[ -d "$APT_BACKUP/trusted.gpg.d" ]]; then cp -a "$APT_BACKUP/trusted.gpg.d/." /etc/apt/trusted.gpg.d/; fi
if [[ -f "$APT_BACKUP/trusted.gpg" ]]; then cp -a "$APT_BACKUP/trusted.gpg" /etc/apt/trusted.gpg; fi
if [[ -d "$APT_BACKUP/preferences.d" ]]; then cp -a "$APT_BACKUP/preferences.d/." /etc/apt/preferences.d/; fi

echo "Restored APT sources and signing keys from backup."
echo "Running apt-get update..."
apt-get update
EOF_APT_RESTORE
chmod 700 "$TREE/RESTORE/restore-apt-sources.sh"

cat > "$TREE/RESTORE/install-packages-exact.sh" <<'EOF_INSTALL'
#!/usr/bin/env bash
set -Eeuo pipefail
BASE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
META="$BASE/METADATA/tool-versions.txt"
[[ -f "$META" ]] || { echo "Missing metadata: $META" >&2; exit 1; }
[[ $EUID -eq 0 ]] || { echo "Run as root." >&2; exit 1; }

if command -v apt-get >/dev/null 2>&1 && command -v dpkg-query >/dev/null 2>&1; then
  # FIRST restore the exact repository definitions and signing keys captured
  # from the old server. This is what allows vendor packages such as PGDG,
  # Microsoft SQL Server and MongoDB to resolve to the recorded versions.
  "$BASE/RESTORE/restore-apt-sources.sh"

  echo "Attempting exact Debian/Ubuntu package versions recorded in the backup."
  awk -F '\\t' '/^nginx\\t|^nginx-common\\t|^postgresql\\t|^postgresql-common\\t|^postgresql-client\\t|^mssql-server\\t|^mongodb-org\\t|^mongodb-org-server\\t|^mongodb-database-tools\\t|^crowdsec\\t|^crowdsec-firewall-bouncer\\t|^fail2ban\\t|^docker-ce\\t|^docker.io\\t/ {print $1 "=" $2}' "$META" |
  while IFS= read -r pkgver; do
    [[ -n "$pkgver" ]] || continue
    pkg="${pkgver%%=*}"
    ver="${pkgver#*=}"
    echo "Installing $pkg=$ver"
    apt-get install -y "${pkg}=${ver}" || { echo "ERROR: exact package unavailable: ${pkg}=${ver}" >&2; exit 1; }
  done
else
  echo "This helper currently targets Debian/Ubuntu apt packages." >&2
  echo "Use METADATA/tool-versions.txt with the native package manager on another distribution." >&2
  exit 2
fi
EOF_INSTALL
chmod 700 "$TREE/RESTORE/install-packages-exact.sh"

cat > "$TREE/RESTORE/restore-original-account-state.sql.txt" <<'EOF_ACCOUNTS'
ACCOUNT STATE RESTORE NOTES

PostgreSQL:
  See POSTGRES/postgres-role-state.txt.
  If original_rolcanlogin was 'f', run as a PostgreSQL superuser:
    ALTER ROLE postgres NOLOGIN;

MSSQL:
  See MSSQL/sa-login-state.txt.
  If original_is_disabled was '1', run as sysadmin:
    ALTER LOGIN [sa] DISABLE;

These commands intentionally are NOT executed automatically.
EOF_ACCOUNTS

# ---------- Archive integrity ----------
log "Creating archive"

if ! tar --acls --xattrs --numeric-owner \
    -czf "$ARCHIVE" \
    -C "$WORK" \
    server-backup backup.log; then
  die "Failed to create backup archive: $ARCHIVE"
fi

[[ -s "$ARCHIVE" ]] || die "Backup archive is missing or empty: $ARCHIVE"

log "Testing gzip integrity"
if ! gzip -t "$ARCHIVE"; then
  die "gzip integrity check failed: $ARCHIVE"
fi

log "Testing tar archive structure"
if ! tar -tzf "$ARCHIVE" >/dev/null; then
  die "Backup archive structure/integrity check failed: $ARCHIVE"
fi

log "Creating detached SHA-256 checksum"

ARCHIVE_ABS="$(realpath "$ARCHIVE")"
CHECKSUM="${ARCHIVE_ABS}.sha256"

[[ -f "$ARCHIVE_ABS" ]] || die "Archive not found: $ARCHIVE_ABS"

if ! sha256sum "$ARCHIVE_ABS" > "$CHECKSUM"; then
    die "Failed to create archive checksum."
fi

chmod 600 "$ARCHIVE_ABS" "$CHECKSUM"

log "SHA-256 checksum created: $CHECKSUM"

# Cleanup working directory only after archive verification succeeds.
rm -rf "$WORK"

# Retention
mapfile -t old < <(ls -1t "$BACKUP_ROOT"/server-backup-"$HOST"-*.tar.gz 2>/dev/null | tail -n +"$((RETENTION+1))")
for f in "${old[@]:-}"; do
  [[ -f "$f" ]] || continue
  rm -f -- "$f" "$f.sha256"
done

log "Backup completed successfully."
log "Archive: $ARCHIVE"
log "Checksum: ${ARCHIVE}.sha256"
if (( ERRORS > 0 )); then
  log "Completed with $ERRORS non-fatal warning(s). Review backup.log before relying on the backup."
fi
exit 0