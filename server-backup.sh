#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# Production server disaster-recovery backup with OS detection & dependency resolution.
# Run as root. Review BACKUP_ROOT and DB credentials before first use.

SCRIPT_VERSION="1.2.0"
BACKUP_ROOT="${BACKUP_ROOT:-/root/server-backups}"
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

log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
warn(){ log "WARNING: $*"; ERRORS=$((ERRORS+1)); }
die(){ log "FATAL: $*"; exit 1; }
need_root(){ [[ $EUID -eq 0 ]] || die "Run as root."; }
cmd(){ command -v "$1" >/dev/null 2>&1; }

copy_if_exists() {
  local src="$1" dst="$2"
  [[ -e "$src" ]] || return 0
  mkdir -p "$(dirname "$TREE/$dst")"
  cp -a "$src" "$TREE/$dst"
}

# ==============================================================================
# OS Detection & Prerequisite Provisioning
# ==============================================================================
detect_os() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_LIKE="${ID_LIKE:-}"
  else
    die "Cannot detect operating system (/etc/os-release missing)."
  fi

  case "$OS_ID" in
    ubuntu|debian)
      OS_FAMILY="debian"
      ;;
    arch|manjaro|endeavouros)
      OS_FAMILY="arch"
      ;;
    *)
      if [[ "$OS_LIKE" =~ (ubuntu|debian) ]]; then
        OS_FAMILY="debian"
      elif [[ "$OS_LIKE" =~ (arch) ]]; then
        OS_FAMILY="arch"
      else
        die "Unsupported OS family: $OS_ID ($OS_LIKE). Supported: Ubuntu/Debian, Arch Linux."
      fi
      ;;
  esac
  log "Detected OS: $NAME ($OS_FAMILY family)"
}

install_missing_tools() {
  log "Evaluating required dump utilities..."

  # Track if apt-get update or pacman -Sy has been run
  local pkg_updated=0

  pkg_install() {
    local pkgs=("$@")
    if [[ "$OS_FAMILY" == "debian" ]]; then
      if (( pkg_updated == 0 )); then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y
        pkg_updated=1
      fi
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${pkgs[@]}"
    elif [[ "$OS_FAMILY" == "arch" ]]; then
      if (( pkg_updated == 0 )); then
        pacman -Sy --noconfirm
        pkg_updated=1
      fi
      pacman -S --noconfirm --needed "${pkgs[@]}"
    fi
  }

  # 1. Base archive utilities
  local base_missing=()
  for c in tar gzip sha256sum; do
    cmd "$c" || base_missing+=("$c")
  done
  if (( ${#base_missing[@]} > 0 )); then
    log "Installing missing base utilities: ${base_missing[*]}"
    if [[ "$OS_FAMILY" == "debian" ]]; then
      pkg_install tar gzip coreutils
    else
      pkg_install tar gzip coreutils
    fi
  fi

  # 2. PostgreSQL tools: if postgres is present but pg_dump/psql is missing
  if [[ -d /etc/postgresql ]] || systemctl list-unit-files 2>/dev/null | grep -q '^postgresql'; then
    if ! cmd pg_dump || ! cmd psql; then
      log "PostgreSQL service detected without client tools. Installing..."
      if [[ "$OS_FAMILY" == "debian" ]]; then
        pkg_install postgresql-client
      else
        pkg_install postgresql-libs
      fi
    fi
  fi

  # 3. MongoDB tools: if mongod is present/configured but mongodump is missing
  if [[ -f /etc/mongod.conf ]] || [[ -d /etc/mongod.conf.d ]] || systemctl list-unit-files 2>/dev/null | grep -q '^mongod'; then
    if ! cmd mongodump; then
      log "MongoDB detected without mongodump. Installing mongo-tools..."
      if [[ "$OS_FAMILY" == "debian" ]]; then
        pkg_install mongo-tools
      else
        # In Arch, official repos package mongo-tools as mongodb-tools
        pkg_install mongodb-tools || warn "Could not install mongodb-tools via pacman (may require AUR package)."
      fi
    fi
  fi

  # 4. MSSQL tools: if mssql-server is installed/running but sqlcmd is missing
  if systemctl list-unit-files 2>/dev/null | grep -q '^mssql-server\.service' || [[ -d /var/opt/mssql ]]; then
    if ! cmd sqlcmd; then
      log "MSSQL Server detected without sqlcmd. Attempting installation..."
      if [[ "$OS_FAMILY" == "debian" ]]; then
        if ! apt-cache show mssql-tools18 >/dev/null 2>&1 && ! apt-cache show mssql-tools >/dev/null 2>&1; then
          cmd curl || pkg_install curl ca-certificates gnupg
          curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /usr/share/keyrings/microsoft-prod.gpg
          curl -fsSL "https://packages.microsoft.com/config/ubuntu/${VERSION_ID:-22.04}/prod.list" \
            > /etc/apt/sources.list.d/mssql-release.list
          apt-get update -y
        fi
        ACCEPT_EULA=Y apt-get install -y --no-install-recommends mssql-tools18 unixodbc-dev || \
        ACCEPT_EULA=Y apt-get install -y --no-install-recommends mssql-tools unixodbc-dev || \
        warn "Could not auto-install mssql-tools via APT."
      else
        # Arch official repositories do not maintain mssql-tools; check AUR or go-sqlcmd binary fallback
        if cmd yay; then
          yay -S --noconfirm mssql-tools || warn "Failed installing mssql-tools via yay."
        else
          warn "Arch Linux requires 'mssql-tools' from the AUR or the standalone sqlcmd utility."
        fi
      fi

      # Standardize binary PATH if installed to /opt/mssql-tools*/bin
      for p in /opt/mssql-tools18/bin /opt/mssql-tools/bin; do
        if [[ -x "$p/sqlcmd" ]]; then
          ln -sf "$p/sqlcmd" /usr/local/bin/sqlcmd
          export PATH="$PATH:$p"
          break
        fi
      done
    fi
  fi
}

need_root
detect_os
install_missing_tools

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
  pacman -Qe > "$TREE/PACKAGES/pacman-explicit.txt" || true
  pacman -Q > "$TREE/PACKAGES/pacman-all.txt" || true
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
if cmd psql || cmd pg_dumpall || [[ -d /etc/postgresql ]]; then
  mkdir -p "$TREE/POSTGRES/databases"
  if cmd psql; then
    sudo -u postgres psql -Atc 'SELECT datname FROM pg_database WHERE datallowconn AND NOT datistemplate ORDER BY 1;' \
      > "$TREE/POSTGRES/database-list.txt" 2>/dev/null || true
    sudo -u postgres pg_dumpall --globals-only > "$TREE/POSTGRES/globals.sql" 2>"$TREE/POSTGRES/globals.err" || warn "PostgreSQL globals dump failed"
    while IFS= read -r db; do
      [[ -n "$db" ]] || continue
      safe="${db//[^A-Za-z0-9_.-]/_}"
      if ! sudo -u postgres pg_dump -Fc --no-owner --no-acl "$db" > "$TREE/POSTGRES/databases/${safe}.dump" 2>"$TREE/POSTGRES/databases/${safe}.err"; then
        warn "PostgreSQL database dump failed: $db"
      fi
    done < "$TREE/POSTGRES/database-list.txt"
  fi
  copy_if_exists /etc/postgresql POSTGRES/etc-postgresql
  copy_if_exists /etc/postgresql-common POSTGRES/etc-postgresql-common
fi

# ---------- MongoDB ----------
if cmd mongodump || cmd mongosh || [[ -d /etc/mongod.conf.d ]] || [[ -f /etc/mongod.conf ]]; then
  mkdir -p "$TREE/MONGODB"
  copy_if_exists /etc/mongod.conf MONGODB/mongod.conf
  copy_if_exists /etc/mongod.conf.d MONGODB/mongod.conf.d
  if cmd mongodump; then
    MONGO_URI="${MONGO_URI:-mongodb://127.0.0.1:27017}"
    if ! mongodump --uri="$MONGO_URI" --archive="$TREE/MONGODB/mongodb.archive.gz" --gzip; then
      warn "MongoDB dump failed"
    fi
  else
    warn "MongoDB detected but mongodump is not installed"
  fi
  if cmd mongosh; then
    mongosh --quiet --eval 'db.adminCommand({listDatabases:1}).databases.map(x=>x.name).join("\n")' \
      > "$TREE/MONGODB/database-list.txt" 2>/dev/null || true
  fi
fi

# ---------- Microsoft SQL Server ----------
if cmd sqlcmd || systemctl list-unit-files 2>/dev/null | grep -q '^mssql-server\.service'; then
  mkdir -p "$TREE/MSSQL"
  systemctl status mssql-server --no-pager --full > "$TREE/MSSQL/service-status.txt" 2>&1 || true
  if cmd sqlcmd; then
    sqlcmd -S "${MSSQL_SERVER:-localhost}" \
      ${MSSQL_USER:+-U "$MSSQL_USER"} \
      ${MSSQL_PASSWORD:+-P "$MSSQL_PASSWORD"} \
      -Q "SELECT @@VERSION AS version;" \
      > "$TREE/MSSQL/version.txt" 2>&1 || true

    SQLCMD_SERVER="${MSSQL_SERVER:-localhost}"
    SQLCMD_ARGS=(-S "$SQLCMD_SERVER")
    [[ -n "${MSSQL_USER:-}" ]] && SQLCMD_ARGS+=(-U "$MSSQL_USER" -P "${MSSQL_PASSWORD:-}")
    sqlcmd "${SQLCMD_ARGS[@]}" -h -1 -W -Q \
      "SET NOCOUNT ON; SELECT name FROM sys.databases WHERE database_id > 4 AND state_desc='ONLINE';" \
      2>/dev/null | sed '/^[[:space:]]*$/d' > "$TREE/MSSQL/database-list.txt" || true

    MSSQL_BACKUP_DIR="${MSSQL_BACKUP_DIR:-/var/opt/mssql/backup}"
    mkdir -p "$TREE/MSSQL/bak"
    while IFS= read -r db; do
      [[ -n "$db" ]] || continue
      safe="${db//[^A-Za-z0-9_.-]/_}"
      qdb="${db//\'/\'\'}"
      bakpath="${MSSQL_BACKUP_DIR}/${safe}-${STAMP}.bak"
      if ! sqlcmd "${SQLCMD_ARGS[@]}" -b -Q \
        "BACKUP DATABASE [$qdb] TO DISK=N'$bakpath' WITH INIT, CHECKSUM, COMPRESSION, STATS=5;" \
        > "$TREE/MSSQL/${safe}-backup.log" 2>&1; then
        warn "MSSQL backup failed: $db"
        continue
      fi
      if [[ -f "$bakpath" ]]; then
        cp -a "$bakpath" "$TREE/MSSQL/bak/"
        rm -f "$bakpath"
      else
        warn "MSSQL backup file missing: $db"
      fi
    done < "$TREE/MSSQL/database-list.txt"
  else
    warn "MSSQL detected but sqlcmd is not installed"
  fi
  copy_if_exists /var/opt/mssql/MSSQL/MSSQL.conf MSSQL/MSSQL.conf
  copy_if_exists /etc/systemd/system/mssql-server.service.d MSSQL/mssql-systemd-override
fi

# ---------- Docker ----------
if cmd docker; then
  docker version > "$TREE/DOCKER/docker-version.txt" 2>&1 || true
  docker ps -a --no-trunc > "$TREE/DOCKER/containers.txt" 2>&1 || true
  docker images --digests > "$TREE/DOCKER/images.txt" 2>&1 || true
  docker network ls > "$TREE/DOCKER/networks.txt" 2>&1 || true
  docker volume ls > "$TREE/DOCKER/volumes.txt" 2>&1 || true
  docker compose version > "$TREE/DOCKER/compose-version.txt" 2>&1 || true
  docker inspect $(docker ps -aq) > "$TREE/DOCKER/container-inspect.json" 2>/dev/null || true
  docker volume inspect $(docker volume ls -q) > "$TREE/DOCKER/volume-inspect.json" 2>/dev/null || true
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
    tar --acls --xattrs --numeric-owner -czf "$TREE/SYSTEM/$(basename "$p").tar.gz" \
      --exclude='*/node_modules/*' --exclude='*/.git/*' -C / "$p" \
      || warn "$p backup failed"
  fi
done

# ---------- Environment/config inventory ----------
copy_if_exists /etc/apt APT/etc-apt
copy_if_exists /etc/pacman.d PACMAN/etc-pacman.d
copy_if_exists /etc/pacman.conf PACMAN/etc-pacman.conf
copy_if_exists /etc/environment SYSTEM/etc-environment
copy_if_exists /etc/profile.d SYSTEM/etc-profile.d
copy_if_exists /etc/sysctl.d SYSTEM/etc-sysctl.d
copy_if_exists /etc/NetworkManager NETWORK/etc-NetworkManager
copy_if_exists /etc/letsencrypt SECURITY/etc-letsencrypt
copy_if_exists /etc/ssl SECURITY/etc-ssl
copy_if_exists /etc/fail2ban SECURITY/etc-fail2ban

# ---------- Git/deployment metadata ----------
find /var/www /opt /srv -type d -name .git -prune -print 2>/dev/null |
  sed 's#/.git$##' > "$TREE/SYSTEM/git-repositories.txt" || true

# ---------- Service/package facts ----------
{
  echo "Backup version: $SCRIPT_VERSION"
  echo "Timestamp: $(date --iso-8601=seconds)"
  echo "Hostname: $HOST"
  echo "Kernel: $(uname -r)"
  echo "OS Family: $OS_FAMILY"
  echo "UID: $EUID"
  echo
  echo "Detected commands:"
  for x in nginx psql pg_dump pg_dumpall mongodump mongosh sqlcmd docker cscli ufw pacman dpkg dotnet; do
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
tar --acls --xattrs --numeric-owner -czf "$ARCHIVE" -C "$WORK" server-backup backup.log

sha256sum "$ARCHIVE" > "${ARCHIVE}.sha256"
chmod 600 "$ARCHIVE" "${ARCHIVE}.sha256"

rm -rf "$WORK"

# Retention
mapfile -t old < <(ls -1t "$BACKUP_ROOT"/server-backup-"$HOST"-*.tar.gz 2>/dev/null | tail -n +"$((RETENTION+1))")
for f in "${old[@]:-}"; do
  [[ -f "$f" ]] || continue
  rm -f -- "$f" "$f.sha256"
done

log "Backup completed."
log "Archive: $ARCHIVE"
log "Checksum: ${ARCHIVE}.sha256"
if (( ERRORS > 0 )); then
  log "Completed with $ERRORS warning(s). Review the backup before relying on it."
  exit 2
fi
exit 0