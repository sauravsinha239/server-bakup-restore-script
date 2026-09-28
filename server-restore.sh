#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# Production server disaster-recovery restore helper.
# Usage:
#   sudo ./server-restore.sh /path/to/server-backup-HOST-DATE.tar.gz
#
# Designed for the backup format produced by server-backup-all-db.sh.
#
# IMPORTANT:
# - Database restores are destructive when the target database already exists.
# - Nginx/SSL are validated before the new Nginx config is activated.
# - Firewall and SSH restoration are OFF by default.
# - Temporary extracted files are retained by default.

SCRIPT_VERSION="2.0.0"
ARCHIVE="${1:-}"

[[ -n "$ARCHIVE" && -f "$ARCHIVE" ]] || {
    echo "Usage: $0 /path/to/server-backup-HOST-DATE.tar.gz"
    exit 1
}
[[ $EUID -eq 0 ]] || {
    echo "ERROR: Run as root."
    exit 1
}

RESTORE_ROOT="${RESTORE_ROOT:-/var/tmp/server-restore-$(date +%Y%m%d_%H%M%S)}"
TREE=""
ERRORS=0
WARNINGS=0

# -------------------------------------------------------------------
# Logging / error handling
# -------------------------------------------------------------------

log() {
    printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

warn() {
    WARNINGS=$((WARNINGS + 1))
    log "WARNING: $*"
}

die() {
    log "FATAL: $*"
    exit 1
}

cmd() {
    command -v "$1" >/dev/null 2>&1
}

prompt_yes_no() {
    local prompt="$1"
    local default="${2:-N}"
    local response

    read -r -p "$prompt [y/N]: " response
    response="${response:-$default}"
    [[ "$response" =~ ^[Yy]$ ]]
}

prompt_with_default() {
    local var_name="$1"
    local label="$2"
    local default="$3"
    local current="${!var_name:-$default}"
    local input

    if [[ -t 0 ]]; then
        if [[ -n "$default" ]]; then
            read -r -p "$label [default: $default]: " input
        else
            read -r -p "$label [ENTER = none]: " input
        fi
        input="${input:-$default}"
    else
        input="$current"
    fi

    printf -v "$var_name" '%s' "$input"
}

prompt_password() {
    local var_name="$1"
    local label="$2"
    local current="${!var_name:-}"
    local input

    if [[ -n "$current" ]]; then
        return 0
    fi

    if [[ -t 0 ]]; then
        read -r -s -p "$label password: " input
        echo
        printf -v "$var_name" '%s' "$input"
    else
        printf -v "$var_name" '%s' ""
    fi
}

cleanup() {
    if [[ -d "$RESTORE_ROOT" ]]; then
        echo
        echo "Restore files retained at:"
        echo "  $RESTORE_ROOT"
        echo
        echo "Delete them manually after you have verified the restored server:"
        echo "  rm -rf -- '$RESTORE_ROOT'"
    fi
}
trap cleanup EXIT

# -------------------------------------------------------------------
# Restore selection
# -------------------------------------------------------------------

RESTORE_WWW=1
RESTORE_NGINX=1
RESTORE_POSTGRES=1
RESTORE_MONGO=1
RESTORE_MSSQL=0
RESTORE_SYSTEMD=1
RESTORE_CROWDSEC=1
RESTORE_DOCKER=1
RESTORE_FIREWALL=0
RESTORE_SSH=0

choose_components() {
    echo
    echo "============================================================"
    echo " SERVER DISASTER RECOVERY RESTORE v$SCRIPT_VERSION"
    echo "============================================================"
    echo
    echo "Archive:"
    echo "  $ARCHIVE"
    echo
    echo "Answer Y/N for each component."
    echo "Firewall and SSH are intentionally OFF by default."
    echo

    prompt_yes_no "Restore /var/www?" Y && RESTORE_WWW=1 || RESTORE_WWW=0
    prompt_yes_no "Restore Nginx + Let's Encrypt?" Y && RESTORE_NGINX=1 || RESTORE_NGINX=0
    prompt_yes_no "Restore PostgreSQL?" Y && RESTORE_POSTGRES=1 || RESTORE_POSTGRES=0
    prompt_yes_no "Restore MongoDB?" Y && RESTORE_MONGO=1 || RESTORE_MONGO=0
    prompt_yes_no "Restore Microsoft SQL Server?" N && RESTORE_MSSQL=1 || RESTORE_MSSQL=0
    prompt_yes_no "Restore custom systemd units?" Y && RESTORE_SYSTEMD=1 || RESTORE_SYSTEMD=0
    prompt_yes_no "Restore CrowdSec?" Y && RESTORE_CROWDSEC=1 || RESTORE_CROWDSEC=0
    prompt_yes_no "Restore Docker volumes?" Y && RESTORE_DOCKER=1 || RESTORE_DOCKER=0
    prompt_yes_no "Restore firewall?" N && RESTORE_FIREWALL=1 || RESTORE_FIREWALL=0
    prompt_yes_no "Restore SSH configuration?" N && RESTORE_SSH=1 || RESTORE_SSH=0

    echo
    echo "Selected:"
    printf '  WWW       : %s\n' "$RESTORE_WWW"
    printf '  Nginx     : %s\n' "$RESTORE_NGINX"
    printf '  PostgreSQL: %s\n' "$RESTORE_POSTGRES"
    printf '  MongoDB   : %s\n' "$RESTORE_MONGO"
    printf '  MSSQL     : %s\n' "$RESTORE_MSSQL"
    printf '  systemd   : %s\n' "$RESTORE_SYSTEMD"
    printf '  CrowdSec  : %s\n' "$RESTORE_CROWDSEC"
    printf '  Docker    : %s\n' "$RESTORE_DOCKER"
    printf '  Firewall  : %s\n' "$RESTORE_FIREWALL"
    printf '  SSH       : %s\n' "$RESTORE_SSH"
    echo

    prompt_yes_no "Continue with this restore?" N ||
        die "Restore cancelled."
}

# -------------------------------------------------------------------
# Package bootstrap
# -------------------------------------------------------------------

install_selected_packages() {
    [[ -f /etc/os-release ]] || return 0
    # shellcheck disable=SC1091
    source /etc/os-release

    if ! prompt_yes_no "Install missing packages before restoring?" Y; then
        return 0
    fi

    case "$ID" in
        ubuntu|debian)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -y

            local pkgs=(tar gzip coreutils)
            [[ "$RESTORE_NGINX" == 1 ]]    && pkgs+=(nginx)
            [[ "$RESTORE_POSTGRES" == 1 ]] && pkgs+=(postgresql-client)
            [[ "$RESTORE_DOCKER" == 1 ]]   && pkgs+=(docker.io)
            [[ "$RESTORE_SSH" == 1 ]]      && pkgs+=(openssh-server)
            [[ "$RESTORE_FIREWALL" == 1 ]] && pkgs+=(ufw iptables nftables)

            apt-get install -y "${pkgs[@]}"

            if [[ "$RESTORE_MONGO" == 1 ]] && ! cmd mongorestore; then
                apt-get install -y mongodb-database-tools 2>/dev/null ||
                    apt-get install -y mongodb-org-tools 2>/dev/null ||
                    warn "Could not automatically install MongoDB Database Tools."
            fi

            if [[ "$RESTORE_MSSQL" == 1 ]] && ! cmd sqlcmd; then
                if [[ -x /opt/mssql-tools18/bin/sqlcmd ]]; then
                    ln -sf /opt/mssql-tools18/bin/sqlcmd /usr/local/bin/sqlcmd
                else
                    warn "sqlcmd is not installed. MSSQL restore will be skipped."
                fi
            fi
            ;;

        arch)
            pacman -Sy --noconfirm --needed tar gzip coreutils

            local pkgs=()
            [[ "$RESTORE_NGINX" == 1 ]]    && pkgs+=(nginx)
            [[ "$RESTORE_POSTGRES" == 1 ]] && pkgs+=(postgresql)
            [[ "$RESTORE_DOCKER" == 1 ]]   && pkgs+=(docker)
            [[ "$RESTORE_SSH" == 1 ]]      && pkgs+=(openssh)
            [[ "$RESTORE_FIREWALL" == 1 ]] && pkgs+=(ufw iptables-nft nftables)
            [[ "$RESTORE_MONGO" == 1 ]]    && pkgs+=(mongodb-tools)

            if ((${#pkgs[@]})); then
                pacman -S --noconfirm --needed "${pkgs[@]}"
            fi
            ;;

        *)
            warn "Unsupported package-manager OS: $ID"
            ;;
    esac
}

# -------------------------------------------------------------------
# Archive extraction and integrity
# -------------------------------------------------------------------

extract_archive() {
    mkdir -p "$RESTORE_ROOT"

    log "Testing archive readability..."
    tar -tzf "$ARCHIVE" >/dev/null ||
        die "Backup archive is corrupt or unreadable."

    log "Extracting backup archive..."
    tar --acls --xattrs --numeric-owner \
        -xzf "$ARCHIVE" \
        -C "$RESTORE_ROOT"

    TREE="$RESTORE_ROOT/server-backup"

    [[ -d "$TREE" ]] ||
        die "Invalid archive: missing server-backup directory."

    [[ -f "$TREE/MANIFEST.sha256" ]] ||
        die "Invalid archive: missing MANIFEST.sha256."

    log "Verifying backup manifest..."

    # sha256sum's --strict makes malformed manifest lines fatal.
    # This intentionally stops BEFORE modifying the live server.
    (
        cd "$TREE"
        sha256sum --strict -c MANIFEST.sha256
    ) || die "Backup checksum verification failed or MANIFEST.sha256 contains malformed entries."

    log "Manifest verification: OK"
}

# -------------------------------------------------------------------
# Helpers
# -------------------------------------------------------------------

backup_existing_dir() {
    local path="$1"
    local stamp="$2"

    if [[ -e "$path" ]]; then
        mv "$path" "${path}.before-restore-${stamp}"
        printf '%s\n' "${path}.before-restore-${stamp}"
    fi
}

restore_tree_dir() {
    local source="$1"
    local destination="$2"

    mkdir -p "$destination"
    cp -a "$source/." "$destination/"
}

# -------------------------------------------------------------------
# WWW
# -------------------------------------------------------------------

restore_www() {
    [[ "$RESTORE_WWW" == 1 ]] || return 0
    [[ -f "$TREE/WWW/var-www.tar.gz" ]] || {
        warn "WWW backup not found; skipping /var/www."
        return 0
    }

    log "[1] Restoring /var/www"

    local old
    old="/var/www.before-restore-$(date +%Y%m%d_%H%M%S)"

    if [[ -d /var/www ]]; then
        mv /var/www "$old"
    fi

    mkdir -p /var/www

    if ! tar --acls --xattrs --numeric-owner \
        -xzf "$TREE/WWW/var-www.tar.gz" -C /var; then
        rm -rf /var/www
        [[ -d "$old" ]] && mv "$old" /var/www
        die "/var/www restore failed. Original directory restored."
    fi

    log "/var/www restored successfully."
}

# -------------------------------------------------------------------
# Let's Encrypt
# -------------------------------------------------------------------

restore_letsencrypt() {
    [[ "$RESTORE_NGINX" == 1 ]] || return 0
    [[ -d "$TREE/SECURITY/etc-letsencrypt" ]] || {
        warn "Backup does not contain /etc/letsencrypt."
        return 0
    }

    log "[2] Restoring Let's Encrypt / SSL configuration"

    local old
    old="/etc/letsencrypt.before-restore-$(date +%Y%m%d_%H%M%S)"

    if [[ -d /etc/letsencrypt ]]; then
        mv /etc/letsencrypt "$old"
    fi

    mkdir -p /etc/letsencrypt
    cp -a "$TREE/SECURITY/etc-letsencrypt/." /etc/letsencrypt/

    chmod 700 /etc/letsencrypt 2>/dev/null || true

    # Save old location for Nginx rollback.
    LETSENCRYPT_OLD="$old"
    log "Let's Encrypt configuration restored."
}

# -------------------------------------------------------------------
# Nginx with actual rollback
# -------------------------------------------------------------------

restore_nginx() {
    [[ "$RESTORE_NGINX" == 1 ]] || return 0
    [[ -d "$TREE/NGINX/etc-nginx" ]] || {
        warn "Nginx configuration not present in backup."
        return 0
    }

    log "[3] Restoring Nginx configuration"

    systemctl stop nginx 2>/dev/null || true

    local stamp
    stamp="$(date +%Y%m%d_%H%M%S)"

    local old_nginx="/etc/nginx.before-restore-${stamp}"

    if [[ -d /etc/nginx ]]; then
        mv /etc/nginx "$old_nginx"
    fi

    mkdir -p /etc/nginx
    cp -a "$TREE/NGINX/etc-nginx/." /etc/nginx/

    log "Testing restored Nginx configuration..."

    if nginx -t; then
        log "Nginx configuration test: OK"

        systemctl enable nginx >/dev/null 2>&1 || true

        if systemctl restart nginx; then
            log "Nginx restarted successfully."

            # Old config is intentionally retained for manual rollback.
            return 0
        fi

        warn "Nginx restart failed; rolling back."
    else
        warn "Nginx configuration test failed; rolling back."
    fi

    # ----------------------------------------------------------------
    # Actual rollback
    # ----------------------------------------------------------------
    rm -rf /etc/nginx

    if [[ -d "$old_nginx" ]]; then
        mv "$old_nginx" /etc/nginx
    else
        mkdir -p /etc/nginx
    fi

    # Restore previous Let's Encrypt directory if this restore replaced it.
    if [[ -n "${LETSENCRYPT_OLD:-}" && -d "$LETSENCRYPT_OLD" ]]; then
        rm -rf /etc/letsencrypt
        mv "$LETSENCRYPT_OLD" /etc/letsencrypt
    fi

    nginx -t || true
    systemctl start nginx 2>/dev/null || true

    die "Nginx restore failed. Previous Nginx/SSL configuration was rolled back."
}

# -------------------------------------------------------------------
# systemd
# -------------------------------------------------------------------

restore_systemd() {
    [[ "$RESTORE_SYSTEMD" == 1 ]] || return 0

    local restored=0

    if [[ -d "$TREE/SYSTEMD/etc-systemd-system" ]]; then
        log "[4] Restoring systemd system units"
        mkdir -p /etc/systemd/system
        cp -a "$TREE/SYSTEMD/etc-systemd-system/." /etc/systemd/system/
        restored=1
    fi

    if [[ -d "$TREE/SYSTEMD/etc-systemd-user" ]]; then
        log "Restoring systemd user units"
        mkdir -p /etc/systemd/user
        cp -a "$TREE/SYSTEMD/etc-systemd-user/." /etc/systemd/user/
        restored=1
    fi

    if ((restored)); then
        systemctl daemon-reload
        log "systemd units restored."
    fi
}

# -------------------------------------------------------------------
# CrowdSec
# -------------------------------------------------------------------

restore_crowdsec() {
    [[ "$RESTORE_CROWDSEC" == 1 ]] || return 0
    [[ -d "$TREE/CROWDSEC/etc-crowdsec" ]] || return 0

    log "[5] Restoring CrowdSec configuration"

    systemctl stop crowdsec 2>/dev/null || true

    local old="/etc/crowdsec.before-restore-$(date +%Y%m%d_%H%M%S)"

    if [[ -d /etc/crowdsec ]]; then
        mv /etc/crowdsec "$old"
    fi

    mkdir -p /etc/crowdsec
    cp -a "$TREE/CROWDSEC/etc-crowdsec/." /etc/crowdsec/

    systemctl daemon-reload

    if systemctl is-enabled crowdsec >/dev/null 2>&1 ||
       systemctl list-unit-files crowdsec.service >/dev/null 2>&1; then
        systemctl enable crowdsec 2>/dev/null || true
        systemctl start crowdsec || {
            warn "CrowdSec failed to start. Previous config: $old"
        }
    fi
}

# -------------------------------------------------------------------
# PostgreSQL
# -------------------------------------------------------------------

sql_ident_escape() {
    local value="$1"
    printf '%s' "${value//\"/\"\"}"
}

sql_literal_escape() {
    local value="$1"
    printf '%s' "${value//\'/\'\'}"
}

restore_postgres() {
    [[ "$RESTORE_POSTGRES" == 1 ]] || return 0
    [[ -d "$TREE/POSTGRES/databases" ]] || {
        warn "PostgreSQL backup directory not found."
        return 0
    }

    cmd psql || die "psql is required for PostgreSQL restore."
    cmd pg_restore || die "pg_restore is required for PostgreSQL restore."

    log "[6] Restoring PostgreSQL"

    systemctl enable postgresql 2>/dev/null || true
    systemctl start postgresql || die "PostgreSQL service could not be started."

    local pg_user="${PG_USER:-postgres}"
    local pg_host="${PG_HOST:-}"
    local pg_port="${PG_PORT:-}"

    local -a PSQL_BASE
    PSQL_BASE=(psql -v ON_ERROR_STOP=1)

    if [[ -n "$pg_host" ]]; then
        PSQL_BASE+=(-h "$pg_host")
    fi
    if [[ -n "$pg_port" ]]; then
        PSQL_BASE+=(-p "$pg_port")
    fi
    PSQL_BASE+=(-U "$pg_user")

    prompt_password PG_PASSWORD "PostgreSQL user '$pg_user'"

    if [[ -n "${PG_PASSWORD:-}" ]]; then
        export PGPASSWORD="$PG_PASSWORD"
    fi

    # Restore roles/tablespaces/global objects first.
    if [[ -f "$TREE/POSTGRES/globals.sql" ]]; then
        log "Restoring PostgreSQL globals..."

        if ! "${PSQL_BASE[@]}" -d postgres \
            -f "$TREE/POSTGRES/globals.sql"; then
            unset PGPASSWORD
            die "PostgreSQL globals restore failed."
        fi
    fi

    local dump
    local db
    local safe
    local db_exists
    local ident

    shopt -s nullglob
    local dumps=( "$TREE"/POSTGRES/databases/*.dump )
    shopt -u nullglob

    ((${#dumps[@]})) || {
        unset PGPASSWORD
        warn "No PostgreSQL database dumps found."
        return 0
    }

    for dump in "${dumps[@]}"; do
        db="$(basename "$dump" .dump)"

        # Backup script sanitizes filenames. For normal PostgreSQL database
        # names this preserves the name. A database-list.txt is also kept
        # for auditing/recovery.
        safe="$db"
        ident="$(sql_ident_escape "$safe")"

        log "Restoring PostgreSQL database: $safe"

        db_exists="$(
            "${PSQL_BASE[@]}" -d postgres -Atqc \
                "SELECT 1 FROM pg_database WHERE datname='$(sql_literal_escape "$safe")';" \
                2>/dev/null || true
        )"

        if [[ "$db_exists" == "1" ]]; then
            log "Database $safe already exists; dropping it before restore."

            if ! "${PSQL_BASE[@]}" -d postgres -c \
                "DROP DATABASE \"$ident\" WITH (FORCE);"; then
                unset PGPASSWORD
                die "Could not drop existing PostgreSQL database: $safe"
            fi
        fi

        if ! "${PSQL_BASE[@]}" -d postgres -c \
            "CREATE DATABASE \"$ident\";"; then
            unset PGPASSWORD
            die "Could not create PostgreSQL database: $safe"
        fi

        if ! pg_restore \
            -v \
            --exit-on-error \
            --no-owner \
            --no-acl \
            --dbname="$safe" \
            "$dump"; then
            unset PGPASSWORD
            die "PostgreSQL restore failed for database: $safe"
        fi

        log "PostgreSQL database restored: $safe"
    done

    unset PGPASSWORD
    log "PostgreSQL restore completed."
}

# -------------------------------------------------------------------
# MongoDB
# -------------------------------------------------------------------

restore_mongo() {
    [[ "$RESTORE_MONGO" == 1 ]] || return 0
    [[ -f "$TREE/MONGODB/mongodb.archive.gz" ]] || {
        warn "MongoDB archive not found."
        return 0
    }

    cmd mongorestore || die "mongorestore is required for MongoDB restore."

    log "[7] Restoring MongoDB"

    if systemctl list-unit-files mongod.service >/dev/null 2>&1; then
        systemctl enable mongod 2>/dev/null || true
        systemctl start mongod || die "MongoDB service could not be started."
    elif systemctl list-unit-files mongodb.service >/dev/null 2>&1; then
        systemctl enable mongodb 2>/dev/null || true
        systemctl start mongodb || die "MongoDB service could not be started."
    fi

    local uri="${MONGO_URI:-mongodb://127.0.0.1:27017}"

    prompt_with_default MONGO_URI \
        "MongoDB URI" \
        "$uri"

    uri="${MONGO_URI:-mongodb://127.0.0.1:27017}"

    if ! mongorestore \
        --uri="$uri" \
        --archive="$TREE/MONGODB/mongodb.archive.gz" \
        --gzip \
        --drop; then
        die "MongoDB restore failed."
    fi

    log "MongoDB restore completed."
}

# -------------------------------------------------------------------
# MSSQL
# -------------------------------------------------------------------

mssql_escape_identifier() {
    local value="$1"
    printf '%s' "${value//]/]]}"
}

mssql_escape_literal() {
    local value="$1"
    printf '%s' "${value//\'/\'\'}"
}

restore_mssql() {
    [[ "$RESTORE_MSSQL" == 1 ]] || return 0
    [[ -d "$TREE/MSSQL/bak" ]] || {
        warn "MSSQL backup directory not found."
        return 0
    }

    cmd sqlcmd || die "sqlcmd is required for MSSQL restore."

    log "[8] Restoring Microsoft SQL Server"

    systemctl start mssql-server 2>/dev/null || true

    local server="${MSSQL_SERVER:-127.0.0.1,1433}"
    local user="${MSSQL_USER:-}"
    local password="${MSSQL_PASSWORD:-}"

    prompt_with_default MSSQL_SERVER "MSSQL server" "$server"
    server="$MSSQL_SERVER"

    prompt_with_default MSSQL_USER "MSSQL username" "${user:-sa}"
    user="$MSSQL_USER"

    prompt_password MSSQL_PASSWORD "MSSQL user '$user'"
    password="${MSSQL_PASSWORD:-}"

    local -a SQLCMD
    SQLCMD=(sqlcmd -S "$server" -C -b)

    [[ -n "$user" ]] && SQLCMD+=(-U "$user" -P "$password")

    "${SQLCMD[@]}" -Q "SELECT @@SERVERNAME AS ServerName, SERVERPROPERTY('Edition') AS Edition;" \
        > "$TREE/MSSQL/restore-server-info.txt" 2>&1 ||
        die "Cannot connect to MSSQL with the supplied credentials."

    shopt -s nullglob
    local baks=( "$TREE"/MSSQL/bak/*.bak )
    shopt -u nullglob

    ((${#baks[@]})) || {
        warn "No MSSQL .bak files found."
        return 0
    }

    local bak
    local db
    local qdb
    local qpath
    local logical_data
    local logical_log
    local data_file
    local log_file
    local sql

    for bak in "${baks[@]}"; do
        db="$(basename "$bak" .bak)"
        qdb="$(mssql_escape_identifier "$db")"
        qpath="$(mssql_escape_literal "$bak")"

        log "Verifying MSSQL backup: $db"

        if ! "${SQLCMD[@]}" -Q \
            "RESTORE VERIFYONLY FROM DISK=N'$qpath';"; then
            die "MSSQL backup verification failed: $db"
        fi

        log "Reading logical file names: $db"

        logical_data="$(
            "${SQLCMD[@]}" -h -1 -W -s '|' -Q \
                "RESTORE FILELISTONLY FROM DISK=N'$qpath';" |
                awk -F'|' '$3 == "D" || $3 == "ROWS" {print $1; exit}'
        )"

        logical_log="$(
            "${SQLCMD[@]}" -h -1 -W -s '|' -Q \
                "RESTORE FILELISTONLY FROM DISK=N'$qpath';" |
                awk -F'|' '$3 == "L" {print $1; exit}'
        )"

        # SQL Server may report logical names with whitespace.
        logical_data="$(printf '%s' "$logical_data" | sed 's/[[:space:]]*$//')"
        logical_log="$(printf '%s' "$logical_log" | sed 's/[[:space:]]*$//')"

        if [[ -z "$logical_data" || -z "$logical_log" ]]; then
            die "Could not determine logical data/log files for MSSQL database: $db"
        fi

        data_file="/var/opt/mssql/data/${db}.mdf"
        log_file="/var/opt/mssql/data/${db}_log.ldf"

        mkdir -p /var/opt/mssql/data

        sql="
IF DB_ID(N'$(mssql_escape_literal "$db")') IS NOT NULL
BEGIN
    ALTER DATABASE [$qdb] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
END;

RESTORE DATABASE [$qdb]
FROM DISK=N'$qpath'
WITH
    REPLACE,
    RECOVERY,
    MOVE N'$(mssql_escape_literal "$logical_data")'
        TO N'$(mssql_escape_literal "$data_file")',
    MOVE N'$(mssql_escape_literal "$logical_log")'
        TO N'$(mssql_escape_literal "$log_file")',
    STATS=5;

ALTER DATABASE [$qdb] SET MULTI_USER;
"

        log "Restoring MSSQL database: $db"

        if ! "${SQLCMD[@]}" -Q "$sql"; then
            # Try to return an existing DB to MULTI_USER if restore failed.
            "${SQLCMD[@]}" -Q \
                "IF DB_ID(N'$(mssql_escape_literal "$db")') IS NOT NULL ALTER DATABASE [$qdb] SET MULTI_USER;" \
                >/dev/null 2>&1 || true

            die "MSSQL restore failed for database: $db"
        fi

        log "MSSQL database restored: $db"
    done

    log "MSSQL restore completed."
}

# -------------------------------------------------------------------
# Docker volumes
# -------------------------------------------------------------------

restore_docker() {
    [[ "$RESTORE_DOCKER" == 1 ]] || return 0
    [[ -d "$TREE/DOCKER/volumes" ]] || return 0
    cmd docker || {
        warn "Docker is not installed; skipping Docker volume restore."
        return 0
    }

    log "[9] Restoring Docker named volumes"

    systemctl enable docker 2>/dev/null || true
    systemctl start docker || die "Docker service could not be started."

    local archive
    local vol

    while IFS= read -r -d '' archive; do
        vol="$(basename "$archive" .tar.gz)"

        log "Restoring Docker volume: $vol"

        docker volume inspect "$vol" >/dev/null 2>&1 ||
            docker volume create "$vol" >/dev/null

        # Use the host tar instead of requiring the alpine image.
        # The volume is mounted into a temporary container.
        if ! docker run --rm \
            -v "$vol:/data" \
            -v "$(dirname "$archive"):/backup:ro" \
            alpine:latest \
            sh -c '
                set -eu
                find /data -mindepth 1 -maxdepth 1 -exec rm -rf {} +
                tar xzf "/backup/'"$(basename "$archive")"'" -C /data
            '; then
            die "Docker volume restore failed: $vol"
        fi
    done < <(find "$TREE/DOCKER/volumes" -type f -name '*.tar.gz' -print0)

    log "Docker volume restore completed."
}

# -------------------------------------------------------------------
# Firewall - opt in only
# -------------------------------------------------------------------

restore_firewall() {
    [[ "$RESTORE_FIREWALL" == 1 ]] || return 0

    log "[10] Restoring firewall rules"

    if command -v ufw >/dev/null 2>&1 &&
       [[ -d "$TREE/FIREWALL/etc-ufw" ]]; then

        # Back up current UFW config before replacing it.
        if [[ -d /etc/ufw ]]; then
            mv /etc/ufw "/etc/ufw.before-restore-$(date +%Y%m%d_%H%M%S)"
        fi

        mkdir -p /etc/ufw
        cp -a "$TREE/FIREWALL/etc-ufw/." /etc/ufw/

        ufw --force enable || die "UFW restore/enable failed."

    elif command -v nft >/dev/null 2>&1 &&
         [[ -f "$TREE/FIREWALL/nftables-ruleset.txt" ]]; then

        # The backup is textual output from `nft list ruleset`.
        nft -c -f "$TREE/FIREWALL/nftables-ruleset.txt" ||
            die "nftables syntax validation failed."

        nft -f "$TREE/FIREWALL/nftables-ruleset.txt" ||
            die "nftables restore failed."

    elif command -v iptables-restore >/dev/null 2>&1 &&
         [[ -f "$TREE/FIREWALL/iptables.rules" ]]; then

        iptables-restore < "$TREE/FIREWALL/iptables.rules" ||
            die "iptables restore failed."
    else
        warn "No supported firewall backup/restore method found."
    fi
}

# -------------------------------------------------------------------
# SSH - opt in only, validate before reload
# -------------------------------------------------------------------

restore_ssh() {
    [[ "$RESTORE_SSH" == 1 ]] || return 0
    [[ -d "$TREE/SSH/etc-ssh" ]] || {
        warn "SSH configuration backup not found."
        return 0
    }

    log "[11] Restoring SSH configuration"

    local old="/etc/ssh.before-restore-$(date +%Y%m%d_%H%M%S)"

    cp -a /etc/ssh "$old"
    cp -a "$TREE/SSH/etc-ssh/." /etc/ssh/

    if sshd -t; then
        if systemctl reload ssh 2>/dev/null ||
           systemctl reload sshd 2>/dev/null; then
            log "SSH configuration restored successfully."
        else
            warn "SSH configuration is valid but reload failed."
        fi
    else
        log "ERROR: SSH configuration is invalid. Rolling back."

        rm -rf /etc/ssh
        cp -a "$old" /etc/ssh

        sshd -t || true
        systemctl reload ssh 2>/dev/null ||
            systemctl reload sshd 2>/dev/null ||
            true

        die "SSH configuration restore failed and was rolled back."
    fi
}

# -------------------------------------------------------------------
# Final status
# -------------------------------------------------------------------

final_status() {
    echo
    echo "============================================================"
    echo " RESTORE FINISHED"
    echo "============================================================"
    echo
    echo "Archive:"
    echo "  $ARCHIVE"
    echo
    echo "Restore workspace:"
    echo "  $RESTORE_ROOT"
    echo

    if ((WARNINGS > 0)); then
        echo "Warnings: $WARNINGS"
        echo
    fi

    echo "Failed systemd units:"
    systemctl --failed --no-legend --no-pager 2>/dev/null || true
    echo

    echo "Recommended verification:"
    echo "  systemctl --failed"
    echo "  systemctl status nginx"
    echo "  nginx -t"
    echo "  systemctl status postgresql"
    echo "  systemctl status mongod 2>/dev/null || systemctl status mongodb 2>/dev/null"
    echo "  systemctl status mssql-server 2>/dev/null"
    echo "  systemctl status docker 2>/dev/null"
    echo
    echo "IMPORTANT: Do not delete $RESTORE_ROOT until the restored services"
    echo "and databases have been verified."
}

# -------------------------------------------------------------------
# Main
# -------------------------------------------------------------------

main() {
    log "Starting server disaster-recovery restore v$SCRIPT_VERSION"

    choose_components
    install_selected_packages
    extract_archive

    # Dependency-aware order:
    # WWW -> SSL -> Nginx -> systemd -> security -> databases -> Docker
    restore_www
    restore_letsencrypt
    restore_nginx
    restore_systemd
    restore_crowdsec
    restore_postgres
    restore_mongo
    restore_mssql
    restore_docker
    restore_firewall
    restore_ssh

    final_status
}

main "$@"
