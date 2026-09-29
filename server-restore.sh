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

SCRIPT_VERSION="2.3.0"
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

# Package management:
# - Selected packages are always installed at the newest repository version.
# - Existing selected packages are upgraded when required.
# - A full OS distribution upgrade is NOT performed automatically.
UPGRADE_SELECTED_PACKAGES=1

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
# Package bootstrap / upgrade
# -------------------------------------------------------------------

install_selected_packages() {
    [[ -f /etc/os-release ]] || return 0
    # shellcheck disable=SC1091
    source /etc/os-release

    if ! prompt_yes_no "Install/upgrade required packages before restoring?" Y; then
        return 0
    fi

    local mongo_repo_added=0
    local mssql_repo_added=0
    local microsoft_files=()
    local disabled_files=()

    restore_apt_repositories() {
        local f
        for f in "${disabled_files[@]}"; do
            [[ -f "$f" ]] || continue
            mv "$f" "${f%.restore-disabled}"
            log "Re-enabled repository: ${f%.restore-disabled}"
        done
    }

    case "$ID" in
        ubuntu|debian)
            export DEBIAN_FRONTEND=noninteractive

            # Required bootstrap tools.
            apt-get update
            apt-get install -y ca-certificates curl gnupg lsb-release apt-transport-https tar gzip coreutils

            # Keep unrelated Microsoft repositories out of the normal package
            # transaction unless MSSQL was explicitly selected.
            if [[ "$RESTORE_MSSQL" != 1 ]]; then
                while IFS= read -r -d '' f; do
                    microsoft_files+=("$f")
                done < <(
                    grep -RIlZE \
                        'packages\.microsoft\.com|packages\.microsoft\.com/ubuntu' \
                        /etc/apt/sources.list /etc/apt/sources.list.d \
                        2>/dev/null || true
                )

                for f in "${microsoft_files[@]}"; do
                    [[ -f "$f" ]] || continue
                    local disabled="${f}.restore-disabled"
                    mv "$f" "$disabled"
                    disabled_files+=("$disabled")
                    log "Temporarily disabled Microsoft repository: $f"
                done
            fi

            # ------------------------------------------------------------
            # MongoDB official repository (fresh Debian/Ubuntu environment)
            # ------------------------------------------------------------
            if [[ "$RESTORE_MONGO" == 1 ]] && ! cmd mongod; then
                log "MongoDB server not found; configuring official MongoDB repository..."

                local mongo_codename="${VERSION_CODENAME:-}"
                if [[ -z "$mongo_codename" ]]; then
                    mongo_codename="$(. /etc/os-release && printf '%s' "${VERSION_CODENAME:-}")"
                fi

                mkdir -p /usr/share/keyrings

                if [[ "$ID" == "ubuntu" &&
                      "$mongo_codename" =~ ^(focal|jammy|noble)$ ]]; then
                    curl -fsSL https://pgp.mongodb.com/server-8.0.asc |
                        gpg --dearmor --yes -o /usr/share/keyrings/mongodb-server-8.0.gpg

                    cat > /etc/apt/sources.list.d/mongodb-org-8.0.list <<EOF
deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-8.0.gpg ] https://repo.mongodb.org/apt/ubuntu ${mongo_codename}/mongodb-org/8.0 multiverse
EOF
                    mongo_repo_added=1

                elif [[ "$ID" == "debian" && "$mongo_codename" == "bookworm" ]]; then
                    curl -fsSL https://pgp.mongodb.com/server-8.0.asc |
                        gpg --dearmor --yes -o /usr/share/keyrings/mongodb-server-8.0.gpg

                    cat > /etc/apt/sources.list.d/mongodb-org-8.0.list <<EOF
deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-8.0.gpg ] https://repo.mongodb.org/apt/debian bookworm/mongodb-org/8.0 main
EOF
                    mongo_repo_added=1
                else
                    warn "Automatic MongoDB 8.0 installation is not configured for $ID/$mongo_codename."
                fi
            fi

            # ------------------------------------------------------------
            # Microsoft SQL Server repository (fresh environment)
            # ------------------------------------------------------------
            if [[ "$RESTORE_MSSQL" == 1 ]]; then
                mkdir -p /usr/share/keyrings

                curl -fsSL https://packages.microsoft.com/keys/microsoft.asc |
                    gpg --dearmor --yes -o /usr/share/keyrings/microsoft-prod.gpg
                chmod 0644 /usr/share/keyrings/microsoft-prod.gpg

                local mssql_repo=""
                case "$ID:$VERSION_ID" in
                    ubuntu:24.04)
                        mssql_repo="https://packages.microsoft.com/config/ubuntu/24.04/mssql-server-2025.list"
                        ;;
                    ubuntu:22.04)
                        mssql_repo="https://packages.microsoft.com/config/ubuntu/22.04/mssql-server-2025.list"
                        ;;
                    ubuntu:20.04)
                        mssql_repo="https://packages.microsoft.com/config/ubuntu/20.04/mssql-server-2022.list"
                        ;;
                    *)
                        warn "Automatic MSSQL installation is currently configured only for supported Ubuntu releases."
                        ;;
                esac

                if [[ -n "$mssql_repo" ]]; then
                    curl -fsSL "$mssql_repo" \
                        -o /etc/apt/sources.list.d/mssql-server.list
                    mssql_repo_added=1

                    # Repository used for sqlcmd/mssql-tools18.
                    local prod_repo="/etc/apt/sources.list.d/microsoft-prod.list"
                    local prod_url="https://packages.microsoft.com/config/ubuntu/${VERSION_ID}/prod.list"

                    if [[ "$ID" == "ubuntu" ]]; then
                        curl -fsSL "$prod_url" -o "$prod_repo"
                    fi
                fi
            fi

            # Rebuild indexes after adding optional repositories.
            apt-get update

            local pkgs=(tar gzip coreutils ca-certificates curl gnupg)
            [[ "$RESTORE_NGINX" == 1 ]]    && pkgs+=(nginx)
            [[ "$RESTORE_POSTGRES" == 1 ]] && pkgs+=(postgresql postgresql-client)
            [[ "$RESTORE_DOCKER" == 1 ]]   && pkgs+=(docker.io)
            [[ "$RESTORE_SSH" == 1 ]]      && pkgs+=(openssh-server)
            [[ "$RESTORE_FIREWALL" == 1 ]] && pkgs+=(ufw iptables nftables)
            [[ "$RESTORE_MONGO" == 1 && "$mongo_repo_added" == 1 ]] && pkgs+=(mongodb-org)
            [[ "$RESTORE_MSSQL" == 1 && "$mssql_repo_added" == 1 ]] && pkgs+=(mssql-server mssql-tools18 unixodbc-dev)

            if [[ "$UPGRADE_SELECTED_PACKAGES" == 1 && ${#pkgs[@]} -gt 0 ]]; then
                log "Upgrading selected restore packages where newer versions are available..."
                apt-get install -y --only-upgrade "${pkgs[@]}" || \
                    warn "Some already-installed packages could not be upgraded; continuing with installation."
            fi

            log "Installing required restore packages..."
            apt-get install -y "${pkgs[@]}"

            if [[ "$RESTORE_MONGO" == 1 ]] && ! cmd mongorestore; then
                apt-get install -y mongodb-database-tools 2>/dev/null ||
                    apt-get install -y mongodb-org-tools 2>/dev/null ||
                    warn "MongoDB restore tools could not be installed automatically."
            fi

            if [[ "$RESTORE_MSSQL" == 1 ]]; then
                if [[ -x /opt/mssql-tools18/bin/sqlcmd ]]; then
                    ln -sf /opt/mssql-tools18/bin/sqlcmd /usr/local/bin/sqlcmd
                elif ! cmd sqlcmd; then
                    warn "sqlcmd is not available; MSSQL restore cannot continue."
                fi
            fi

            # The MSSQL/Mongo repositories are intentionally retained when
            # those components were selected, so future upgrades remain usable.
            # Restore unrelated Microsoft repositories that were temporarily
            # disabled above.
            restore_apt_repositories
            ;;

        arch)
            # Arch requires a full synchronized upgrade to avoid partial-upgrade
            # dependency breakage.
            log "Synchronizing Arch repositories and upgrading the system..."
            pacman -Syu --noconfirm --needed

            local pkgs=()
            [[ "$RESTORE_NGINX" == 1 ]]    && pkgs+=(nginx)
            [[ "$RESTORE_POSTGRES" == 1 ]] && pkgs+=(postgresql)
            [[ "$RESTORE_DOCKER" == 1 ]]   && pkgs+=(docker)
            [[ "$RESTORE_SSH" == 1 ]]      && pkgs+=(openssh)
            [[ "$RESTORE_FIREWALL" == 1 ]] && pkgs+=(ufw iptables-nft nftables)

            if ((${#pkgs[@]})); then
                log "Installing/upgrading selected Arch restore packages..."
                pacman -S --noconfirm --needed "${pkgs[@]}"
            fi

            if [[ "$RESTORE_MONGO" == 1 ]] && ! cmd mongod; then
                warn "MongoDB server is not in the official Arch repositories. Install MongoDB separately before MongoDB restore."
            fi

            if [[ "$RESTORE_MSSQL" == 1 ]]; then
                warn "Microsoft SQL Server native Linux packages are not supported by this Arch restore path. Use a supported Ubuntu/RHEL environment or an MSSQL container."
            fi
            ;;

        *)
            warn "Unsupported package-manager OS: $ID"
            ;;
    esac
}

# -------------------------------------------------------------------
# Archive integrity and extraction
# -------------------------------------------------------------------

verify_archive() {
    local checksum_file="${ARCHIVE}.sha256"

    log "Testing gzip integrity..."
    if ! gzip -t "$ARCHIVE"; then
        die "Gzip integrity check failed. Archive is corrupted."
    fi
    log "Gzip integrity: OK"

    log "Testing tar archive structure..."
    if ! tar -tzf "$ARCHIVE" >/dev/null; then
        die "Tar archive is corrupt or unreadable."
    fi
    log "Tar archive structure: OK"

    if [[ -f "$checksum_file" ]]; then
        log "Verifying detached SHA-256 checksum..."

        (
            cd "$(dirname "$ARCHIVE")"
            sha256sum --strict --check "$(basename "$checksum_file")"
        ) || die "Archive SHA-256 verification failed. Backup may be corrupted."

        log "Archive SHA-256: OK"
    else
        warn "Detached SHA-256 checksum file not found: $checksum_file"

        if ! prompt_yes_no "Continue without SHA-256 verification?" N; then
            die "Restore aborted because checksum file is missing."
        fi
    fi
}

extract_archive() {
    mkdir -p "$RESTORE_ROOT"

    verify_archive

    log "Extracting backup archive..."
    tar --acls --xattrs --numeric-owner         -xzf "$ARCHIVE"         -C "$RESTORE_ROOT" ||
        die "Backup archive extraction failed."

    TREE="$RESTORE_ROOT/server-backup"

    [[ -d "$TREE" ]] ||
        die "Invalid archive: missing server-backup directory."

    [[ -f "$TREE/backup-info.txt" ]] ||
        warn "backup-info.txt not found; archive may be from an older backup version."

    log "Archive extraction: OK"
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

    # Fresh/local environment:
    # use PostgreSQL's local OS account instead of asking for the old password.
    # This is the preferred disaster-recovery path.
    local -a PSQL_BASE
    local -a PGRESTORE_BASE

    if [[ -z "$pg_host" ]]; then
        id postgres >/dev/null 2>&1 ||
            die "PostgreSQL OS user 'postgres' was not found."

        PSQL_BASE=(runuser -u postgres -- psql -v ON_ERROR_STOP=1)
        PGRESTORE_BASE=(runuser -u postgres -- pg_restore)
        log "Using local PostgreSQL OS authentication; old PostgreSQL password is not required."
    else
        PSQL_BASE=(psql -v ON_ERROR_STOP=1 -h "$pg_host")
        [[ -n "$pg_port" ]] && PSQL_BASE+=(-p "$pg_port")
        PSQL_BASE+=(-U "$pg_user")

        prompt_password PG_PASSWORD "PostgreSQL user '$pg_user'"
        [[ -n "${PG_PASSWORD:-}" ]] || die "Remote PostgreSQL requires a password."
        export PGPASSWORD="$PG_PASSWORD"

        PGRESTORE_BASE=(pg_restore -h "$pg_host")
        [[ -n "$pg_port" ]] && PGRESTORE_BASE+=(-p "$pg_port")
        PGRESTORE_BASE+=(-U "$pg_user")
    fi

    # Restore roles/tablespaces/global objects first.
    if [[ -f "$TREE/POSTGRES/globals.sql" ]]; then
        log "Restoring PostgreSQL globals..."

        if ! "${PSQL_BASE[@]}" -d postgres \
            -f "$TREE/POSTGRES/globals.sql"; then
            unset PGPASSWORD PG_PASSWORD
            die "PostgreSQL globals restore failed."
        fi
    fi

    local dump db safe db_exists ident
    shopt -s nullglob
    local dumps=( "$TREE"/POSTGRES/databases/*.dump )
    shopt -u nullglob

    ((${#dumps[@]})) || {
        unset PGPASSWORD PG_PASSWORD
        warn "No PostgreSQL database dumps found."
        return 0
    }

    for dump in "${dumps[@]}"; do
        db="$(basename "$dump" .dump)"
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
                unset PGPASSWORD PG_PASSWORD
                die "Could not drop existing PostgreSQL database: $safe"
            fi
        fi

        if ! "${PSQL_BASE[@]}" -d postgres -c \
            "CREATE DATABASE \"$ident\";"; then
            unset PGPASSWORD PG_PASSWORD
            die "Could not create PostgreSQL database: $safe"
        fi

        local -a restore_cmd=("${PGRESTORE_BASE[@]}")
        restore_cmd+=(
            -v
            --exit-on-error
            --no-owner
            --no-acl
            "--dbname=$safe"
            "$dump"
        )

        if ! "${restore_cmd[@]}"; then
            unset PGPASSWORD PG_PASSWORD
            die "PostgreSQL restore failed for database: $safe"
        fi

        log "PostgreSQL database restored: $safe"
    done

    unset PGPASSWORD PG_PASSWORD
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

    if cmd mongod; then
        if systemctl list-unit-files mongod.service >/dev/null 2>&1; then
            systemctl enable mongod 2>/dev/null || true
            systemctl start mongod || die "MongoDB service could not be started."
        elif systemctl list-unit-files mongodb.service >/dev/null 2>&1; then
            systemctl enable mongodb 2>/dev/null || true
            systemctl start mongodb || die "MongoDB service could not be started."
        fi
    else
        die "MongoDB server is not installed. Package bootstrap could not install it for this OS."
    fi

    # Fresh environment default: local MongoDB without authentication.
    # If a URI is explicitly supplied, use it and its credentials.
    local uri="${MONGO_URI:-mongodb://127.0.0.1:27017}"

    if [[ -z "${MONGO_URI:-}" ]]; then
        log "Using fresh local MongoDB without authentication; old MongoDB password is not required."
    else
        log "Using MongoDB URI supplied by MONGO_URI."
    fi

    # Give mongod a moment after first startup.
    local attempt
    for attempt in {1..30}; do
        if mongosh --quiet --host 127.0.0.1 --eval 'db.adminCommand({ping:1}).ok' \
            >/dev/null 2>&1; then
            break
        fi
        sleep 1
    done

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

    log "[8] Restoring Microsoft SQL Server"

    # Fresh environment setup. The old SA password is never required.
    if ! cmd sqlcmd && [[ -x /opt/mssql-tools18/bin/sqlcmd ]]; then
        ln -sf /opt/mssql-tools18/bin/sqlcmd /usr/local/bin/sqlcmd
    fi

    if ! cmd sqlcmd; then
        die "sqlcmd is required for MSSQL restore."
    fi

    if ! systemctl list-unit-files mssql-server.service >/dev/null 2>&1; then
        die "mssql-server service is not installed. Select a supported Ubuntu environment for automatic MSSQL installation."
    fi

    local server="${MSSQL_SERVER:-127.0.0.1,1433}"
    local user="${MSSQL_USER:-sa}"
    local password="${MSSQL_PASSWORD:-}"

    # If SQL Server has never been configured, create a NEW SA password.
    if [[ ! -f /var/opt/mssql/mssql.conf || ! -s /var/opt/mssql/mssql.conf ]]; then
        log "Fresh MSSQL installation detected."

        prompt_with_default MSSQL_PID \
            "SQL Server edition/product ID" \
            "${MSSQL_PID:-Evaluation}"

        prompt_password MSSQL_PASSWORD "NEW SQL Server SA"
        password="${MSSQL_PASSWORD:-}"

        [[ -n "$password" ]] ||
            die "A new SQL Server SA password is required."

        [[ "$password" =~ ^.{8,128}$ ]] ||
            die "SQL Server SA password must be 8-128 characters."

        log "Running unattended SQL Server initial setup..."
        ACCEPT_EULA=Y \
        MSSQL_PID="$MSSQL_PID" \
        MSSQL_SA_PASSWORD="$password" \
            /opt/mssql/bin/mssql-conf -n setup ||
            die "SQL Server initial setup failed."

        systemctl enable mssql-server
        systemctl restart mssql-server
    else
        systemctl enable mssql-server 2>/dev/null || true
        systemctl start mssql-server || die "MSSQL service could not be started."

        if [[ -z "$password" ]]; then
            # Fresh restore environments may already have a configured instance
            # but the old password is intentionally unknown.
            log "Existing MSSQL installation detected; requesting the NEW/current SA password."
            prompt_password MSSQL_PASSWORD "MSSQL user '$user'"
            password="${MSSQL_PASSWORD:-}"
        fi
    fi

    [[ -n "$password" ]] || die "MSSQL password is required."

    local -a SQLCMD
    SQLCMD=(sqlcmd -S "$server" -C -b -U "$user" -P "$password")

    "${SQLCMD[@]}" -Q "SELECT @@SERVERNAME AS ServerName, SERVERPROPERTY('Edition') AS Edition;" \
        > "$TREE/MSSQL/restore-server-info.txt" 2>&1 ||
        die "Cannot connect to MSSQL with the supplied credentials."

    shopt -s nullglob
    local baks=( "$TREE"/MSSQL/bak/*.bak )
    shopt -u nullglob

    ((${#baks[@]})) || {
        warn "No MSSQL .bak files found."
        unset MSSQL_PASSWORD password
        return 0
    }

    local bak db qdb qpath logical_data logical_log data_file log_file sql

    for bak in "${baks[@]}"; do
        db="$(basename "$bak" .bak)"
        qdb="$(mssql_escape_identifier "$db")"
        qpath="$(mssql_escape_literal "$bak")"

        log "Verifying MSSQL backup: $db"

        if ! "${SQLCMD[@]}" -Q \
            "RESTORE VERIFYONLY FROM DISK=N'$qpath';"; then
            unset MSSQL_PASSWORD password
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

        logical_data="$(printf '%s' "$logical_data" | sed 's/[[:space:]]*$//')"
        logical_log="$(printf '%s' "$logical_log" | sed 's/[[:space:]]*$//')"

        [[ -n "$logical_data" && -n "$logical_log" ]] ||
            die "Could not determine logical data/log files for MSSQL database: $db"

        data_file="/var/opt/mssql/data/${db}.mdf"
        log_file="/var/opt/mssql/data/${db}_log.ldf"

        mkdir -p /var/opt/mssql/data
        chown mssql:mssql /var/opt/mssql/data 2>/dev/null || true

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
            "${SQLCMD[@]}" -Q \
                "IF DB_ID(N'$(mssql_escape_literal "$db")') IS NOT NULL ALTER DATABASE [$qdb] SET MULTI_USER;" \
                >/dev/null 2>&1 || true

            unset MSSQL_PASSWORD password
            die "MSSQL restore failed for database: $db"
        fi

        log "MSSQL database restored: $db"
    done

    unset MSSQL_PASSWORD password
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
    echo "Package policy:"
    if [[ "$UPGRADE_SELECTED_PACKAGES" == 1 ]]; then
        echo "  Selected restore packages were upgraded/installed."
    else
        echo "  Package upgrades were disabled."
    fi
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
    echo "  sudo -u postgres psql -c '\l' 2>/dev/null || true"
    echo "  mongosh --eval 'db.adminCommand({listDatabases:1})' 2>/dev/null || true"
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
