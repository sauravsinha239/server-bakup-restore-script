#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# Production server disaster-recovery backup.
# Auto-detects OS, installs missing tools, loads local backup.conf, 
# and prompts interactively for usernames (with Enter for default) and passwords.
# Run as root.

SCRIPT_VERSION="1.4.0"
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

BACKUP_ROOT="${BACKUP_ROOT:-~/server-backups}"
RETENTION="${RETENTION:-8}"
STAMP="$(date +%Y-%m-%d_%H%M%S)"
HOST="$(hostname -s 2>/dev/null || hostname)"
WORK="${BACKUP_ROOT}/.work-${HOST}-${STAMP}"
TREE="${WORK}/server-backup"
ARCHIVE="${BACKUP_ROOT}/server-backup-${HOST}-${STAMP}.tar.gz"
LOG="${WORK}/backup.log"
MANIFEST="${TREE}/MANIFEST.sha256"
ERRORS=0

mkdir -p "$TREE" "$BACKUP_ROOT"
exec > >(tee -a "$LOG") 2>&1

copy_if_exists() {
  local src="$1" dst="$2"
  [[ -e "$src" ]] || return 0
  mkdir -p "$(dirname "$TREE/$dst")"
  cp -a "$src" "$TREE/$dst"
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

# ========================================================
# 2. Main Backup Execution
# ========================================================
log "Starting server backup v${SCRIPT_VERSION}"
log "Host: $HOST"
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
      mongosh "$MONGO_URI" --quiet --eval 'db.adminCommand({listDatabases:1}).databases.map(x=>x.name).join("\n")' \
        > "$TREE/MONGODB/database-list.txt" 2>/dev/null || true
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

    if ! sqlcmd "${SQLCMD_ARGS[@]}" -Q \
      "BACKUP DATABASE [$qdb]
       TO DISK = N'$bakpath'
       WITH INIT, CHECKSUM, COMPRESSION, STATS=5;
       RESTORE VERIFYONLY FROM DISK = N'$bakpath';" \
      > "$TREE/MSSQL/${safe}-backup.log" 2>&1; then
      die "MSSQL backup/verification failed: $db. Aborting backup."
    fi

    [[ -s "$bakpath" ]] ||
      die "MSSQL backup file is missing or empty: $bakpath"

    cp -a "$bakpath" "$TREE/MSSQL/bak/" ||
      die "Failed to copy MSSQL backup into archive tree: $db"

    rm -f "$bakpath" ||
      die "Failed to remove temporary MSSQL backup file: $bakpath"
  done < "$TREE/MSSQL/database-list.txt"

  unset MSSQL_PASSWORD
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
  echo
  echo "Detected commands:"
  for x in nginx psql pg_dump pg_dumpall pg_isready mongodump mongosh sqlcmd docker cscli ufw dotnet pacman dpkg; do
    printf '%-12s %s\n' "$x" "$(command -v "$x" 2>/dev/null || echo NOT-INSTALLED)"
  done
} > "$TREE/backup-info.txt"

# ---------- Checksums and archive ----------
log "Creating checksums"
(
  cd "$TREE"
  find . -type f ! -name 'MANIFEST.sha256' -print0 |
    sort -z |
    xargs -0 sha256sum > "$MANIFEST"
)

log "Creating archive"
if ! tar --acls --xattrs --numeric-owner -czf "$ARCHIVE" -C "$WORK" server-backup backup.log; then
  die "Failed to create backup archive: $ARCHIVE"
fi

[[ -s "$ARCHIVE" ]] || die "Backup archive is missing or empty: $ARCHIVE"

log "Verifying archive integrity"
if ! tar -tzf "$ARCHIVE" >/dev/null; then
  die "Backup archive integrity check failed: $ARCHIVE"
fi

if ! sha256sum "$ARCHIVE" > "${ARCHIVE}.sha256"; then
  die "Failed to create archive checksum."
fi

chmod 600 "$ARCHIVE" "${ARCHIVE}.sha256"

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