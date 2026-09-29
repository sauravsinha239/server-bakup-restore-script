#!/usr/bin/env bash
# Server Disaster Recovery Restore
# Version: 4.0.0
#
# Design:
#   1. Preflight and identify OS / architecture
#   2. Verify archive and detached SHA-256
#   3. Extract backup into a private immutable-ish workspace
#   4. Validate backup layout before changing the live system
#   5. Install missing software using the native/official repository
#   6. Stage database backup files into service-owned directories
#   7. Restore databases
#   8. Validate services/configuration
#   9. Keep previous live configuration for rollback
#
# IMPORTANT:
#   - Run as root.
#   - Database restores are destructive for databases with the same name.
#   - The backup tree is NEVER recursively chowned.
#   - Firewall and SSH restoration are OFF by default.
#
# Usage:
#   sudo ./server-restore-production-4.0.0.sh /path/to/backup.tar.gz
#   Docker container:
#   docker run --rm -it -v /path/to/backups:/backup:ro \
#       -v /var/run/docker.sock:/var/run/docker.sock \
#       ubuntu:24.04
#   ./server-restore-production-4.0.0.sh \
#       /backup/server-backup-YYYY-MM-DD_HHMMSS.tar.gz
#
# Debug:
#   sudo DEBUG=1 ./server-restore-production-4.0.0.sh /path/to/backup.tar.gz
#
# Optional environment:
#   RESTORE_ROOT=/var/tmp/my-restore
#   LOG_FILE=/var/log/server-restore.log
#   KEEP_STAGING=1
#   PLAN_ONLY=1             # verify archive/layout without modifying the system
#   CHECKSUM_FILE=/path/to/archive.sha256
#   PG_VERSION=18
#   MONGO_VERSION=8.0
#   MSSQL_PID=Developer
#   MSSQL_PASSWORD='...'
#   PG_PASSWORD='...'
#   MONGO_URI='mongodb://127.0.0.1:27017'

set -Eeuo pipefail
IFS=$'\n\t'
umask 077

VERSION="4.1.0"
IN_CONTAINER=0
CONTAINER_RUNTIME=""
SYSTEMD_AVAILABLE=0
DOCKER_SOCKET_AVAILABLE=0
ARCHIVE="${1:-${BACKUP_ARCHIVE:-}}"
DEBUG="${DEBUG:-0}"
KEEP_STAGING="${KEEP_STAGING:-1}"
PLAN_ONLY="${PLAN_ONLY:-0}"
CHECKSUM_FILE="${CHECKSUM_FILE:-}"

RESTORE_ROOT="${RESTORE_ROOT:-/var/tmp/server-restore-$(date +%Y%m%d_%H%M%S)}"
LOG_FILE="${LOG_FILE:-/var/log/server-restore.log}"
TRACE_FILE="$RESTORE_ROOT/debug.trace"
TREE=""
OS_ID=""
OS_VERSION=""
OS_CODENAME=""
ARCH=""
PACKAGE_MANAGER=""

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

WARNINGS=0
ERRORS=0
APT_DISABLED=()
CLEANUP_DONE=0
PG_STAGE=""
ORIGINAL_ARCHIVE_ARG="${1:-}"

# Runtime state
DOCKER_CMD=""
PG_SERVICE=""
MONGO_SERVICE=""

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

init_logging() {
    mkdir -p "$RESTORE_ROOT"
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    touch "$LOG_FILE" 2>/dev/null || LOG_FILE="$RESTORE_ROOT/restore.log"
    chmod 600 "$LOG_FILE" 2>/dev/null || true

    if [[ "$DEBUG" == "1" ]]; then
        exec 19>"$TRACE_FILE"
        export BASH_XTRACEFD=19
        PS4='+ ${BASH_SOURCE}:${LINENO}:${FUNCNAME[0]}: '
        set -x
    fi
}

log() {
    local msg="[$(date '+%F %T')] $*"
    printf '%s\n' "$msg" | tee -a "$LOG_FILE"
}

warn() {
    WARNINGS=$((WARNINGS + 1))
    log "WARNING: $*"
}

die() {
    log "FATAL: $*"
    exit 1
}

on_err() {
    local rc=$?
    local line="${BASH_LINENO[0]:-unknown}"
    local command="${BASH_COMMAND:-unknown}"
    log "ERROR: rc=$rc line=$line command=$command"
    log "ERROR: restore workspace: $RESTORE_ROOT"
    log "ERROR: log: $LOG_FILE"
    [[ "$DEBUG" == "1" ]] && log "ERROR: trace: $TRACE_FILE"
    exit "$rc"
}

trap on_err ERR

# ---------------------------------------------------------------------------
# Generic helpers
# ---------------------------------------------------------------------------

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

have_cmd() {
    command -v "$1" >/dev/null 2>&1
}

run_as() {
    local user="$1"
    shift
    if have_cmd runuser; then
        runuser -u "$user" -- "$@"
    elif have_cmd su; then
        su -s /bin/sh "$user" -c "$(printf '%q ' "$@")"
    else
        die "Neither runuser nor su is available; cannot run as $user."
    fi
}

systemd_usable() {
    (( SYSTEMD_AVAILABLE == 1 ))
}

unit_exists() {
    local unit="$1"
    systemd_usable || return 1
    systemctl list-unit-files "$unit" >/dev/null 2>&1
}

service_active() {
    local svc="$1"
    systemd_usable || return 1
    systemctl is-active --quiet "$svc"
}

service_start() {
    local svc="$1"
    if systemd_usable; then
        systemctl enable "$svc" >/dev/null 2>&1 || true
        systemctl start "$svc" || return 1
        systemctl is-active --quiet "$svc"
    else
        warn "systemd is unavailable; cannot start service unit '$svc' directly."
        return 1
    fi
}

service_restart() {
    local svc="$1"
    if systemd_usable; then
        systemctl restart "$svc" || return 1
        systemctl is-active --quiet "$svc"
    else
        warn "systemd is unavailable; cannot restart service unit '$svc'."
        return 1
    fi
}

require_root() {
    [[ "$EUID" -eq 0 ]] || die "Run this script as root."
}

# Ensure Docker CLI is selected from either normal PATH or common locations.
detect_container() {
    IN_CONTAINER=0
    CONTAINER_RUNTIME=""
    SYSTEMD_AVAILABLE=0
    DOCKER_SOCKET_AVAILABLE=0

    if [[ -f /.dockerenv ]]; then
        IN_CONTAINER=1
        CONTAINER_RUNTIME="docker"
    elif [[ -r /proc/1/cgroup ]] &&
         grep -qaE '(docker|containerd|kubepods|podman|libpod)' /proc/1/cgroup 2>/dev/null; then
        IN_CONTAINER=1
        CONTAINER_RUNTIME="container-runtime"
    elif [[ -r /proc/1/environ ]] &&
         tr '\0' '\n' < /proc/1/environ 2>/dev/null | grep -q '^container='; then
        IN_CONTAINER=1
        CONTAINER_RUNTIME="container"
    fi

    if have_cmd systemctl && [[ -d /run/systemd/system ]] &&
       systemctl list-units --no-pager >/dev/null 2>&1; then
        SYSTEMD_AVAILABLE=1
    fi

    if [[ -S /var/run/docker.sock || -S /run/docker.sock ]]; then
        DOCKER_SOCKET_AVAILABLE=1
    fi

    if (( IN_CONTAINER )); then
        log "Container environment detected: ${CONTAINER_RUNTIME:-unknown}"
    else
        log "Host environment detected."
    fi
    log "systemd available: $SYSTEMD_AVAILABLE"
    log "Docker socket available: $DOCKER_SOCKET_AVAILABLE"
}

resolve_docker_cli() {
    if have_cmd docker; then
        DOCKER_CMD="$(command -v docker)"
    elif [[ -x /usr/bin/docker ]]; then
        DOCKER_CMD=/usr/bin/docker
    else
        DOCKER_CMD=""
    fi
}

detect_os() {
    [[ -r /etc/os-release ]] || die "/etc/os-release not found."
    # shellcheck disable=SC1091
    source /etc/os-release

    OS_ID="${ID:-unknown}"
    OS_VERSION="${VERSION_ID:-unknown}"
    OS_CODENAME="${VERSION_CODENAME:-}"

    case "$OS_ID" in
        ubuntu|debian|arch)
            ;;
        *)
            die "Unsupported operating system: $OS_ID $OS_VERSION"
            ;;
    esac

    ARCH="$(dpkg --print-architecture 2>/dev/null || true)"
    [[ -n "$ARCH" ]] || ARCH="$(uname -m)"

    case "$OS_ID" in
        ubuntu|debian) PACKAGE_MANAGER="apt" ;;
        arch) PACKAGE_MANAGER="pacman" ;;
    esac

    log "OS: $OS_ID $OS_VERSION ${OS_CODENAME:-}"
    log "Architecture: $ARCH"
    log "Package manager: $PACKAGE_MANAGER"
}

safe_mkdir() {
    local path="$1"
    local mode="${2:-0755}"
    install -d -m "$mode" "$path"
}

backup_live_path() {
    local path="$1"
    local stamp="$2"
    local backup="${path}.before-restore-${stamp}"

    if [[ -e "$path" || -L "$path" ]]; then
        mv -- "$path" "$backup" || die "Could not move existing $path to $backup"
        printf '%s\n' "$backup"
    else
        printf '%s\n' ""
    fi
}

restore_copy() {
    # Copy source tree WITHOUT changing source ownership.
    # rsync is preferred because it handles ACL/xattr/hardlink metadata.
    local src="$1"
    local dst="$2"

    [[ -d "$src" ]] || die "Source directory does not exist: $src"
    safe_mkdir "$dst"

    if have_cmd rsync; then
        rsync -aHAX --numeric-ids -- "$src"/ "$dst"/
    else
        tar --acls --xattrs --numeric-owner -C "$src" -cf - . |
            tar --acls --xattrs --numeric-owner -C "$dst" -xpf -
    fi
}

verify_file() {
    local file="$1"
    [[ -f "$file" ]] || die "Required backup file does not exist: $file"
    [[ -r "$file" ]] || die "Required backup file is not readable: $file"
    [[ -s "$file" ]] || die "Required backup file is empty: $file"
}

# ---------------------------------------------------------------------------
# Archive verification / extraction
# ---------------------------------------------------------------------------

verify_sha256() {
    local archive="$1"
    local checksum="$2"
    local expected actual checksum_line

    [[ -f "$archive" ]] || die "Backup archive does not exist: $archive"
    [[ -r "$archive" ]] || die "Backup archive is not readable: $archive"
    [[ -s "$archive" ]] || die "Backup archive is empty: $archive"
    [[ -f "$checksum" ]] || die "SHA-256 file does not exist: $checksum"
    [[ -r "$checksum" ]] || die "SHA-256 file is not readable: $checksum"

    checksum_line="$(awk '
        {
            x=$1
            if (length(x)==64 && x ~ /^[0-9A-Fa-f]+$/) { print; exit }
        }
    ' "$checksum")"
    expected="$(printf '%s\n' "$checksum_line" | awk '{print $1}')"

    [[ "$expected" =~ ^[0-9A-Fa-f]{64}$ ]] ||
        die "Invalid SHA-256 file format: $checksum"

    # Do NOT use `sha256sum -c` here. Detached checksum files often contain
    # the original absolute path, which becomes stale after a backup is moved,
    # copied, or mounted into a Docker container.
    actual="$(sha256sum "$archive" | awk '{print $1}')"

    log "Expected SHA-256: $expected"
    log "Actual SHA-256:   $actual"

    [[ "${expected,,}" == "${actual,,}" ]] ||
        die "SHA-256 verification failed."

    log "SHA-256: OK"
}

validate_tar_paths() {
    local archive="$1"
    local bad

    bad="$(tar -tzf "$archive" | awk '
        index($0, "\0") {next}
        $0 ~ /^\// || $0 ~ /(^|\/)\.\.($|\/)/ {print; exit}
    ')"
    [[ -z "$bad" ]] || die "Unsafe path found in archive: $bad"
}

verify_archive() {
    local checksum="${CHECKSUM_FILE:-${ARCHIVE}.sha256}"

    need_cmd gzip
    need_cmd tar
    need_cmd sha256sum

    [[ -f "$ARCHIVE" ]] || die "Backup archive does not exist: $ARCHIVE"
    [[ -r "$ARCHIVE" ]] || die "Backup archive is not readable: $ARCHIVE"
    [[ -s "$ARCHIVE" ]] || die "Backup archive is empty: $ARCHIVE"

    log "Archive: $ARCHIVE"
    log "Checksum: $checksum"
    log "Checking gzip integrity..."
    gzip -t "$ARCHIVE" || die "gzip integrity check failed."
    log "gzip integrity: OK"

    log "Checking tar structure..."
    tar -tzf "$ARCHIVE" >/dev/null || die "tar archive is corrupt."
    log "tar structure: OK"

    log "Checking archive paths..."
    validate_tar_paths "$ARCHIVE"
    log "Archive paths: OK"

    if [[ -f "$checksum" ]]; then
        log "Checking detached SHA-256..."
        verify_sha256 "$ARCHIVE" "$checksum"
    else
        warn "Detached checksum not found: $checksum"
        if [[ -t 0 ]]; then
            read -r -p "Continue without detached SHA-256 verification? [y/N]: " ans
            [[ "$ans" =~ ^[Yy]([Ee][Ss])?$ ]] ||
                die "Restore aborted because checksum verification is unavailable."
        else
            die "Non-interactive restore requires $checksum."
        fi
    fi
}

extract_archive() {
    verify_archive

    safe_mkdir "$RESTORE_ROOT" 0700
    chmod 700 "$RESTORE_ROOT"
    log "Extracting archive to: $RESTORE_ROOT"

    tar --acls --xattrs --numeric-owner \
        --no-same-owner \
        -xzf "$ARCHIVE" -C "$RESTORE_ROOT" ||
        die "Archive extraction failed."

    TREE="$RESTORE_ROOT/server-backup"

    [[ -d "$TREE" ]] ||
        die "Backup layout invalid: missing $TREE"

    log "Backup root: $TREE"
}

# ---------------------------------------------------------------------------
# Backup layout inspection
# ---------------------------------------------------------------------------

show_backup_layout() {
    log "Backup components detected:"

    for d in \
        WWW \
        NGINX \
        SECURITY \
        SYSTEMD \
        CROWDSEC \
        POSTGRES \
        MONGODB \
        MSSQL \
        DOCKER \
        FIREWALL \
        SSH
    do
        if [[ -e "$TREE/$d" ]]; then
            log "  [FOUND] $d"
        else
            log "  [----]  $d"
        fi
    done
}

choose_restore_components() {
    # Keep non-interactive runs deterministic. Interactive runs get the old
    # component-selection workflow back, with safe defaults.
    if [[ ! -t 0 || "${NONINTERACTIVE:-0}" == "1" ]]; then
        log "Non-interactive mode: using configured restore component defaults."
        return 0
    fi

    # Container-aware defaults.
    if [[ "$SYSTEMD_AVAILABLE" != "1" ]]; then
        RESTORE_SYSTEMD=0
    fi
    if [[ "$IN_CONTAINER" == "1" && "$DOCKER_SOCKET_AVAILABLE" != "1" ]]; then
        RESTORE_DOCKER=0
    fi

    echo
    echo "============================================================"
    echo " Restore components"
    echo "============================================================"
    echo "Answer Y to restore, N to skip. Defaults are shown in [ ]"
    echo

    local ans
    read -r -p "Restore /var/www? [Y/n]: " ans
    [[ -z "$ans" || "$ans" =~ ^[Yy]$ ]] && RESTORE_WWW=1 || RESTORE_WWW=0

    read -r -p "Restore Nginx? [Y/n]: " ans
    [[ -z "$ans" || "$ans" =~ ^[Yy]$ ]] && RESTORE_NGINX=1 || RESTORE_NGINX=0

    read -r -p "Restore PostgreSQL? [Y/n]: " ans
    [[ -z "$ans" || "$ans" =~ ^[Yy]$ ]] && RESTORE_POSTGRES=1 || RESTORE_POSTGRES=0

    read -r -p "Restore MongoDB? [Y/n]: " ans
    [[ -z "$ans" || "$ans" =~ ^[Yy]$ ]] && RESTORE_MONGO=1 || RESTORE_MONGO=0

    read -r -p "Restore MSSQL? [y/N]: " ans
    [[ "$ans" =~ ^[Yy]$ ]] && RESTORE_MSSQL=1 || RESTORE_MSSQL=0

    if [[ "$SYSTEMD_AVAILABLE" == "1" ]]; then
        read -r -p "Restore systemd units? [Y/n]: " ans
        [[ -z "$ans" || "$ans" =~ ^[Yy]$ ]] && RESTORE_SYSTEMD=1 || RESTORE_SYSTEMD=0
    else
        RESTORE_SYSTEMD=0
        log "systemd unavailable: systemd restore disabled."
    fi

    read -r -p "Restore CrowdSec config? [Y/n]: " ans
    [[ -z "$ans" || "$ans" =~ ^[Yy]$ ]] && RESTORE_CROWDSEC=1 || RESTORE_CROWDSEC=0

    if [[ "$IN_CONTAINER" == "1" && "$DOCKER_SOCKET_AVAILABLE" != "1" ]]; then
        RESTORE_DOCKER=0
        log "Docker container without Docker socket: Docker volume restore disabled."
    else
        read -r -p "Restore Docker volumes? [Y/n]: " ans
        [[ -z "$ans" || "$ans" =~ ^[Yy]$ ]] && RESTORE_DOCKER=1 || RESTORE_DOCKER=0
    fi

    read -r -p "Restore firewall? [y/N]: " ans
    [[ "$ans" =~ ^[Yy]$ ]] && RESTORE_FIREWALL=1 || RESTORE_FIREWALL=0

    read -r -p "Restore SSH configuration? [y/N]: " ans
    [[ "$ans" =~ ^[Yy]$ ]] && RESTORE_SSH=1 || RESTORE_SSH=0

    echo
    log "Selected restore components:"
    log "  WWW=$RESTORE_WWW NGINX=$RESTORE_NGINX POSTGRES=$RESTORE_POSTGRES MONGO=$RESTORE_MONGO MSSQL=$RESTORE_MSSQL"
    log "  SYSTEMD=$RESTORE_SYSTEMD CROWDSEC=$RESTORE_CROWDSEC DOCKER=$RESTORE_DOCKER FIREWALL=$RESTORE_FIREWALL SSH=$RESTORE_SSH"

    read -r -p "Continue with these selections? [Y/n]: " ans
    [[ -z "$ans" || "$ans" =~ ^[Yy]$ ]] || die "Restore cancelled by user."
}

validate_selected_backup() {
    if [[ "$RESTORE_WWW" == 1 ]]; then
        [[ -f "$TREE/WWW/var-www.tar.gz" ]] ||
            warn "/var/www selected but backup file is absent."
    fi

    if [[ "$RESTORE_NGINX" == 1 ]]; then
        [[ -d "$TREE/NGINX/etc-nginx" ]] ||
            warn "Nginx selected but NGINX/etc-nginx is absent."
    fi

    if [[ "$RESTORE_POSTGRES" == 1 ]]; then
        [[ -d "$TREE/POSTGRES" ]] ||
            warn "PostgreSQL selected but POSTGRES directory is absent."
    fi

    if [[ "$RESTORE_MONGO" == 1 ]]; then
        [[ -f "$TREE/MONGODB/mongodb.archive.gz" ]] ||
            warn "MongoDB selected but mongodb.archive.gz is absent."
    fi

    if [[ "$RESTORE_MSSQL" == 1 ]]; then
        [[ -d "$TREE/MSSQL/bak" ]] ||
            warn "MSSQL selected but MSSQL/bak is absent."
    fi
}

# ---------------------------------------------------------------------------
# APT repository management
# ---------------------------------------------------------------------------

apt_disable_conflicting_sources() {
    local f backup
    [[ "$PACKAGE_MANAGER" == "apt" ]] || return 0

    # Any pre-existing Microsoft source can break apt-get update before the
    # restore script gets a chance to install the correct MSSQL repository.
    # Keep the original as *.restore-disabled and restore it only if the script
    # did not create a canonical replacement with the same path.
    while IFS= read -r -d '' f; do
        if grep -qiE 'packages\.microsoft\.com' "$f" 2>/dev/null; then
            case "$f" in
                *.restore-disabled|*.restore-disabled.*) continue ;;
            esac
            backup="${f}.restore-disabled"
            if [[ -e "$backup" ]]; then
                backup="${f}.restore-disabled.$(date +%s)"
            fi
            mv -f -- "$f" "$backup"
            APT_DISABLED+=("$backup")
            log "Temporarily disabled Microsoft source: $f"
        fi
    done < <(
        {
            [[ -f /etc/apt/sources.list ]] && printf '%s\0' /etc/apt/sources.list
            find /etc/apt/sources.list.d -maxdepth 1 -type f \
                \( -name '*.list' -o -name '*.sources' \) -print0 2>/dev/null || true
        }
    )
}

apt_restore_sources() {
    local f original
    for f in "${APT_DISABLED[@]:-}"; do
        [[ -f "$f" ]] || continue
        original="${f%.restore-disabled}"
        # Timestamped backups have a different suffix.
        if [[ "$original" == "$f" ]]; then
            original="${f%%.restore-disabled.*}"
        fi
        if [[ -e "$original" ]]; then
            warn "Not restoring disabled APT source because replacement exists: $original"
            continue
        fi

        local microsoft_current=0
        while IFS= read -r -d '' current; do
            if grep -qiE 'packages\.microsoft\.com' "$current" 2>/dev/null; then
                microsoft_current=1
                break
            fi
        done < <(find /etc/apt/sources.list.d -maxdepth 1 -type f \
            \( -name '*.list' -o -name '*.sources' \) -print0 2>/dev/null || true)

        if (( microsoft_current == 1 )); then
            log "Keeping disabled legacy Microsoft source disabled because an active Microsoft repository exists."
            continue
        fi

        mv -f -- "$f" "$original" || warn "Could not restore APT source: $original"
    done
    APT_DISABLED=()
}

# ---------------------------------------------------------------------------
# Package installation
# ---------------------------------------------------------------------------

install_base_tools_apt() {
    apt-get update
    apt-get install -y \
        ca-certificates curl gnupg \
        tar gzip coreutils rsync \
        openssl
}

install_postgres_ubuntu_official() {
    local version="${PG_VERSION:-18}"
    local key="/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc"
    local repo="/etc/apt/sources.list.d/pgdg.sources"

    log "PostgreSQL: configuring official PGDG repository."

    apt-get install -y postgresql-common
    install -d -m 0755 /usr/share/postgresql-common/pgdg

    curl -fsSL \
        -o "$key" \
        https://www.postgresql.org/media/keys/ACCC4CF8.asc

    chmod 0644 "$key"

    local pg_arch
    case "$ARCH" in
        amd64|arm64) pg_arch="$ARCH" ;;
        *) die "Unsupported PostgreSQL PGDG architecture: $ARCH" ;;
    esac

    cat > "$repo" <<EOF
Types: deb
URIs: https://apt.postgresql.org/pub/repos/apt
Suites: ${OS_CODENAME}-pgdg
Architectures: ${pg_arch}
Components: main
Signed-By: ${key}
EOF

    chmod 0644 "$repo"

    apt-get update
    apt-get install -y "postgresql-${version}" "postgresql-client-${version}"
}

install_postgres() {
    if have_cmd psql && have_cmd pg_restore; then
        log "PostgreSQL client tools already available."
    elif [[ "$PACKAGE_MANAGER" == "apt" ]]; then
        if apt-cache show postgresql >/dev/null 2>&1; then
            apt-get update
            apt-get install -y postgresql postgresql-client
        else
            install_postgres_ubuntu_official
        fi
    elif [[ "$PACKAGE_MANAGER" == "pacman" ]]; then
        pacman -S --noconfirm --needed postgresql
    else
        die "Cannot install PostgreSQL on this OS."
    fi

    have_cmd psql || die "psql installation failed."
    have_cmd pg_restore || die "pg_restore installation failed."
}

install_mongodb_ubuntu_official() {
    local key="/usr/share/keyrings/mongodb-server-8.0.gpg"
    local list="/etc/apt/sources.list.d/mongodb-org-8.0.list"

    [[ "$OS_ID" == "ubuntu" ]] ||
        die "MongoDB automatic repository installation is only implemented for supported Ubuntu releases."

    case "$OS_CODENAME" in
        noble|jammy|focal) ;;
        *) die "MongoDB 8.0 official Ubuntu repository does not support codename: $OS_CODENAME" ;;
    esac

    log "MongoDB: configuring official MongoDB 8.0 repository."

    apt-get install -y gnupg curl
    install -d -m 0755 /usr/share/keyrings

    curl -fsSL https://pgp.mongodb.com/server-8.0.asc |
        gpg --dearmor --yes -o "$key"

    chmod 0644 "$key"

    local mongo_arch
    case "$ARCH" in
        amd64) mongo_arch=amd64 ;;
        arm64) mongo_arch=arm64 ;;
        *) die "Unsupported MongoDB architecture: $ARCH" ;;
    esac

    cat > "$list" <<EOF
deb [ arch=${mongo_arch} signed-by=${key} ] https://repo.mongodb.org/apt/ubuntu ${OS_CODENAME}/mongodb-org/8.0 multiverse
EOF

    chmod 0644 "$list"

    apt-get update
    apt-get install -y mongodb-org
}

install_mongodb() {
    if have_cmd mongorestore; then
        log "MongoDB Database Tools already available."
    elif [[ "$PACKAGE_MANAGER" == "apt" && "$OS_ID" == "ubuntu" ]]; then
        install_mongodb_ubuntu_official
    elif [[ "$PACKAGE_MANAGER" == "pacman" ]]; then
        # Arch does not provide MongoDB Community from the official Arch
        # repositories. Do not silently install an unrelated package.
        die "MongoDB is not installed on Arch. Install MongoDB Community using MongoDB's supported Linux package/tarball method, then rerun."
    else
        die "No supported official MongoDB installation path for $OS_ID."
    fi

    have_cmd mongorestore || die "mongorestore installation failed."
}

install_mssql_ubuntu_official() {
    local repo="/etc/apt/sources.list.d/mssql-server-restore.list"
    local key="/usr/share/keyrings/microsoft-prod.gpg"

    [[ "$OS_ID" == "ubuntu" ]] ||
        die "Microsoft SQL Server automatic installation is supported here only on Ubuntu."

    case "$OS_VERSION" in
        24.04)
            log "MSSQL: using Microsoft SQL Server 2025 repository for Ubuntu 24.04."
            curl -fsSL \
                https://packages.microsoft.com/config/ubuntu/24.04/mssql-server-2025.list \
                -o "$repo"
            ;;
        22.04)
            log "MSSQL: using Microsoft SQL Server 2022 repository for Ubuntu 22.04."
            curl -fsSL \
                https://packages.microsoft.com/config/ubuntu/22.04/mssql-server-2022.list \
                -o "$repo"
            ;;
        20.04)
            log "MSSQL: using Microsoft SQL Server 2022 repository for Ubuntu 20.04."
            curl -fsSL \
                https://packages.microsoft.com/config/ubuntu/20.04/mssql-server-2022.list \
                -o "$repo"
            ;;
        *)
            die "No supported Microsoft SQL Server repository mapping for Ubuntu $OS_VERSION."
            ;;
    esac

    install -d -m 0755 /usr/share/keyrings

    curl -fsSL https://packages.microsoft.com/keys/microsoft.asc |
        gpg --dearmor --yes -o "$key"

    chmod 0644 "$key"
    chmod 0644 "$repo"

    apt-get update
    apt-get install -y mssql-server

    # Microsoft documents mssql-tools18 separately.
    local tools_repo="/etc/apt/sources.list.d/mssql-tools18.list"
    curl -fsSL \
        "https://packages.microsoft.com/config/ubuntu/${OS_VERSION}/prod.list" \
        -o "$tools_repo"

    chmod 0644 "$tools_repo"

    apt-get update
    ACCEPT_EULA=Y apt-get install -y mssql-tools18 unixodbc-dev

    if [[ -x /opt/mssql-tools18/bin/sqlcmd ]]; then
        ln -sf /opt/mssql-tools18/bin/sqlcmd /usr/local/bin/sqlcmd
    fi

    [[ -x /opt/mssql/bin/mssql-conf ]] ||
        die "mssql-conf not installed."

    have_cmd sqlcmd ||
        die "sqlcmd not installed."
}

install_mssql() {
    if [[ -x /opt/mssql/bin/mssql-conf ]] && have_cmd sqlcmd; then
        log "MSSQL server/tools already installed."
        return
    fi

    install_mssql_ubuntu_official
}

install_selected_packages() {
    log "Installing required restore software..."

    case "$PACKAGE_MANAGER" in
        apt)
            export DEBIAN_FRONTEND=noninteractive
            apt_disable_conflicting_sources
            install_base_tools_apt

            if [[ "$RESTORE_NGINX" == 1 ]]; then
                apt-get install -y nginx
            fi

            if [[ "$RESTORE_POSTGRES" == 1 ]]; then
                install_postgres
            fi

            if [[ "$RESTORE_MONGO" == 1 ]]; then
                install_mongodb
            fi

            if [[ "$RESTORE_MSSQL" == 1 ]]; then
                install_mssql
            fi

            if [[ "$RESTORE_DOCKER" == 1 ]]; then
                if (( IN_CONTAINER == 1 && DOCKER_SOCKET_AVAILABLE == 0 )); then
                    warn "Docker restore requested, but running inside a container without a Docker socket; Docker daemon package will not be installed."
                else
                    apt-get install -y docker.io
                fi
            fi

            if [[ "$RESTORE_SSH" == 1 ]]; then
                apt-get install -y openssh-server
            fi

            if [[ "$RESTORE_FIREWALL" == 1 ]]; then
                apt-get install -y ufw iptables nftables
            fi
            ;;
        pacman)
            pacman -Sy --noconfirm --needed \
                ca-certificates curl tar gzip rsync

            if [[ "$RESTORE_NGINX" == 1 ]]; then
                pacman -S --noconfirm --needed nginx
            fi

            if [[ "$RESTORE_POSTGRES" == 1 ]]; then
                install_postgres
            fi

            if [[ "$RESTORE_MONGO" == 1 ]]; then
                install_mongodb
            fi

            if [[ "$RESTORE_MSSQL" == 1 ]]; then
                die "Microsoft SQL Server Linux is not installed from Arch official repositories. Use a supported Ubuntu host/package for automatic MSSQL recovery."
            fi

            if [[ "$RESTORE_DOCKER" == 1 ]]; then
                if (( IN_CONTAINER == 1 && DOCKER_SOCKET_AVAILABLE == 0 )); then
                    warn "Docker restore requested, but no Docker socket is available inside this container."
                else
                    pacman -S --noconfirm --needed docker
                fi
            fi

            if [[ "$RESTORE_SSH" == 1 ]]; then
                pacman -S --noconfirm --needed openssh
            fi
            ;;
    esac

    apt_restore_sources
}

# ---------------------------------------------------------------------------
# /var/www
# ---------------------------------------------------------------------------

restore_www() {
    [[ "$RESTORE_WWW" == 1 ]] || return 0
    [[ -f "$TREE/WWW/var-www.tar.gz" ]] || {
        warn "Skipping /var/www: backup component not present."
        return
    }

    log "[1/11] Restoring /var/www"

    local stage="$RESTORE_ROOT/stage/www"
    local old="/var/www.before-restore-$(date +%Y%m%d_%H%M%S)"

    rm -rf "$stage"
    safe_mkdir "$stage" 0700

    tar --acls --xattrs --numeric-owner \
        -xzf "$TREE/WWW/var-www.tar.gz" -C "$stage" ||
        die "/var/www archive extraction failed."

    # Accept the two common backup layouts:
    #   1) archive contains var/www/... (created from /)
    #   2) archive contains the contents of /var/www directly
    local source_dir=""
    if [[ -d "$stage/var/www" ]]; then
        source_dir="$stage/var/www"
    elif [[ -d "$stage/www" && ! -d "$stage/var" ]]; then
        source_dir="$stage/www"
    else
        # Direct-content layout is valid if extraction produced at least one
        # file/directory and did not contain an unexpected top-level tree.
        if find "$stage" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
            source_dir="$stage"
        fi
    fi

    [[ -n "$source_dir" && -d "$source_dir" ]] ||
        die "WWW archive layout invalid: expected var/www or direct /var/www contents."

    local new_www="$RESTORE_ROOT/stage/www-activated"
    rm -rf "$new_www"
    safe_mkdir "$new_www" 0755
    restore_copy "$source_dir" "$new_www"

    if [[ -e /var/www || -L /var/www ]]; then
        mv /var/www "$old" ||
            die "Could not move existing /var/www to $old"
    fi

    mv "$new_www" /var/www || {
        [[ -e "$old" ]] && mv "$old" /var/www || true
        die "Could not activate restored /var/www; previous /var/www was restored."
    }
    chown root:root /var/www
    chmod 755 /var/www

    log "/var/www restored. Previous copy: $old"
}

# ---------------------------------------------------------------------------
# Let's Encrypt / Nginx
# ---------------------------------------------------------------------------

restore_letsencrypt() {
    [[ "$RESTORE_NGINX" == 1 ]] || return 0
    [[ -d "$TREE/SECURITY/etc-letsencrypt" ]] || {
        warn "Let's Encrypt backup not present."
        return
    }

    log "[2/11] Restoring Let's Encrypt"

    local stage="$RESTORE_ROOT/stage/letsencrypt"
    local old="/etc/letsencrypt.before-restore-$(date +%Y%m%d_%H%M%S)"

    rm -rf "$stage"
    safe_mkdir "$stage" 0700

    restore_copy "$TREE/SECURITY/etc-letsencrypt" "$stage"

    if [[ -e /etc/letsencrypt ]]; then
        mv /etc/letsencrypt "$old"
    fi

    mv "$stage" /etc/letsencrypt
    chown -R root:root /etc/letsencrypt
    chmod 700 /etc/letsencrypt

    log "Let's Encrypt restored. Previous copy: $old"
}

normalize_nginx_http2() {
    # Only handles the current Nginx deprecation:
    #   listen 443 ssl http2;
    # becomes:
    #   listen 443 ssl;
    #   http2 on;
    local file tmp

    while IFS= read -r -d '' file; do
        if grep -Eq '^[[:space:]]*listen[[:space:]].*[[:space:]]http2[[:space:]]*;' "$file"; then
            tmp="${file}.tmp.$$"

            awk '
            BEGIN { inserted=0 }
            {
                line=$0
                if (line !~ /^[[:space:]]*#/ &&
                    line ~ /^[[:space:]]*listen[[:space:]].*[[:space:]]http2[[:space:]]*;/) {
                    sub(/[[:space:]]+http2[[:space:]]*;/, ";", line)
                    print line
                    if (!inserted) {
                        print "    http2 on;"
                        inserted=1
                    }
                } else {
                    print line
                }
            }' "$file" > "$tmp" || die "Failed editing Nginx file: $file"

            cat "$tmp" > "$file"
            rm -f "$tmp"
            log "Nginx: converted deprecated listen ... http2 syntax in $file"
        fi
    done < <(find /etc/nginx -type f -print0 2>/dev/null)
}

restore_nginx() {
    [[ "$RESTORE_NGINX" == 1 ]] || return 0
    [[ -d "$TREE/NGINX/etc-nginx" ]] || {
        warn "Nginx backup not present."
        return
    }

    log "[3/11] Restoring Nginx"

    local stage="$RESTORE_ROOT/stage/nginx"
    local old="/etc/nginx.before-restore-$(date +%Y%m%d_%H%M%S)"

    rm -rf "$stage"
    safe_mkdir "$stage" 0700

    restore_copy "$TREE/NGINX/etc-nginx" "$stage"

    if systemd_usable; then
        systemctl stop nginx 2>/dev/null || true
    else
        pkill -TERM -x nginx 2>/dev/null || true
    fi

    if [[ -e /etc/nginx ]]; then
        mv /etc/nginx "$old"
    fi

    mv "$stage" /etc/nginx
    chown -R root:root /etc/nginx
    chmod 755 /etc/nginx

    normalize_nginx_http2

    if ! nginx -t; then
        log "Nginx validation failed. Rolling back."
        rm -rf /etc/nginx
        [[ -d "$old" ]] && mv "$old" /etc/nginx
        if systemd_usable; then
            systemctl start nginx 2>/dev/null || true
        else
            nginx >/dev/null 2>&1 || true
        fi
        die "Nginx restore failed; previous configuration restored."
    fi

    if systemd_usable; then
        service_start nginx || die "Nginx failed to start after successful configuration validation."
    else
        nginx >/dev/null 2>&1 || die "Nginx failed to start in systemd-less environment."
    fi

    log "Nginx restored and running. Previous copy: $old"
}

# ---------------------------------------------------------------------------
# systemd / CrowdSec
# ---------------------------------------------------------------------------

restore_systemd() {
    [[ "$RESTORE_SYSTEMD" == 1 ]] || return 0

    log "[4/11] Restoring systemd units"

    if ! systemd_usable; then
        warn "systemd is not available in this environment; systemd unit restore is skipped."
        return 0
    fi

    if [[ -d "$TREE/SYSTEMD/etc-systemd-system" ]]; then
        restore_copy \
            "$TREE/SYSTEMD/etc-systemd-system" \
            /etc/systemd/system
    fi

    if [[ -d "$TREE/SYSTEMD/etc-systemd-user" ]]; then
        restore_copy \
            "$TREE/SYSTEMD/etc-systemd-user" \
            /etc/systemd/user
    fi

    systemctl daemon-reload
    log "systemd units restored."
}

restore_crowdsec() {
    [[ "$RESTORE_CROWDSEC" == 1 ]] || return 0
    [[ -d "$TREE/CROWDSEC/etc-crowdsec" ]] || {
        warn "CrowdSec backup not present."
        return
    }

    log "[5/11] Restoring CrowdSec configuration"

    local old="/etc/crowdsec.before-restore-$(date +%Y%m%d_%H%M%S)"

    if systemd_usable; then
        systemctl stop crowdsec 2>/dev/null || true
    fi

    if [[ -e /etc/crowdsec ]]; then
        mv /etc/crowdsec "$old"
    fi

    restore_copy "$TREE/CROWDSEC/etc-crowdsec" /etc/crowdsec
    chown -R root:root /etc/crowdsec

    if systemd_usable && unit_exists crowdsec.service; then
        systemctl enable crowdsec >/dev/null 2>&1 || true
        systemctl start crowdsec || warn "CrowdSec did not start. Previous config: $old"
    else
        warn "CrowdSec service start skipped because systemd is unavailable or unit is missing."
    fi
}

# ---------------------------------------------------------------------------
# PostgreSQL
# ---------------------------------------------------------------------------

pg_sql_ident() {
    local s="$1"
    printf '%s' "${s//\"/\"\"}"
}

pg_sql_literal() {
    local s="$1"
    printf '%s' "${s//\'/\'\'}"
}

pg_prepare_globals() {
    local input="$1"
    local output="$2"

    verify_file "$input"
    safe_mkdir "$(dirname "$output")" 0700

    local roles_file="$RESTORE_ROOT/pg-existing-roles.txt"
    run_as postgres psql -Atqc \
        "SELECT rolname FROM pg_roles;" > "$roles_file"

    declare -A existing=()
    local role
    while IFS= read -r role; do
        [[ -n "$role" ]] && existing["$role"]=1
    done < "$roles_file"

    : > "$output"

    local line decl role_name
    local create_role_re='^CREATE[[:space:]]+ROLE[[:space:]]+(.+);[[:space:]]*$'

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ $create_role_re ]]; then
            decl="${BASH_REMATCH[1]}"
            # globals.sql normally contains `CREATE ROLE <name> ...`.
            # Extract only the role identifier; do not treat WITH attributes as
            # part of the role name.
            if [[ "${decl:0:1}" == '"' ]]; then
                role_name="$(printf '%s\n' "$decl" | sed -E 's/^"((""|[^"])*)".*/\1/')"
                role_name="$(printf '%s\n' "$role_name" | sed 's/""/"/g')"
            else
                role_name="${decl%%[[:space:]]*}"
                role_name="${role_name%;}"
            fi

            if [[ -n "${existing[$role_name]+yes}" ]]; then
                printf -- '-- RESTORE-SKIPPED existing role: %s\n' "$role_name" >> "$output"
            else
                printf '%s\n' "$line" >> "$output"
            fi
        else
            printf '%s\n' "$line" >> "$output"
        fi
    done < "$input"

    chown postgres:postgres "$output"
    chmod 600 "$output"
    [[ -s "$output" ]] || die "Prepared PostgreSQL globals file is empty."

    log "PostgreSQL globals prepared: $output"
}

pg_drop_create_database() {
    local db="$1"
    local ident
    ident="$(pg_sql_ident "$db")"

    if run_as postgres psql -Atqc \
        "SELECT 1 FROM pg_database WHERE datname='$(pg_sql_literal "$db")';" \
        | grep -qx 1; then

        log "PostgreSQL: dropping existing database: $db"

        if ! run_as postgres psql -v ON_ERROR_STOP=1 -c \
            "DROP DATABASE \"$ident\" WITH (FORCE);" 2>/dev/null; then
            run_as postgres psql -v ON_ERROR_STOP=1 -c \
                "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$(pg_sql_literal "$db")';" \
                >/dev/null || true

            run_as postgres psql -v ON_ERROR_STOP=1 -c \
                "DROP DATABASE \"$ident\";" ||
                die "Could not drop PostgreSQL database: $db"
        fi
    fi

    run_as postgres psql -v ON_ERROR_STOP=1 -c \
        "CREATE DATABASE \"$ident\";" ||
        die "Could not create PostgreSQL database: $db"
}

start_postgres() {
    if systemd_usable && unit_exists postgresql.service; then
        service_start postgresql && return 0
    fi

    if have_cmd pg_lsclusters && have_cmd pg_ctlcluster; then
        local line version cluster status
        while read -r version cluster status _; do
            [[ -n "$version" && -n "$cluster" ]] || continue
            if [[ "$status" != "online" ]]; then
                log "PostgreSQL: starting cluster $version/$cluster without systemd."
                pg_ctlcluster "$version" "$cluster" start || true
            fi
            if pg_ctlcluster "$version" "$cluster" status >/dev/null 2>&1; then
                PG_SERVICE="${version}/${cluster}"
                return 0
            fi
        done < <(pg_lsclusters --no-header 2>/dev/null || true)
    fi

    # Fallback for images where the cluster exists but pg_lsclusters is absent.
    if have_cmd pg_ctl; then
        local datadir
        datadir="$(find /var/lib/postgresql -mindepth 2 -maxdepth 2 -type f -name PG_VERSION -printf '%h\n' 2>/dev/null | head -n1 || true)"
        if [[ -n "$datadir" ]]; then
            run_as postgres pg_ctl -D "$datadir" -w start || true
            run_as postgres pg_ctl -D "$datadir" status >/dev/null 2>&1 && return 0
        fi
    fi

    die "PostgreSQL could not be started (systemd unavailable and no usable cluster start method found)."
}

restore_postgres() {
    [[ "$RESTORE_POSTGRES" == 1 ]] || return 0
    [[ -d "$TREE/POSTGRES" ]] || {
        warn "PostgreSQL backup not present."
        return
    }

    log "[6/11] Restoring PostgreSQL"

    need_cmd psql
    need_cmd pg_restore
    id postgres >/dev/null 2>&1 ||
        die "PostgreSQL OS user does not exist."

    start_postgres

    PG_STAGE="/var/tmp/server-restore-postgresql-$(date +%Y%m%d_%H%M%S)-$$"
    local pg_stage="$PG_STAGE"
    rm -rf "$pg_stage"
    safe_mkdir "$pg_stage" 0700

    # IMPORTANT: backup tree is not chowned. Only the staged database files
    # are assigned to postgres.
    safe_mkdir "$pg_stage/databases" 0700
    chown postgres:postgres "$pg_stage" "$pg_stage/databases"
    log "PostgreSQL staging directory: $pg_stage"
    chmod 700 "$pg_stage" "$pg_stage/databases"

    if [[ -f "$TREE/POSTGRES/globals.sql" ]]; then
        cp --preserve=mode,timestamps \
            "$TREE/POSTGRES/globals.sql" \
            "$pg_stage/globals.sql"

        chown postgres:postgres "$pg_stage/globals.sql"
        chmod 600 "$pg_stage/globals.sql"

        pg_prepare_globals \
            "$pg_stage/globals.sql" \
            "$pg_stage/globals.restore.sql"

        log "PostgreSQL: restoring roles/global privileges."
        run_as postgres psql -v ON_ERROR_STOP=1 \
            -d postgres \
            -f "$pg_stage/globals.restore.sql" ||
            die "PostgreSQL global restore failed."
    fi

    local -a dumps=()
    local dump db
    shopt -s nullglob
    dumps=( "$TREE/POSTGRES/databases/"*.dump )
    shopt -u nullglob

    if ((${#dumps[@]} == 0)); then
        warn "No PostgreSQL database dumps found."
        return
    fi

    local i=0
    for dump in "${dumps[@]}"; do
        i=$((i + 1))
        verify_file "$dump"

        db="$(basename "$dump" .dump)"
        log "PostgreSQL [$i/${#dumps[@]}]: staging $db"

        cp --preserve=mode,timestamps "$dump" "$pg_stage/databases/$db.dump"
        chown postgres:postgres "$pg_stage/databases/$db.dump"
        chmod 600 "$pg_stage/databases/$db.dump"

        pg_drop_create_database "$db"

        log "PostgreSQL [$i/${#dumps[@]}]: pg_restore $db"

        run_as postgres pg_restore \
            --exit-on-error \
            --no-owner \
            --no-acl \
            --dbname="$db" \
            "$pg_stage/databases/$db.dump" ||
            die "PostgreSQL restore failed: $db"

        # Basic post-restore verification.
        run_as postgres psql -d "$db" -Atqc "SELECT current_database();" |
            grep -Fxq "$db" ||
            die "PostgreSQL verification failed: $db"

        log "PostgreSQL [$i/${#dumps[@]}]: OK"
    done

    log "PostgreSQL restore completed."
}

# ---------------------------------------------------------------------------
# MongoDB
# ---------------------------------------------------------------------------

start_mongo() {
    if systemd_usable; then
        if unit_exists mongod.service && service_start mongod; then
            MONGO_SERVICE=mongod
            return 0
        fi
        if unit_exists mongodb.service && service_start mongodb; then
            MONGO_SERVICE=mongodb
            return 0
        fi
    fi

    if have_cmd mongod; then
        local cfg="${MONGO_CONFIG:-/etc/mongod.conf}"
        local pidfile="/var/run/mongodb/mongod.pid"
        if [[ -f "$cfg" ]]; then
            install -d -o mongodb -g mongodb -m 0755 /var/run/mongodb /var/log/mongodb 2>/dev/null || true
            if ! pgrep -x mongod >/dev/null 2>&1; then
                log "MongoDB: starting mongod without systemd."
                run_as mongodb mongod --config "$cfg" --fork --pidfilepath "$pidfile" || true
            fi
            sleep 2
            pgrep -x mongod >/dev/null 2>&1 && return 0
        fi
    fi

    die "MongoDB could not be started (no working systemd unit or mongod direct-start configuration)."
}

restore_mongo() {
    [[ "$RESTORE_MONGO" == 1 ]] || return 0
    [[ -f "$TREE/MONGODB/mongodb.archive.gz" ]] || {
        warn "MongoDB backup not present."
        return
    }

    log "[7/11] Restoring MongoDB"

    need_cmd mongorestore

    start_mongo

    local stage="$RESTORE_ROOT/stage/mongodb"
    rm -rf "$stage"
    safe_mkdir "$stage" 0700

    cp --preserve=mode,timestamps \
        "$TREE/MONGODB/mongodb.archive.gz" \
        "$stage/mongodb.archive.gz"

    chmod 600 "$stage/mongodb.archive.gz"

    local uri="${MONGO_URI:-mongodb://127.0.0.1:27017}"

    if [[ -t 0 && -z "${MONGO_URI:-}" ]]; then
        read -r -p "MongoDB URI [${uri}]: " answer
        uri="${answer:-$uri}"
    fi

    log "MongoDB: restoring archive."

    mongorestore \
        --uri="$uri" \
        --archive="$stage/mongodb.archive.gz" \
        --gzip \
        --drop \
        --stopOnError ||
        die "MongoDB restore failed."

    # Connectivity verification.
    if have_cmd mongosh; then
        mongosh "$uri" --quiet --eval 'db.adminCommand({ping:1}).ok' |
            grep -qx '1' ||
            die "MongoDB ping verification failed."
    fi

    log "MongoDB restore completed."
}

# ---------------------------------------------------------------------------
# Microsoft SQL Server
# ---------------------------------------------------------------------------

mssql_ident() {
    local s="$1"
    printf '%s' "${s//]/]]}"
}

mssql_lit() {
    local s="$1"
    printf '%s' "${s//\'/\'\'}"
}

mssql_password_valid() {
    local p="$1"
    local n=0
    (( ${#p} >= 8 && ${#p} <= 128 )) || return 1
    [[ "$p" =~ [A-Z] ]] && n=$((n+1))
    [[ "$p" =~ [a-z] ]] && n=$((n+1))
    [[ "$p" =~ [0-9] ]] && n=$((n+1))
    [[ "$p" =~ [^A-Za-z0-9] ]] && n=$((n+1))
    (( n >= 3 ))
}

get_mssql_password() {
    if [[ -n "${MSSQL_PASSWORD:-}" ]]; then
        mssql_password_valid "$MSSQL_PASSWORD" ||
            die "MSSQL_PASSWORD does not satisfy SQL Server password policy."
        return
    fi

    [[ -t 0 ]] || die "MSSQL_PASSWORD is required in non-interactive mode."

    local p1 p2
    while true; do
        read -r -s -p "MSSQL password: " p1
        echo
        read -r -s -p "Confirm MSSQL password: " p2
        echo

        [[ "$p1" == "$p2" ]] || {
            warn "Passwords do not match."
            continue
        }

        mssql_password_valid "$p1" || {
            warn "Password must be 8-128 chars and contain 3 of uppercase/lowercase/number/symbol."
            continue
        }

        MSSQL_PASSWORD="$p1"
        unset p1 p2
        return
    done
}

mssql_setup_if_needed() {
    [[ -x /opt/mssql/bin/mssql-conf ]] ||
        die "mssql-conf is unavailable."

    local conf="/var/opt/mssql/mssql.conf"

    if [[ -f "$conf" ]] &&
       grep -qiE '^[[:space:]]*accepteula[[:space:]]*=[[:space:]]*[Yy]' "$conf"; then
        return
    fi

    log "MSSQL: first-time setup required."

    get_mssql_password

    local pid="${MSSQL_PID:-Developer}"

    ACCEPT_EULA=Y \
    MSSQL_PID="$pid" \
    MSSQL_SA_PASSWORD="$MSSQL_PASSWORD" \
        /opt/mssql/bin/mssql-conf -n setup ||
        die "MSSQL first-time setup failed."

    if systemd_usable; then
        systemctl enable mssql-server >/dev/null 2>&1 || true
        systemctl restart mssql-server || die "MSSQL service failed after setup."
    else
        log "MSSQL: systemd unavailable; starting sqlservr directly."
        if ! pgrep -f '/opt/mssql/bin/sqlservr' >/dev/null 2>&1; then
            runuser -u mssql -- /opt/mssql/bin/sqlservr >/var/opt/mssql/sqlservr.restore.log 2>&1 &
            sleep 8
        fi
        pgrep -f '/opt/mssql/bin/sqlservr' >/dev/null 2>&1 ||
            die "MSSQL sqlservr process failed to start."
    fi
}

mssql_sqlcmd() {
    SQLCMDPASSWORD="$MSSQL_PASSWORD" \
        sqlcmd -S "$MSSQL_SERVER" -C -b -U "$MSSQL_USER" "$@"
}

restore_mssql() {
    [[ "$RESTORE_MSSQL" == 1 ]] || return 0
    [[ -d "$TREE/MSSQL/bak" ]] || {
        warn "MSSQL backup not present."
        return
    }

    log "[8/11] Restoring Microsoft SQL Server"

    need_cmd sqlcmd
    mssql_setup_if_needed

    local MSSQL_SERVER="${MSSQL_SERVER:-127.0.0.1,1433}"
    local MSSQL_USER="${MSSQL_USER:-sa}"

    get_mssql_password

    if systemd_usable; then
        service_start mssql-server || die "MSSQL service failed to start."
    elif ! pgrep -f '/opt/mssql/bin/sqlservr' >/dev/null 2>&1; then
        runuser -u mssql -- /opt/mssql/bin/sqlservr >/var/opt/mssql/sqlservr.restore.log 2>&1 &
        sleep 8
    fi

    local stage="/var/opt/mssql/restore-staging"
    safe_mkdir "$stage" 0750
    chown mssql:mssql "$stage"
    chmod 750 "$stage"

    local backup_dir="/var/opt/mssql/backup"
    safe_mkdir "$backup_dir" 0750
    chown mssql:mssql "$backup_dir"
    chmod 750 "$backup_dir"

    local -a baks=()
    shopt -s nullglob
    baks=( "$TREE/MSSQL/bak/"*.bak )
    shopt -u nullglob

    ((${#baks[@]} > 0)) ||
        die "MSSQL selected but no .bak files were found."

    local bak db staged filelist
    local -i i=0

    for bak in "${baks[@]}"; do
        i=$((i + 1))
        verify_file "$bak"

        db="$(basename "$bak" .bak)"
        staged="$backup_dir/$(basename "$bak")"

        log "MSSQL [$i/${#baks[@]}]: staging $db.bak"

        install -o mssql -g mssql -m 0600 \
            "$bak" "$staged"

        local qpath
        qpath="$(mssql_lit "$staged")"

        log "MSSQL [$i/${#baks[@]}]: VERIFYONLY"

        mssql_sqlcmd -Q \
            "RESTORE VERIFYONLY FROM DISK=N'$qpath';" ||
            die "MSSQL backup verification failed: $db"

        filelist="$stage/${db}.filelist.txt"

        mssql_sqlcmd -h -1 -W -s '|' -Q \
            "RESTORE FILELISTONLY FROM DISK=N'$qpath';" \
            > "$filelist" ||
            die "Could not read MSSQL file list: $db"

        local moves=""
        local data_seen=0
        local log_seen=0
        local logical physical type rest safe target

        while IFS='|' read -r logical physical type rest; do
            logical="${logical#"${logical%%[![:space:]]*}"}"
            logical="${logical%"${logical##*[![:space:]]}"}"
            type="${type#"${type%%[![:space:]]*}"}"
            type="${type%"${type##*[![:space:]]}"}"

            [[ -n "$logical" ]] || continue

            safe="$(printf '%s' "$logical" | tr -cd '[:alnum:]_-')"
            [[ -n "$safe" ]] || safe="file"

            case "$type" in
                D)
                    target="/var/opt/mssql/data/${db}_${safe}.mdf"
                    data_seen=1
                    ;;
                L)
                    target="/var/opt/mssql/data/${db}_${safe}_log.ldf"
                    log_seen=1
                    ;;
                *)
                    target="/var/opt/mssql/data/${db}_${safe}.ndf"
                    ;;
            esac

            moves+="MOVE N'$(mssql_lit "$logical")' TO N'$(mssql_lit "$target")',"
        done < "$filelist"

        [[ "$data_seen" -eq 1 ]] ||
            die "MSSQL backup has no data file: $db"
        [[ "$log_seen" -eq 1 ]] ||
            die "MSSQL backup has no log file: $db"

        moves="${moves%,}"

        local qdb
        qdb="$(mssql_ident "$db")"

        log "MSSQL [$i/${#baks[@]}]: restoring $db"

        mssql_sqlcmd -Q "
IF DB_ID(N'$(mssql_lit "$db")') IS NOT NULL
BEGIN
    ALTER DATABASE [$qdb] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
END;

RESTORE DATABASE [$qdb]
FROM DISK=N'$qpath'
WITH REPLACE, RECOVERY,
$moves,
STATS=5;

ALTER DATABASE [$qdb] SET MULTI_USER;
" || {
            mssql_sqlcmd -Q \
                "IF DB_ID(N'$(mssql_lit "$db")') IS NOT NULL
                 ALTER DATABASE [$qdb] SET MULTI_USER;" >/dev/null 2>&1 || true
            die "MSSQL restore failed: $db"
        }

        # Verify database exists and is online.
        mssql_sqlcmd -h -1 -W -Q \
            "SELECT state_desc FROM sys.databases WHERE name=N'$(mssql_lit "$db")';" |
            grep -qx 'ONLINE' ||
            die "MSSQL verification failed: database $db is not ONLINE."

        log "MSSQL [$i/${#baks[@]}]: OK"
    done

    unset MSSQL_PASSWORD
    log "MSSQL restore completed."
}

# ---------------------------------------------------------------------------
# Docker
# ---------------------------------------------------------------------------

restore_docker() {
    [[ "$RESTORE_DOCKER" == 1 ]] || return 0
    [[ -d "$TREE/DOCKER/volumes" ]] || {
        warn "Docker volume backup not present."
        return 0
    }

    log "[9/11] Restoring Docker volumes"

    resolve_docker_cli
    if [[ -z "$DOCKER_CMD" ]]; then
        if (( IN_CONTAINER )); then
            warn "Docker CLI is unavailable inside this container; Docker volume restore skipped."
            return 0
        fi
        die "Docker command not available."
    fi

    if (( IN_CONTAINER == 1 && DOCKER_SOCKET_AVAILABLE == 0 )); then
        warn "Docker container detected but no Docker socket is mounted."
        warn "Docker volume restore skipped. Mount /var/run/docker.sock to restore host Docker volumes."
        return 0
    fi

    if (( DOCKER_SOCKET_AVAILABLE == 0 )); then
        if systemd_usable; then
            service_start docker || die "Docker service could not be started."
        elif have_cmd dockerd; then
            die "Docker daemon is not running and systemd is unavailable. Start dockerd externally or mount docker.sock."
        else
            die "Docker daemon is unavailable."
        fi
    else
        log "Using mounted Docker socket; Docker daemon belongs to the host."
    fi

    "$DOCKER_CMD" info >/dev/null 2>&1 || die "Docker daemon is not reachable."

    local archive vol mountpoint
    while IFS= read -r -d '' archive; do
        vol="$(basename "$archive" .tar.gz)"
        [[ "$vol" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || die "Unsafe Docker volume name: $vol"

        "$DOCKER_CMD" volume inspect "$vol" >/dev/null 2>&1 ||
            "$DOCKER_CMD" volume create "$vol" >/dev/null

        mountpoint="$("$DOCKER_CMD" volume inspect --format '{{.Mountpoint}}' "$vol")"
        [[ -n "$mountpoint" && -d "$mountpoint" ]] ||
            die "Docker volume mountpoint unavailable: $vol"

        log "Docker: restoring volume $vol"

        # Extract into a sibling temporary directory first. This avoids leaving
        # a half-restored volume when tar extraction fails.
        local tmp="${mountpoint}.restore-$$"
        rm -rf -- "$tmp"
        install -d -m 0700 "$tmp"
        tar --acls --xattrs --numeric-owner --no-same-owner \
            -xzf "$archive" -C "$tmp" || {
                rm -rf -- "$tmp"
                die "Docker volume restore failed during extraction: $vol"
            }

        find "$mountpoint" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
        find "$tmp" -mindepth 1 -maxdepth 1 -exec mv -- {} "$mountpoint"/ \;
        rm -rf -- "$tmp"
    done < <(find "$TREE/DOCKER/volumes" -type f -name '*.tar.gz' -print0)

    log "Docker volumes restored."
}

restore_firewall() {
    [[ "$RESTORE_FIREWALL" == 1 ]] || return 0

    log "[10/11] Restoring firewall"

    if [[ -d "$TREE/FIREWALL/etc-ufw" ]] && have_cmd ufw; then
        local old="/etc/ufw.before-restore-$(date +%Y%m%d_%H%M%S)"
        [[ -d /etc/ufw ]] && mv /etc/ufw "$old"

        restore_copy "$TREE/FIREWALL/etc-ufw" /etc/ufw
        chown -R root:root /etc/ufw
        ufw --force enable ||
            die "UFW restore failed."
    elif [[ -f "$TREE/FIREWALL/nftables-ruleset.txt" ]] && have_cmd nft; then
        nft -c -f "$TREE/FIREWALL/nftables-ruleset.txt" ||
            die "nftables validation failed."
        nft -f "$TREE/FIREWALL/nftables-ruleset.txt" ||
            die "nftables restore failed."
    elif [[ -f "$TREE/FIREWALL/iptables.rules" ]] &&
         have_cmd iptables-restore; then
        iptables-restore < "$TREE/FIREWALL/iptables.rules" ||
            die "iptables restore failed."
    else
        warn "No usable firewall backup/method found."
    fi
}

restore_ssh() {
    [[ "$RESTORE_SSH" == 1 ]] || return 0
    [[ -d "$TREE/SSH/etc-ssh" ]] || {
        warn "SSH backup not present."
        return
    }

    log "[11/11] Restoring SSH"

    local old="/etc/ssh.before-restore-$(date +%Y%m%d_%H%M%S)"

    cp -a /etc/ssh "$old"
    restore_copy "$TREE/SSH/etc-ssh" /etc/ssh
    chown -R root:root /etc/ssh
    chmod 755 /etc/ssh

    if sshd -t; then
        if systemd_usable; then
            systemctl reload ssh 2>/dev/null ||
                systemctl reload sshd 2>/dev/null ||
                warn "SSH configuration valid but reload failed."
        else
            warn "SSH configuration is valid; service reload skipped because systemd is unavailable."
        fi
    else
        log "SSH validation failed. Rolling back."
        rm -rf /etc/ssh
        mv "$old" /etc/ssh
        sshd -t || true
        if systemd_usable; then
            systemctl reload ssh 2>/dev/null ||
                systemctl reload sshd 2>/dev/null || true
        fi
        die "SSH restore failed; previous SSH configuration restored."
    fi
}

# ---------------------------------------------------------------------------
# Final verification
# ---------------------------------------------------------------------------

final_verify() {
    log "Running final service verification."

    if [[ "$RESTORE_NGINX" == 1 ]] && have_cmd nginx; then
        nginx -t || die "Final Nginx verification failed."
        if systemd_usable; then
            systemctl is-active --quiet nginx || die "Final Nginx service verification failed."
        else
            pgrep -x nginx >/dev/null 2>&1 || warn "Nginx configuration is valid but nginx process is not running (no systemd)."
        fi
    fi

    if [[ "$RESTORE_POSTGRES" == 1 ]]; then
        run_as postgres psql -Atqc "SELECT version();" >/dev/null ||
            die "Final PostgreSQL query verification failed."
    fi

    if [[ "$RESTORE_MONGO" == 1 ]]; then
        local uri="${MONGO_URI:-mongodb://127.0.0.1:27017}"
        if have_cmd mongosh; then
            mongosh "$uri" --quiet --eval 'db.adminCommand({ping:1}).ok' |
                grep -qx '1' || die "Final MongoDB ping verification failed."
        elif ! pgrep -x mongod >/dev/null 2>&1 && ! systemd_usable; then
            warn "MongoDB client verification unavailable."
        fi
    fi

    if [[ "$RESTORE_MSSQL" == 1 ]]; then
        if systemd_usable; then
            systemctl is-active --quiet mssql-server || die "Final MSSQL service verification failed."
        elif pgrep -f '/opt/mssql/bin/sqlservr' >/dev/null 2>&1; then
            log "MSSQL process verification: OK"
        else
            warn "MSSQL service verification skipped because systemd is unavailable."
        fi
    fi

    if [[ "$RESTORE_DOCKER" == 1 && -n "$DOCKER_CMD" ]]; then
        if "$DOCKER_CMD" info >/dev/null 2>&1; then
            log "Docker daemon verification: OK"
        else
            warn "Docker daemon is not reachable during final verification."
        fi
    fi

    log "Final verification: OK."
}

cleanup() {
    local rc=$?

    if [[ "$CLEANUP_DONE" == 1 ]]; then
        return
    fi
    CLEANUP_DONE=1

    apt_restore_sources || true

    if [[ "$KEEP_STAGING" != "1" && -n "$RESTORE_ROOT" && -d "$RESTORE_ROOT" ]]; then
        rm -rf "$RESTORE_ROOT" || true
    fi

    # PostgreSQL staging lives outside RESTORE_ROOT so the postgres service
    # account can traverse it.
    if [[ "$KEEP_STAGING" != "1" && -n "$PG_STAGE" && -d "$PG_STAGE" ]]; then
        rm -rf -- "$PG_STAGE" || true
    fi

    if [[ "$DEBUG" == "1" ]]; then
        exec 19>&- 2>/dev/null || true
    fi

    return "$rc"
}

trap cleanup EXIT
trap 'log "Restore interrupted."; exit 130' INT TERM

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    require_root

    [[ -n "$ARCHIVE" ]] ||
        die "Usage: $0 /path/to/server-backup.tar.gz"

    if [[ ! -f "$ARCHIVE" ]]; then
        local requested_name="$(basename -- "$ARCHIVE")"
        local candidate=""
        for dir in             /home/ubuntu/server-backups             /home/Admin/server-backups             /backup             /backups             /mnt/backup             /mnt/backups; do
            if [[ -f "$dir/$requested_name" ]]; then
                candidate="$dir/$requested_name"
                break
            fi
        done

        if [[ -n "$candidate" ]]; then
            log "Backup path was not found at '$ARCHIVE'."
            log "Found same archive by filename at: $candidate"
            ARCHIVE="$candidate"
        else
            die "Backup archive does not exist: $ARCHIVE"
        fi
    fi

    [[ -r "$ARCHIVE" ]] ||
        die "Backup archive is not readable: $ARCHIVE"

    ARCHIVE="$(realpath -e "$ARCHIVE")"

    init_logging

    log "============================================================"
    log "SERVER DISASTER RECOVERY RESTORE v$VERSION"
    log "============================================================"
    detect_os
    detect_container
    resolve_docker_cli

    log "Archive: $ARCHIVE"
    log "Workspace: $RESTORE_ROOT"
    log "Log: $LOG_FILE"
    [[ "$DEBUG" == "1" ]] && log "Trace: $TRACE_FILE"
    log "Execution environment: $([[ "$IN_CONTAINER" == 1 ]] && printf 'container' || printf 'host')"
    log "systemd available: $SYSTEMD_AVAILABLE"
    log "Docker socket available: $DOCKER_SOCKET_AVAILABLE"
    extract_archive
    show_backup_layout
    choose_restore_components
    validate_selected_backup

    if [[ "$PLAN_ONLY" == "1" ]]; then
        log "PLAN_ONLY=1: archive and backup layout validated; no system changes will be made."
        exit 0
    fi

    # Installation happens AFTER archive validation.
    install_selected_packages

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

    final_verify

    log "============================================================"
    log "RESTORE COMPLETED SUCCESSFULLY"
    log "============================================================"
    log "Workspace: $RESTORE_ROOT"
    log "Log: $LOG_FILE"
    [[ "$DEBUG" == "1" ]] && log "Trace: $TRACE_FILE"
    log "Warnings: $WARNINGS"
    log "Previous live configuration backups were retained where applicable."
}

main "$@"
