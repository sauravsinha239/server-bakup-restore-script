#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# Production disaster recovery restore helper with verification and fail-fast database restore.
# Usage:
#   sudo ./server-restore.sh /root/server-backups/server-backup-HOST-DATE.tar.gz

ARCHIVE="${1:-}"
[[ -n "$ARCHIVE" && -f "$ARCHIVE" ]] || { echo "Usage: $0 backup.tar.gz"; exit 1; }
[[ $EUID -eq 0 ]] || { echo "Run as root."; exit 1; }

echo "Verifying backup archive..."
if ! tar -tzf "$ARCHIVE" >/dev/null; then
  echo "ERROR: Backup archive is corrupt or unreadable."
  exit 1
fi

ARCHIVE_SHA256="${ARCHIVE}.sha256"
if [[ -f "$ARCHIVE_SHA256" ]]; then
  echo "Verifying SHA256 checksum..."
  if ! (cd "$(dirname "$ARCHIVE")" && sha256sum -c "$(basename "$ARCHIVE_SHA256")"); then
    echo "ERROR: Backup SHA256 verification failed. Restore aborted."
    exit 1
  fi
else
  echo "WARNING: No SHA256 sidecar found; archive integrity was checked but authenticity was not."
fi


RESTORE_ROOT="${RESTORE_ROOT:-/var/tmp/server-restore-$(date +%Y%m%d_%H%M%S)}"

# Keep extracted files by default for forensic/recovery inspection.
# Set CLEANUP_RESTORE=1 to delete them after a successful restore.
cleanup() {
  local rc=$?
  if [[ -d "$RESTORE_ROOT" ]]; then
    if [[ "${CLEANUP_RESTORE:-0}" == "1" && "$rc" -eq 0 ]]; then
      rm -rf "$RESTORE_ROOT"
      echo "Temporary restore files cleaned up."
    else
      echo "Restore files retained at: $RESTORE_ROOT"
    fi
  fi
  exit "$rc"
}
trap cleanup EXIT

# Default component flags
RESTORE_WWW=1
RESTORE_NGINX=1
RESTORE_POSTGRES=1
RESTORE_MONGO=1
RESTORE_MSSQL=0
RESTORE_SYSTEMD=1
RESTORE_CROWDSEC=1
RESTORE_DOCKER_VOLUMES=1
RESTORE_FIREWALL=0
RESTORE_SSH=0

# ==============================================================================
# 1. HELPER & BOOTSTRAP FUNCTIONS
# ==============================================================================

prompt_yes_no() {
  local prompt="$1"
  local default="${2:-N}"
  local response
  read -r -p "$prompt [y/N]: " response
  response="${response:-$default}"
  [[ "$response" =~ ^[Yy]$ ]]
}

bootstrap_whiptail() {
  if command -v whiptail >/dev/null 2>&1; then
    return 0
  fi

  echo "whiptail not found. Installing to provide visual checklist..."
  [[ -f /etc/os-release ]] || return 1
  # shellcheck disable=SC1091
  source /etc/os-release

  case "$ID" in
    debian|ubuntu)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y && apt-get install -y --no-install-recommends whiptail curl gnupg
      ;;
    arch)
      pacman -Sy --noconfirm --needed libnewt curl
      ;;
    *)
      return 1
      ;;
  esac
}

run_tui_checklist() {
  whiptail --title "Disaster Recovery Package Selection" \
    --checklist "Select services to install & restore (Space to toggle, Enter to confirm):" \
    20 72 8 \
    "WWW"      "Restore /var/www web data" ON \
    "NGINX"    "Nginx Web Server" ON \
    "POSTGRES" "PostgreSQL Server & Client" ON \
    "MONGO"    "MongoDB Database Tools" ON \
    "MSSQL"    "Microsoft SQL Server Client (sqlcmd)" OFF \
    "DOCKER"   "Docker Engine & Volume tooling" ON \
    "FIREWALL" "UFW & Iptables / Nftables" OFF \
    "SSH"      "OpenSSH Server configuration" OFF \
    3>&1 1>&2 2>&3
}

interactive_selection() {
  echo
  if ! prompt_yes_no "Do you want to configure and install packages before restoring?" "Y"; then
    echo "Skipping package provisioning. Using existing system packages..."
    return 0
  fi

  bootstrap_whiptail || true

  if command -v whiptail >/dev/null 2>&1; then
    local choices
    choices=$(run_tui_checklist) || { echo "Setup aborted by user."; exit 1; }

    # Reset restore flags based on visual choices
    RESTORE_WWW=0; RESTORE_NGINX=0; RESTORE_POSTGRES=0; RESTORE_MONGO=0
    RESTORE_MSSQL=0; RESTORE_DOCKER_VOLUMES=0; RESTORE_FIREWALL=0; RESTORE_SSH=0

    for item in $choices; do
      case "${item//\"/}" in
        WWW)      RESTORE_WWW=1 ;;
        NGINX)    RESTORE_NGINX=1 ;;
        POSTGRES) RESTORE_POSTGRES=1 ;;
        MONGO)    RESTORE_MONGO=1 ;;
        MSSQL)    RESTORE_MSSQL=1 ;;
        DOCKER)   RESTORE_DOCKER_VOLUMES=1 ;;
        FIREWALL) RESTORE_FIREWALL=1 ;;
        SSH)      RESTORE_SSH=1 ;;
      esac
    done
  else
    echo "Whiptail unavailable. Using step-by-step CLI prompts:"
    prompt_yes_no "Restore /var/www?" "Y" && RESTORE_WWW=1 || RESTORE_WWW=0
    prompt_yes_no "Install & restore Nginx?" "Y" && RESTORE_NGINX=1 || RESTORE_NGINX=0
    prompt_yes_no "Install & restore PostgreSQL?" "Y" && RESTORE_POSTGRES=1 || RESTORE_POSTGRES=0
    prompt_yes_no "Install & restore MongoDB tools?" "Y" && RESTORE_MONGO=1 || RESTORE_MONGO=0
    prompt_yes_no "Install & restore Microsoft SQL Server tools?" "N" && RESTORE_MSSQL=1 || RESTORE_MSSQL=0
    prompt_yes_no "Install & restore Docker?" "Y" && RESTORE_DOCKER_VOLUMES=1 || RESTORE_DOCKER_VOLUMES=0
    prompt_yes_no "Install & restore Firewall rules (UFW/nftables)?" "N" && RESTORE_FIREWALL=1 || RESTORE_FIREWALL=0
    prompt_yes_no "Install & restore OpenSSH Server?" "N" && RESTORE_SSH=1 || RESTORE_SSH=0
  fi

  install_selected_packages
}

install_selected_packages() {
  [[ -f /etc/os-release ]] || { echo "Cannot verify OS release; skipping install."; return 0; }
  # shellcheck disable=SC1091
  source /etc/os-release
  echo "Installing required packages for $ID..."

  case "$ID" in
    debian|ubuntu)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      local pkgs=(tar gzip curl)
      [[ "$RESTORE_NGINX" == 1 ]]          && pkgs+=(nginx)
      [[ "$RESTORE_POSTGRES" == 1 ]]       && pkgs+=(postgresql postgresql-client)
      [[ "$RESTORE_DOCKER_VOLUMES" == 1 ]] && pkgs+=(docker.io)
      [[ "$RESTORE_FIREWALL" == 1 ]]       && pkgs+=(ufw iptables nftables)
      [[ "$RESTORE_SSH" == 1 ]]            && pkgs+=(openssh-server)
      apt-get install -y --no-install-recommends "${pkgs[@]}" 2>/dev/null || apt-get install -y "${pkgs[@]}"
      if [[ "$RESTORE_MONGO" == 1 ]] && ! command -v mongorestore >/dev/null 2>&1; then
        echo "WARNING: mongorestore is not installed. MongoDB restore cannot proceed."
      fi

      if [[ "$RESTORE_MSSQL" == 1 ]] && ! command -v sqlcmd >/dev/null 2>&1; then
        echo "Configuring Microsoft SQL tools repository..."
        curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor --yes -o /usr/share/keyrings/microsoft-prod.gpg
        curl -fsSL "https://packages.microsoft.com/config/$ID/$VERSION_ID/prod.list" > /etc/apt/sources.list.d/mssql-release.list
        apt-get update -y
        ACCEPT_EULA=Y apt-get install -y mssql-tools18 unixodbc-dev
        ln -sf /opt/mssql-tools18/bin/sqlcmd /usr/local/bin/sqlcmd
      fi
      ;;

    arch)
      pacman -Sy --noconfirm
      local pkgs=(tar gzip curl)
      [[ "$RESTORE_NGINX" == 1 ]]          && pkgs+=(nginx)
      [[ "$RESTORE_POSTGRES" == 1 ]]       && pkgs+=(postgresql)
      [[ "$RESTORE_DOCKER_VOLUMES" == 1 ]] && pkgs+=(docker)
      [[ "$RESTORE_FIREWALL" == 1 ]]       && pkgs+=(ufw iptables-nft nftables)
      [[ "$RESTORE_SSH" == 1 ]]            && pkgs+=(openssh)
      [[ "$RESTORE_MONGO" == 1 ]]          && pkgs+=(mongodb-tools)

      pacman -S --noconfirm --needed "${pkgs[@]}"

      if [[ "$RESTORE_POSTGRES" == 1 && ! -d /var/lib/postgres/data/base ]]; then
        echo "Initializing default PostgreSQL data cluster for Arch..."
        sudo -u postgres initdb --locale=C.UTF-8 -D /var/lib/postgres/data
      fi
      ;;
  esac
}

# ==============================================================================
# 2. RUN SELECTION & EXTRACT ARCHIVE
# ==============================================================================

interactive_selection

mkdir -p "$RESTORE_ROOT"
echo "Extracting backup archive to $RESTORE_ROOT..."
tar -xzf "$ARCHIVE" -C "$RESTORE_ROOT"
TREE="$RESTORE_ROOT/server-backup"
[[ -d "$TREE" ]] || { echo "Invalid backup archive: missing 'server-backup' folder."; exit 1; }

echo "=== SERVER RESTORE ==="
echo "Source: $ARCHIVE"
echo "Working directory: $RESTORE_ROOT"

if [[ -f "$TREE/MANIFEST.sha256" ]]; then
  echo "Verifying backup file manifest..."
  if ! (cd "$TREE" && sha256sum -c MANIFEST.sha256); then
    echo "ERROR: Backup manifest verification failed. Restore aborted."
    exit 1
  fi
else
  echo "WARNING: Backup manifest is missing."
fi

# ==============================================================================
# 3. RESTORATION WORKFLOW
# ==============================================================================

# [1] WWW
if [[ "$RESTORE_WWW" == 1 && -f "$TREE/WWW/var-www.tar.gz" ]]; then
  echo "[1] Restoring /var/www"
  if [[ -d /var/www ]]; then
    mv /var/www "/var/www.before-restore-$(date +%s)"
  fi
  mkdir -p /var/www
  tar --acls --xattrs --numeric-owner -xzf "$TREE/WWW/var-www.tar.gz" -C /var
  test -d /var/www || { echo "ERROR: /var/www restore failed."; exit 1; }
fi

# [2] Nginx
if [[ "$RESTORE_NGINX" == 1 && -d "$TREE/NGINX/etc-nginx" ]]; then
  echo "[2] Restoring Nginx configuration"
  systemctl stop nginx 2>/dev/null || true
  nginx_backup="/etc/nginx.before-restore-$(date +%s)"
  if [[ -d /etc/nginx ]]; then
    mv /etc/nginx "$nginx_backup"
  fi
  mkdir -p /etc/nginx
  cp -a "$TREE/NGINX/etc-nginx/." /etc/nginx/
  if ! nginx -t; then
    echo "ERROR: Restored Nginx configuration is invalid. Rolling back."
    rm -rf /etc/nginx
    [[ -d "$nginx_backup" ]] && mv "$nginx_backup" /etc/nginx
    systemctl start nginx 2>/dev/null || true
    exit 1
  fi
  systemctl enable nginx
  systemctl restart nginx
  systemctl is-active --quiet nginx || { echo "ERROR: Nginx failed to start."; exit 1; }
fi

# [3] Custom systemd units
if [[ "$RESTORE_SYSTEMD" == 1 ]]; then
  echo "[3] Restoring custom systemd units"
  mkdir -p /etc/systemd/system /etc/systemd/user
  for d in etc-systemd-system etc-systemd-user; do
    src="$TREE/SYSTEMD/$d"
    [[ -d "$src" ]] || continue
    case "$d" in
      etc-systemd-system) cp -a "$src/." /etc/systemd/system/ ;;
      etc-systemd-user)   cp -a "$src/." /etc/systemd/user/ ;;
    esac
  done
  systemctl daemon-reload
fi

# [4] CrowdSec
if [[ "$RESTORE_CROWDSEC" == 1 && -d "$TREE/CROWDSEC/etc-crowdsec" ]]; then
  echo "[4] Restoring CrowdSec configuration"
  systemctl stop crowdsec 2>/dev/null || true
  [[ -d /etc/crowdsec ]] && mv /etc/crowdsec "/etc/crowdsec.before-restore-$(date +%s)" || true
  mkdir -p /etc/crowdsec
  cp -a "$TREE/CROWDSEC/etc-crowdsec/." /etc/crowdsec/
  systemctl daemon-reload
  systemctl enable crowdsec 2>/dev/null || true
  systemctl start crowdsec 2>/dev/null || true
fi

# [5] PostgreSQL
if [[ "$RESTORE_POSTGRES" == 1 && -d "$TREE/POSTGRES/databases" ]]; then
  echo "[5] Restoring PostgreSQL"

  command -v pg_restore >/dev/null 2>&1 || { echo "ERROR: pg_restore is required."; exit 1; }
  command -v psql >/dev/null 2>&1 || { echo "ERROR: psql is required."; exit 1; }

  systemctl enable postgresql 2>/dev/null || true
  systemctl start postgresql
  systemctl is-active --quiet postgresql || { echo "ERROR: PostgreSQL failed to start."; exit 1; }

  # Restore roles/tablespaces first. If globals fail, permissions/ownership may be incomplete.
  if [[ -f "$TREE/POSTGRES/globals.sql" ]]; then
    echo "  Restoring PostgreSQL globals..."
    if ! sudo -u postgres psql -v ON_ERROR_STOP=1 -f "$TREE/POSTGRES/globals.sql"; then
      echo "ERROR: PostgreSQL globals restore failed. Aborting."
      exit 1
    fi
  fi

  # Prefer the database-list from the backup if available. The dump filename is
  # sanitized by the backup script, so for ordinary names it is identical.
  shopt -s nullglob
  dumps=( "$TREE"/POSTGRES/databases/*.dump )
  ((${#dumps[@]} > 0)) || { echo "ERROR: No PostgreSQL database dumps found."; exit 1; }

  for dump in "${dumps[@]}"; do
    filebase="$(basename "$dump" .dump)"
    # The backup script sanitizes only characters outside [A-Za-z0-9_.-].
    # Recover the exact database name from database-list when possible.
    db="$filebase"
    if [[ -f "$TREE/POSTGRES/database-list.txt" ]]; then
      candidate="$(grep -Fx "$filebase" "$TREE/POSTGRES/database-list.txt" | head -n1 || true)"
      [[ -n "$candidate" ]] && db="$candidate"
    fi

    echo "  Restoring database: $db"

    # SQL identifier and string escaping.
    db_ident="${db//\"/\"\"}"
    db_lit="${db//\'/\'\'}"

    if ! sudo -u postgres psql -v ON_ERROR_STOP=1 -tAc \
      "SELECT 1 FROM pg_database WHERE datname='$db_lit';" | grep -q '^1$'; then
      echo "    Creating database..."
      if ! sudo -u postgres psql -v ON_ERROR_STOP=1 -c "CREATE DATABASE \"$db_ident\";"; then
        echo "ERROR: Could not create PostgreSQL database: $db"
        exit 1
      fi
    fi

    # Validate the custom-format dump before destructive restore.
    if ! sudo -u postgres pg_restore -l "$dump" >/dev/null; then
      echo "ERROR: Invalid PostgreSQL dump: $dump"
      exit 1
    fi

    # Restore into the existing DB. --clean removes objects contained in the dump.
    if ! sudo -u postgres pg_restore \
      --clean --if-exists --no-owner --no-acl \
      --exit-on-error \
      --dbname="$db" "$dump"; then
      echo "ERROR: pg_restore failed for database: $db"
      exit 1
    fi
  done
  shopt -u nullglob
fi

# [6] MongoDB
if [[ "$RESTORE_MONGO" == 1 && -f "$TREE/MONGODB/mongodb.archive.gz" ]]; then
  echo "[6] Restoring MongoDB"

  command -v mongorestore >/dev/null 2>&1 || {
    echo "ERROR: mongorestore is required for MongoDB restore."
    exit 1
  }

  systemctl enable mongod 2>/dev/null || true
  systemctl start mongod
  systemctl is-active --quiet mongod || { echo "ERROR: MongoDB failed to start."; exit 1; }

  MONGO_URI="${MONGO_URI:-mongodb://127.0.0.1:27017}"

  if ! mongorestore --uri="$MONGO_URI" \
      --archive="$TREE/MONGODB/mongodb.archive.gz" \
      --gzip --drop --stopOnError; then
    echo "ERROR: MongoDB restore failed. Aborting."
    exit 1
  fi
fi

# [7] MSSQL
if [[ "$RESTORE_MSSQL" == 1 && -d "$TREE/MSSQL/bak" ]]; then
  echo "[7] Restoring Microsoft SQL Server databases"

  command -v sqlcmd >/dev/null 2>&1 || { echo "ERROR: sqlcmd is required."; exit 1; }

  systemctl enable mssql-server 2>/dev/null || true
  systemctl start mssql-server
  systemctl is-active --quiet mssql-server || { echo "ERROR: MSSQL failed to start."; exit 1; }

  prompt_yes_no "Use SQL authentication (instead of integrated authentication)?" "Y" && {
    read -r -p "MSSQL username [sa]: " MSSQL_USER
    MSSQL_USER="${MSSQL_USER:-sa}"
    read -r -s -p "MSSQL password: " MSSQL_PASSWORD
    echo
  } || {
    MSSQL_USER=""
    MSSQL_PASSWORD=""
  }

  SQLCMD_ARGS=(-S "${MSSQL_SERVER:-127.0.0.1,1433}" -C -b)
  [[ -n "${MSSQL_USER:-}" ]] && SQLCMD_ARGS+=(-U "$MSSQL_USER" -P "$MSSQL_PASSWORD")

  if ! sqlcmd "${SQLCMD_ARGS[@]}" -Q "SELECT @@SERVERNAME;" >/dev/null; then
    echo "ERROR: MSSQL connection/authentication failed. Aborting."
    exit 1
  fi

  shopt -s nullglob
  baks=( "$TREE"/MSSQL/bak/*.bak )
  ((${#baks[@]} > 0)) || { echo "ERROR: No MSSQL .bak files found."; exit 1; }

  for bak in "${baks[@]}"; do
    db="$(basename "$bak" .bak)"
    db_ident="${db//]/]]}"
    bak_lit="${bak//\'/\'\'}"

    echo "  Verifying backup: $db"
    if ! sqlcmd "${SQLCMD_ARGS[@]}" -Q \
      "RESTORE VERIFYONLY FROM DISK=N'$bak_lit';" >/dev/null; then
      echo "ERROR: MSSQL .bak verification failed: $db"
      exit 1
    fi

    echo "  Restoring database: $db"
    if ! sqlcmd "${SQLCMD_ARGS[@]}" -Q \
      "IF DB_ID(N'${db//\'/\'\'}') IS NOT NULL
         ALTER DATABASE [$db_ident] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
       RESTORE DATABASE [$db_ident]
         FROM DISK=N'$bak_lit'
         WITH REPLACE, RECOVERY, STATS=5;
       ALTER DATABASE [$db_ident] SET MULTI_USER;" ; then
      echo "ERROR: MSSQL restore failed for database: $db"
      exit 1
    fi

    # Confirm the database is online after restore.
    state="$(sqlcmd "${SQLCMD_ARGS[@]}" -h -1 -W -Q \
      "SET NOCOUNT ON; SELECT state_desc FROM sys.databases WHERE name=N'${db//\'/\'\'}';" |
      tr -d '\r' | xargs || true)"
    [[ "$state" == "ONLINE" ]] || {
      echo "ERROR: MSSQL database '$db' is not ONLINE after restore (state: ${state:-unknown})."
      exit 1
    }
  done
  shopt -u nullglob
fi

# [8] Docker named volumes
if [[ "$RESTORE_DOCKER_VOLUMES" == 1 && -d "$TREE/DOCKER/volumes" && $(command -v docker 2>/dev/null || true) ]]; then
  echo "[8] Restoring Docker named volumes"
  systemctl start docker 2>/dev/null || true
  while IFS= read -r archive; do
    [[ -f "$archive" ]] || continue
    vol="$(basename "$archive" .tar.gz)"
    docker volume inspect "$vol" >/dev/null 2>&1 || docker volume create "$vol" >/dev/null
    docker run --rm -v "$vol":/data -v "$(dirname "$archive")":/backup alpine \
      sh -c "rm -rf /data/* /data/.[!.]* /data/..?* 2>/dev/null || true; tar xzf /backup/$(basename "$archive") -C /data"
  done < <(find "$TREE/DOCKER/volumes" -type f -name '*.tar.gz' -print)
fi

# [9] Firewall (Opt-in)
if [[ "$RESTORE_FIREWALL" == 1 ]]; then
  echo "[9] Restoring firewall"
  if command -v ufw >/dev/null && [[ -d "$TREE/FIREWALL/etc-ufw" ]]; then
    mkdir -p /etc/ufw
    cp -a "$TREE/FIREWALL/etc-ufw/." /etc/ufw/
    ufw --force enable || true
  elif command -v nft >/dev/null && [[ -f "$TREE/FIREWALL/nftables-ruleset.txt" ]]; then
    nft -f "$TREE/FIREWALL/nftables-ruleset.txt" || echo "WARNING: nftables restore failed."
  elif command -v iptables-restore >/dev/null && [[ -f "$TREE/FIREWALL/iptables.rules" ]]; then
    iptables-restore < "$TREE/FIREWALL/iptables.rules" || echo "WARNING: iptables restore failed."
  fi
fi

# [10] SSH (Opt-in)
if [[ "$RESTORE_SSH" == 1 && -d "$TREE/SSH/etc-ssh" ]]; then
  echo "[10] Restoring SSH configuration"
  cp -a /etc/ssh "/etc/ssh.before-restore-$(date +%s)" 2>/dev/null || true
  mkdir -p /etc/ssh
  cp -a "$TREE/SSH/etc-ssh/." /etc/ssh/
  if sshd -t; then
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
  else
    echo "ERROR: sshd configuration invalid."
    exit 2
  fi
fi

echo
echo "=== RESTORE COMPLETE ==="
echo "Services status:"
systemctl --failed --no-pager || true

failed_count="$(systemctl --failed --no-legend --plain 2>/dev/null | grep -c . || true)"
if [[ "$failed_count" -gt 0 ]]; then
  echo "ERROR: $failed_count systemd unit(s) are failed after restore."
  echo "Review: systemctl --failed"
  exit 2
fi

echo "Restore completed successfully."
echo "Temporary extracted backup: $RESTORE_ROOT"