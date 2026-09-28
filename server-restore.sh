#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# Disaster recovery restore helper.
# Usage:
#   sudo ./server-restore.sh /root/server-backups/server-backup-HOST-DATE.tar.gz
# Optional:
#   RESTORE_WWW=1 RESTORE_NGINX=1 RESTORE_POSTGRES=1 RESTORE_MONGO=1 RESTORE_MSSQL=1 \
#   RESTORE_FIREWALL=0 ./server-restore.sh backup.tar.gz
#
# The script deliberately does NOT automatically replace a live firewall or SSH
# configuration. Those operations are opt-in to avoid locking you out.

ARCHIVE="${1:-}"
[[ -n "$ARCHIVE" && -f "$ARCHIVE" ]] || { echo "Usage: $0 backup.tar.gz"; exit 1; }
[[ $EUID -eq 0 ]] || { echo "Run as root."; exit 1; }

RESTORE_ROOT="${RESTORE_ROOT:-/var/tmp/server-restore-$(date +%Y%m%d_%H%M%S)}"
RESTORE_WWW="${RESTORE_WWW:-1}"
RESTORE_NGINX="${RESTORE_NGINX:-1}"
RESTORE_POSTGRES="${RESTORE_POSTGRES:-1}"
RESTORE_MONGO="${RESTORE_MONGO:-1}"
RESTORE_MSSQL="${RESTORE_MSSQL:-1}"
RESTORE_SYSTEMD="${RESTORE_SYSTEMD:-1}"
RESTORE_CROWDSEC="${RESTORE_CROWDSEC:-1}"
RESTORE_DOCKER_VOLUMES="${RESTORE_DOCKER_VOLUMES:-1}"
RESTORE_FIREWALL="${RESTORE_FIREWALL:-0}"
RESTORE_SSH="${RESTORE_SSH:-0}"

mkdir -p "$RESTORE_ROOT"
tar -xzf "$ARCHIVE" -C "$RESTORE_ROOT"
TREE="$RESTORE_ROOT/server-backup"
[[ -d "$TREE" ]] || { echo "Invalid backup archive."; exit 1; }

echo "=== SERVER RESTORE ==="
echo "Source: $ARCHIVE"
echo "Temporary directory: $RESTORE_ROOT"
echo
echo "IMPORTANT: restore onto a compatible OS/package stack."
echo "Firewall and SSH restoration are OFF by default."

# Verify internal manifest where possible.
if [[ -f "$TREE/MANIFEST.sha256" ]]; then
  (cd "$TREE" && sha256sum -c MANIFEST.sha256) || {
    echo "WARNING: checksum verification failed."
  }
fi

# WWW
if [[ "$RESTORE_WWW" == 1 && -f "$TREE/WWW/var-www.tar.gz" ]]; then
  echo "[1] Restoring /var/www"
  [[ -d /var/www ]] && mv /var/www "/var/www.before-restore-$(date +%s)" || true
  mkdir -p /var
  tar --acls --xattrs --numeric-owner -xzf "$TREE/WWW/var-www.tar.gz" -C /var
fi

# Nginx
if [[ "$RESTORE_NGINX" == 1 && -d "$TREE/NGINX/etc-nginx" ]]; then
  echo "[2] Restoring Nginx configuration"
  systemctl stop nginx 2>/dev/null || true
  [[ -d /etc/nginx ]] && mv /etc/nginx "/etc/nginx.before-restore-$(date +%s)" || true
  cp -a "$TREE/NGINX/etc-nginx" /etc/nginx
  nginx -t
  systemctl enable nginx
  systemctl restart nginx
fi

# systemd custom units
if [[ "$RESTORE_SYSTEMD" == 1 ]]; then
  echo "[3] Restoring custom systemd units"
  for d in etc-systemd-system etc-systemd-user; do
    src="$TREE/SYSTEMD/$d"
    [[ -d "$src" ]] || continue
    case "$d" in
      etc-systemd-system) cp -a "$src/." /etc/systemd/system/ ;;
      etc-systemd-user) cp -a "$src/." /etc/systemd/user/ ;;
    esac
  done
  systemctl daemon-reload
fi

# CrowdSec
if [[ "$RESTORE_CROWDSEC" == 1 && -d "$TREE/CROWDSEC/etc-crowdsec" ]]; then
  echo "[4] Restoring CrowdSec configuration"
  systemctl stop crowdsec 2>/dev/null || true
  [[ -d /etc/crowdsec ]] && mv /etc/crowdsec "/etc/crowdsec.before-restore-$(date +%s)" || true
  cp -a "$TREE/CROWDSEC/etc-crowdsec" /etc/crowdsec
  systemctl daemon-reload
  systemctl enable crowdsec 2>/dev/null || true
  systemctl start crowdsec 2>/dev/null || true
fi

# PostgreSQL
if [[ "$RESTORE_POSTGRES" == 1 && -d "$TREE/POSTGRES/databases" && -d /etc/postgresql ]]; then
  echo "[5] Restoring PostgreSQL"
  systemctl start postgresql
  if [[ -f "$TREE/POSTGRES/globals.sql" ]]; then
    sudo -u postgres psql -f "$TREE/POSTGRES/globals.sql" || echo "WARNING: globals restore reported errors."
  fi
  shopt -s nullglob
  for dump in "$TREE"/POSTGRES/databases/*.dump; do
    db="$(basename "$dump" .dump)"
    echo "  Restoring database: $db"
    # Create DB if it does not exist. pg_restore handles schema/data.
    sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname='${db//\'/\'\'}'" |
      grep -q 1 || sudo -u postgres createdb "$db"
    sudo -u postgres pg_restore --clean --if-exists --no-owner --dbname="$db" "$dump" ||
      echo "WARNING: pg_restore reported errors for $db."
  done
  shopt -u nullglob
fi

# MongoDB
if [[ "$RESTORE_MONGO" == 1 && -f "$TREE/MONGODB/mongodb.archive.gz" && $(command -v mongorestore 2>/dev/null || true) ]]; then
  echo "[6] Restoring MongoDB"
  systemctl start mongod 2>/dev/null || true
  MONGO_URI="${MONGO_URI:-mongodb://127.0.0.1:27017}"
  mongorestore --uri="$MONGO_URI" --archive="$TREE/MONGODB/mongodb.archive.gz" --gzip --drop ||
    echo "WARNING: mongorestore reported errors."
fi

# MSSQL
if [[ "$RESTORE_MSSQL" == 1 && -d "$TREE/MSSQL/bak" && $(command -v sqlcmd 2>/dev/null || true) ]]; then
  echo "[7] Restoring Microsoft SQL Server databases"
  systemctl start mssql-server 2>/dev/null || true
  SQLCMD_ARGS=(-S "${MSSQL_SERVER:-localhost}")
  [[ -n "${MSSQL_USER:-}" ]] && SQLCMD_ARGS+=(-U "$MSSQL_USER" -P "${MSSQL_PASSWORD:-}")
  for bak in "$TREE"/MSSQL/bak/*.bak; do
    [[ -f "$bak" ]] || continue
    db="$(basename "$bak" .bak)"
    echo "  Restoring database: $db"
    # Get logical file names first.
    mapfile -t logical < <(sqlcmd "${SQLCMD_ARGS[@]}" -h -1 -W -Q \
      "RESTORE FILELISTONLY FROM DISK=N'${bak//\'/\'/}'" 2>/dev/null |
      awk -F',' 'NF>=2 {gsub(/^[ \t]+|[ \t]+$/, "", $1); print $1}')
    # Safer generic restore: let SQL Server use MOVE paths derived from logical names.
    # For most standard Linux installations, DATA directories are /var/opt/mssql/data.
    if [[ "${#logical[@]}" -ge 1 ]]; then
      moves=""
      for logical_name in "${logical[@]}"; do
        safe="${logical_name//[^A-Za-z0-9_.-]/_}"
        moves+=" MOVE N'${logical_name//\'/\'\'}' TO N'/var/opt/mssql/data/${safe}.mdf',"
      done
      # The above cannot reliably distinguish log files from data files without
      # parsing FILELISTONLY columns; use SQL Server's default restore path where possible.
    fi
    sqlcmd "${SQLCMD_ARGS[@]}" -b -Q \
      "IF DB_ID(N'${db//\'/\'\'}') IS NOT NULL ALTER DATABASE [${db//]/]]}] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
       RESTORE DATABASE [${db//]/]]}] FROM DISK=N'${bak//\'/\'\'}' WITH REPLACE, RECOVERY, STATS=5;
       ALTER DATABASE [${db//]/]]}] SET MULTI_USER;" ||
      echo "WARNING: MSSQL restore reported errors for $db."
  done
fi

# Docker named volumes
if [[ "$RESTORE_DOCKER_VOLUMES" == 1 && -d "$TREE/DOCKER/volumes" && $(command -v docker 2>/dev/null || true) ]]; then
  echo "[8] Restoring Docker named volumes"
  while IFS= read -r archive; do
    [[ -f "$archive" ]] || continue
    vol="$(basename "$archive" .tar.gz)"
    docker volume inspect "$vol" >/dev/null 2>&1 || docker volume create "$vol" >/dev/null
    docker run --rm -v "$vol":/data -v "$(dirname "$archive")":/backup alpine \
      sh -c "rm -rf /data/* /data/.[!.]* /data/..?* 2>/dev/null || true; tar xzf /backup/$(basename "$archive") -C /data"
  done < <(find "$TREE/DOCKER/volumes" -type f -name '*.tar.gz' -print)
fi

# Firewall — opt-in because an incorrect rule can cut off SSH.
if [[ "$RESTORE_FIREWALL" == 1 ]]; then
  echo "[9] Restoring firewall — verify console access first"
  if command -v ufw >/dev/null && [[ -d "$TREE/FIREWALL/etc-ufw" ]]; then
    cp -a "$TREE/FIREWALL/etc-ufw/." /etc/ufw/
    ufw --force enable || true
  fi
  if command -v iptables-restore >/dev/null && [[ -f "$TREE/FIREWALL/iptables.rules" ]]; then
    iptables-restore < "$TREE/FIREWALL/iptables.rules" || echo "WARNING: IPv4 iptables restore failed."
  fi
  if command -v ip6tables-restore >/dev/null && [[ -f "$TREE/FIREWALL/ip6tables.rules" ]]; then
    ip6tables-restore < "$TREE/FIREWALL/ip6tables.rules" || echo "WARNING: IPv6 iptables restore failed."
  fi
  if command -v nft >/dev/null && [[ -f "$TREE/FIREWALL/nftables-ruleset.txt" ]]; then
    nft -f "$TREE/FIREWALL/nftables-ruleset.txt" || echo "WARNING: nftables restore failed."
  fi
fi

# SSH — opt-in. Test config before restart.
if [[ "$RESTORE_SSH" == 1 && -d "$TREE/SSH/etc-ssh" ]]; then
  echo "[10] Restoring SSH configuration — validating first"
  cp -a /etc/ssh "/etc/ssh.before-restore-$(date +%s)" 2>/dev/null || true
  cp -a "$TREE/SSH/etc-ssh/." /etc/ssh/
  if sshd -t; then
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
  else
    echo "ERROR: sshd configuration invalid. Restoring previous /etc/ssh is recommended."
    exit 2
  fi
fi

echo
echo "=== RESTORE FINISHED ==="
echo "Review:"
echo "  systemctl --failed"
echo "  systemctl status nginx postgresql mongod mssql-server crowdsec"
echo "  ss -tulpn"
echo "  nginx -t"
echo "Then verify application health and database connectivity."
echo "Temporary extracted backup: $RESTORE_ROOT"
