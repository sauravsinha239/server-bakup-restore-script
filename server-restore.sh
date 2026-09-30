#!/usr/bin/env bash
# Server Disaster Recovery Restore
# Version: 4.3.0
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
# 4.2.2 fixes:
#   - PostgreSQL pg_lsclusters parsing now handles all columns correctly.
#   - PostgreSQL uses pg_ctlcluster --skip-systemctl-redirect in containers.
#   - Microsoft APT sources are disabled outside sources.list.d (no APT warnings).
#   - MSSQL tools use Microsoft's packages-microsoft-prod.deb bootstrap.
#   - MSSQL waits for SQL Server readiness before RESTORE.
#   - MongoDB direct-start waits for a real ping before restore.
#   - SHA verification is independent of stale filenames inside .sha256 files.
#   - Nginx 1.24.x keeps legacy listen ... http2 syntax.
#   - Interactive component selection remains enabled.
#   - PostgreSQL recovery is pinned to the native postgres superuser; the
#     script verifies existence, LOGIN, and SUPERUSER after globals restore.
#   - MSSQL recovery is pinned to the native sa login; the script verifies
#     ENABLED + sysadmin and assigns restored databases to sa.
#   - MSSQL .bak files are VERIFYONLY checked and restored with FILELISTONLY
#     MOVE clauses, WITH REPLACE, RECOVERY, and ONLINE verification.
#   - PostgreSQL recovery role postgres is explicitly re-enabled after globals restore.
#   - MSSQL recovery login sa is explicitly enabled after authentication.
#   - Fresh MSSQL setup always establishes a new recovery password for sa.
#
# IMPORTANT:
#   - Run as root.
#   - Database restores are destructive for databases with the same name.
#   - The backup tree is NEVER recursively chowned.
#   - Firewall and SSH restoration are OFF by default.
#
# Usage:
#   sudo ./server-restore-production-4.2.0.sh /path/to/backup.tar.gz
#   Docker container:
#   docker run --rm -it -v /path/to/backups:/backup:ro \
#       -v /var/run/docker.sock:/var/run/docker.sock \
#       ubuntu:24.04
#   ./server-restore-production-4.2.0.sh \
#       /backup/server-backup-YYYY-MM-DD_HHMMSS.tar.gz
#
# Debug:
#   sudo DEBUG=1 ./server-restore-production-4.2.0.sh /path/to/backup.tar.gz
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

VERSION="4.3.0"
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
APT_CURRENT_BACKUP=""
APT_BACKUP_RESTORED=0
RESTORE_SUCCESS=0
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

backup_current_apt_state() {
    [[ "$PACKAGE_MANAGER" == "apt" ]] || return 0
    local stamp="/var/lib/server-restore/apt-current-backup/$(date +%Y%m%d_%H%M%S)-$$"
    APT_CURRENT_BACKUP="$stamp"
    safe_mkdir "$stamp" 0700
    log "STEP 1: Backing up CURRENT new-server APT sources/keys: $stamp"
    [[ ! -e /etc/apt/sources.list ]] || cp -a /etc/apt/sources.list "$stamp/sources.list"
    [[ ! -d /etc/apt/sources.list.d ]] || cp -a /etc/apt/sources.list.d "$stamp/sources.list.d"
    [[ ! -d /etc/apt/keyrings ]] || cp -a /etc/apt/keyrings "$stamp/keyrings"
    [[ ! -d /usr/share/keyrings ]] || cp -a /usr/share/keyrings "$stamp/usr-share-keyrings"
    [[ ! -d /etc/apt/trusted.gpg.d ]] || cp -a /etc/apt/trusted.gpg.d "$stamp/trusted.gpg.d"
    [[ ! -f /etc/apt/trusted.gpg ]] || cp -a /etc/apt/trusted.gpg "$stamp/trusted.gpg"
    [[ ! -d /etc/apt/preferences.d ]] || cp -a /etc/apt/preferences.d "$stamp/preferences.d"
    [[ ! -f /etc/apt/auth.conf ]] || cp -a /etc/apt/auth.conf "$stamp/auth.conf"
    [[ ! -d /etc/apt/auth.conf.d ]] || cp -a /etc/apt/auth.conf.d "$stamp/auth.conf.d"
    chmod -R go-rwx "$stamp" 2>/dev/null || true
    log "Current APT rollback backup created: $APT_CURRENT_BACKUP"
}

restore_current_apt_state() {
    [[ "$PACKAGE_MANAGER" == "apt" ]] || return 0
    [[ -n "$APT_CURRENT_BACKUP" && -d "$APT_CURRENT_BACKUP" ]] || return 0
    log "Rolling back CURRENT new-server APT state from: $APT_CURRENT_BACKUP"
    rm -rf /etc/apt/sources.list.d /etc/apt/keyrings /usr/share/keyrings /etc/apt/trusted.gpg.d /etc/apt/preferences.d /etc/apt/auth.conf.d
    rm -f /etc/apt/sources.list /etc/apt/trusted.gpg /etc/apt/auth.conf
    [[ ! -e "$APT_CURRENT_BACKUP/sources.list" ]] || cp -a "$APT_CURRENT_BACKUP/sources.list" /etc/apt/sources.list
    [[ ! -d "$APT_CURRENT_BACKUP/sources.list.d" ]] || cp -a "$APT_CURRENT_BACKUP/sources.list.d" /etc/apt/
    [[ ! -d "$APT_CURRENT_BACKUP/keyrings" ]] || cp -a "$APT_CURRENT_BACKUP/keyrings" /etc/apt/
    [[ ! -d "$APT_CURRENT_BACKUP/usr-share-keyrings" ]] || cp -a "$APT_CURRENT_BACKUP/usr-share-keyrings" /usr/share/
    [[ ! -d "$APT_CURRENT_BACKUP/trusted.gpg.d" ]] || cp -a "$APT_CURRENT_BACKUP/trusted.gpg.d" /etc/apt/
    [[ ! -f "$APT_CURRENT_BACKUP/trusted.gpg" ]] || cp -a "$APT_CURRENT_BACKUP/trusted.gpg" /etc/apt/trusted.gpg
    [[ ! -d "$APT_CURRENT_BACKUP/preferences.d" ]] || cp -a "$APT_CURRENT_BACKUP/preferences.d" /etc/apt/
    [[ ! -f "$APT_CURRENT_BACKUP/auth.conf" ]] || cp -a "$APT_CURRENT_BACKUP/auth.conf" /etc/apt/auth.conf
    [[ ! -d "$APT_CURRENT_BACKUP/auth.conf.d" ]] || cp -a "$APT_CURRENT_BACKUP/auth.conf.d" /etc/apt/
    chmod 600 /etc/apt/auth.conf 2>/dev/null || true
    chmod -R go-rwx /etc/apt/auth.conf.d 2>/dev/null || true
    log "Current APT state restored."
}

validate_backup_apt_os() {
    [[ "$PACKAGE_MANAGER" == "apt" ]] || return 0
    local meta="$TREE/METADATA/tool-versions.env"
    [[ -f "$meta" ]] || die "Missing backup metadata: $meta"
    local backup_id backup_version
    backup_id="$(sed -n 's/^OS_ID=//p' "$meta" | head -n1 | tr -d "'\"")"
    backup_version="$(sed -n 's/^OS_VERSION=//p' "$meta" | head -n1 | tr -d "'\"")"
    [[ -z "$backup_id" || "$backup_id" == "$OS_ID" ]] || die "OS mismatch: backup=$backup_id current=$OS_ID. Refusing old APT repositories."
    if [[ -n "$backup_version" && "$backup_version" != "$OS_VERSION" && "${ALLOW_OS_MISMATCH:-0}" != "1" ]]; then
        die "OS version mismatch: backup=$backup_version current=$OS_VERSION. Set ALLOW_OS_MISMATCH=1 only if intentional."
    fi
}

restore_pgdg_official_key() {
    log "Restoring official PostgreSQL PGDG signing key..."

    local pgdg_dir="/usr/share/postgresql-common/pgdg"
    local pgdg_key="${pgdg_dir}/apt.postgresql.org.asc"
    local pgdg_key_url="https://www.postgresql.org/media/keys/ACCC4CF8.asc"

    install -d -m 0755 "$pgdg_dir"

    if ! command -v curl >/dev/null 2>&1; then
        log "curl is not installed. Installing curl..."

        apt-get install -y curl

    if ! command -v curl >/dev/null 2>&1; then
        die "Failed to install curl"
    fi

        log "curl installed successfully."
    fi
    curl -fsSL "$pgdg_key_url" -o "$pgdg_key"

    chmod 0644 "$pgdg_key"

    if ! gpg --show-keys --with-fingerprint "$pgdg_key" 2>/dev/null \
        | grep -q "7FCC 7D46 ACCC 4CF8"; then
        rm -f "$pgdg_key"
        die "Downloaded PostgreSQL PGDG signing key fingerprint verification failed"
    fi

    log "Official PostgreSQL PGDG signing key installed and verified."
}

restore_backup_apt_sources() {

    [[ "$PACKAGE_MANAGER" == "apt" ]] || return 0

    local src="$TREE/APT"

    [[ -d "$src" ]] || die "Backup has no APT repository/key metadata: $src"

    validate_backup_apt_os

    log "STEP 2: Restoring OLD server APT sources and signing keys."

    # ------------------------------------------------------------
    # 1. Backup CURRENT new-server APT state for rollback
    # ------------------------------------------------------------
    backup_current_apt_state

    # ------------------------------------------------------------
    # 2. Remove CURRENT new-server APT sources and keyrings
    # ------------------------------------------------------------
    rm -rf \
        /etc/apt/sources.list.d \
        /etc/apt/keyrings \
        /usr/share/keyrings \
        /usr/share/postgresql-common/pgdg \
        /etc/apt/trusted.gpg.d \
        /etc/apt/preferences.d

    rm -f \
        /etc/apt/sources.list \
        /etc/apt/trusted.gpg

    # ------------------------------------------------------------
    # 3. Re-create APT directories
    # ------------------------------------------------------------
    mkdir -p \
        /etc/apt/sources.list.d \
        /etc/apt/keyrings \
        /usr/share/keyrings \
        /usr/share/postgresql-common/pgdg \
        /etc/apt/trusted.gpg.d \
        /etc/apt/preferences.d

    # ------------------------------------------------------------
    # 4. Restore OLD server sources.list
    # ------------------------------------------------------------
    if [[ -f "$src/sources.list" ]]; then
        cp -a "$src/sources.list" /etc/apt/sources.list
    fi

    # ------------------------------------------------------------
    # 5. Restore OLD server sources.list.d
    # ------------------------------------------------------------
    if [[ -d "$src/sources.list.d" ]]; then
        cp -a "$src/sources.list.d/." /etc/apt/sources.list.d/
    fi

    # ------------------------------------------------------------
    # 6. Restore OLD server APT keyrings
    #
    # Backup keyrings are copied to BOTH locations because
    # different repository configurations may use either path.
    # ------------------------------------------------------------
    if [[ -d "$src/keyrings" ]]; then
        cp -a "$src/keyrings/." /usr/share/keyrings/
        cp -a "$src/keyrings/." /etc/apt/keyrings/
    fi

    # ------------------------------------------------------------
    # 7. Restore OLD PostgreSQL PGDG key
    # ------------------------------------------------------------
    if [[ -d "$src/postgresql-common-pgdg" ]]; then
        cp -a \
            "$src/postgresql-common-pgdg/." \
            /usr/share/postgresql-common/pgdg/
    fi

    # ------------------------------------------------------------
    # 8. Restore OLD trusted.gpg.d
    # ------------------------------------------------------------
    if [[ -d "$src/trusted.gpg.d" ]]; then
        cp -a \
            "$src/trusted.gpg.d/." \
            /etc/apt/trusted.gpg.d/
    fi

    # ------------------------------------------------------------
    # 9. Restore OLD trusted.gpg
    # ------------------------------------------------------------
    if [[ -f "$src/trusted.gpg" ]]; then
        cp -a \
            "$src/trusted.gpg" \
            /etc/apt/trusted.gpg
    fi

    # ------------------------------------------------------------
    # 10. Restore OLD APT preferences
    # ------------------------------------------------------------
    if [[ -d "$src/preferences.d" ]]; then
        cp -a \
            "$src/preferences.d/." \
            /etc/apt/preferences.d/
    fi

    # ------------------------------------------------------------
    # 11. Fix permissions
    # ------------------------------------------------------------
    chmod 0644 /etc/apt/sources.list 2>/dev/null || true

    find \
        /etc/apt/sources.list.d \
        /etc/apt/keyrings \
        /usr/share/keyrings \
        /usr/share/postgresql-common/pgdg \
        /etc/apt/trusted.gpg.d \
        /etc/apt/preferences.d \
        -type f \
        -exec chmod 0644 {} + \
        2>/dev/null || true

    # ------------------------------------------------------------
    # 12. Make sure official PGDG key exists.
    #
    # If the backup contains the key, use the backup key.
    # If it does not, download the official PostgreSQL key.
    # ------------------------------------------------------------
    if [[ ! -s "/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc" ]]; then

        log "PGDG signing key not present in backup."
        log "Downloading official PostgreSQL PGDG signing key."

        if ! command -v curl >/dev/null 2>&1; then
            log "curl is not installed. Installing curl."

            apt-get install -y curl || \
                die "Failed to install curl."

            command -v curl >/dev/null 2>&1 || \
                die "curl installation failed."
        fi

        curl -fsSL \
            "https://www.postgresql.org/media/keys/ACCC4CF8.asc" \
            -o "/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc" || \
            die "Failed to download official PostgreSQL PGDG signing key."

        chmod 0644 \
            "/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc"

    fi

    # ------------------------------------------------------------
    # 13. Verify PGDG key fingerprint
    # ------------------------------------------------------------
    if [[ -s "/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc" ]]; then

        if ! gpg --show-keys --with-fingerprint \
            "/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc" \
            2>/dev/null | grep -q "7FCC 7D46 ACCC 4CF8"; then

            die "PostgreSQL PGDG signing key fingerprint verification failed."
        fi

        log "PostgreSQL PGDG signing key verified: 7FCC 7D46 ACCC 4CF8"

    else
        die "PostgreSQL PGDG signing key is missing."
    fi

    # ------------------------------------------------------------
    # 14. Update package lists using OLD repositories
    # ------------------------------------------------------------
    log "STEP 3: apt-get update using OLD server repositories."

    apt-get update

    # ------------------------------------------------------------
    # 15. Mark OLD APT state as successfully restored
    # ------------------------------------------------------------
    APT_BACKUP_RESTORED=1

    log "Old APT repositories and signing keys are now active."
}

apt_restore_sources() {
    [[ "$PACKAGE_MANAGER" == "apt" ]] || return 0
    if [[ "$RESTORE_SUCCESS" != 1 && -n "$APT_CURRENT_BACKUP" && -d "$APT_CURRENT_BACKUP" ]]; then
        restore_current_apt_state || true
        apt-get update >/dev/null 2>&1 || true
    fi
}

# ---------------------------------------------------------------------------
# Package installation
# ---------------------------------------------------------------------------
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

    # Microsoft currently documents the packages-microsoft-prod.deb bootstrap
    # for mssql-tools18 on Ubuntu 24.04. Use it instead of leaving a second
    # manually-managed prod.list behind.
    local repo_deb="/var/tmp/packages-microsoft-prod.deb"
    curl -fsSL \
        "https://packages.microsoft.com/config/ubuntu/${OS_VERSION}/packages-microsoft-prod.deb" \
        -o "$repo_deb"
    dpkg -i "$repo_deb" >/dev/null
    rm -f -- "$repo_deb"

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

install_exact_apt_packages() {
    local exact="$TREE/APT/exact-important-packages.txt"
    local legacy="$TREE/PACKAGES/dpkg-packages.txt"
    if [[ ! -f "$exact" ]]; then
        warn "Exact package manifest missing; deriving it from legacy dpkg inventory."
        [[ -f "$legacy" ]] || die "No exact package manifest or legacy dpkg inventory found."
        exact="$RESTORE_ROOT/derived-exact-important-packages.txt"
        awk -F '\t' '$1 ~ /^(postgresql($|-)|postgresql-common$|mssql-|mongodb-|nginx($|-)|crowdsec($|-)|crowdsec-firewall-bouncer|docker(-ce)?($|-)|docker.io$|containerd($|-)|runc$|ca-certificates$|curl$|gnupg$|tar$|gzip$|rsync$|openssl$|openssh-server$|openssh-client$|ufw$|iptables$|nftables$)/ {print}' "$legacy" | sort -u > "$exact"
    fi
    log "STEP 4: Installing EXACT package versions captured from old server."
    local tmp="$RESTORE_ROOT/exact-selected-packages.txt"
    : > "$tmp"
    add_matches() { local regex="$1"; awk -F '\t' -v re="$regex" '$1 ~ re {print $1 "\t" $2}' "$exact" >> "$tmp"; }
    add_matches '^(ca-certificates|curl|gnupg|tar|gzip|rsync|openssl)$'
    [[ "$RESTORE_NGINX" == 1 ]] && add_matches '^nginx($|-)'
    [[ "$RESTORE_POSTGRES" == 1 ]] && add_matches '^postgresql($|-)|^postgresql-common$'
    [[ "$RESTORE_MONGO" == 1 ]] && add_matches '^mongodb-'
    if [[ "$RESTORE_MSSQL" == 1 ]]; then add_matches '^mssql-'; add_matches '^unixodbc($|-)|^libodbc'; fi
    [[ "$RESTORE_CROWDSEC" == 1 ]] && add_matches '^crowdsec($|-)|^crowdsec-firewall-bouncer'
    [[ "$RESTORE_DOCKER" == 1 ]] && add_matches '^docker(-ce)?($|-)|^docker.io$|^containerd($|-)|^runc$'
    [[ "$RESTORE_SSH" == 1 ]] && add_matches '^openssh-server$|^openssh-client$'
    [[ "$RESTORE_FIREWALL" == 1 ]] && add_matches '^(ufw|iptables|nftables)$'
    sort -u "$tmp" -o "$tmp"
    [[ -s "$tmp" ]] || die "No exact package versions were captured for selected components."
    local pkg ver
    while IFS=$'\t' read -r pkg ver; do
        [[ -n "$pkg" && -n "$ver" ]] || continue
        apt-cache policy "$pkg" 2>/dev/null | grep -Fq "$ver" || die "EXACT VERSION UNAVAILABLE: ${pkg}=${ver}. Refusing a different version."
        log "Installing exact: ${pkg}=${ver}"
        apt-get install -y --allow-downgrades "${pkg}=${ver}" || die "Exact installation failed: ${pkg}=${ver}"
    done < "$tmp"
    log "STEP 5: Exact package installation completed."
}

install_selected_packages() {
    log "Installing required restore software..."
    case "$PACKAGE_MANAGER" in
        apt)
            export DEBIAN_FRONTEND=noninteractive
            # REQUIRED ORDER: save current -> restore old repos/keys -> update -> exact install.
            restore_backup_apt_sources
            install_exact_apt_packages
            ;;
        pacman)
            pacman -Sy --noconfirm --needed ca-certificates curl tar gzip rsync
            [[ "$RESTORE_NGINX" == 1 ]] && pacman -S --noconfirm --needed nginx
            [[ "$RESTORE_POSTGRES" == 1 ]] && install_postgres
            [[ "$RESTORE_MONGO" == 1 ]] && install_mongodb
            [[ "$RESTORE_MSSQL" != 1 ]] || die "MSSQL automatic recovery is not supported from Arch."
            if [[ "$RESTORE_DOCKER" == 1 ]]; then
                if (( IN_CONTAINER == 1 && DOCKER_SOCKET_AVAILABLE == 0 )); then warn "Docker socket unavailable."; else pacman -S --noconfirm --needed docker; fi
            fi
            [[ "$RESTORE_SSH" == 1 ]] && pacman -S --noconfirm --needed openssh
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Restore plan helper
# ---------------------------------------------------------------------------
write_restore_plan() {
    local plan="$RESTORE_ROOT/RESTORE-PLAN.txt"
    cat > "$plan" <<'EOF_PLAN'
SERVER DISASTER RECOVERY ORDER
1. Verify archive + SHA-256.
2. Detect current OS/architecture.
3. Validate backup OS matches current OS.
4. Backup CURRENT new-server APT sources, keyrings, trusted keys and preferences.
5. Restore OLD server APT sources/keyrings from the backup.
6. Run apt-get update using OLD repositories.
7. Install EXACT package versions captured on the old server.
8. Verify installed versions.
9. Restore Nginx/CrowdSec/application configuration.
10. Restore PostgreSQL roles and databases.
11. Restore MongoDB configuration/users/data.
12. Restore MSSQL logins and databases.
13. Restore Docker/application data.
14. Final verification.
15. On failure: restore CURRENT new-server APT source/key state.
16. On success: keep OLD APT repositories active for reproducibility.
EOF_PLAN
    log "Restore plan written to: $plan"
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
    # Nginx 1.25.1+ supports the standalone `http2 on;` directive.
    # Older Nginx (including Ubuntu 24.04's common 1.24.x package) uses:
    #     listen 443 ssl http2;
    # Therefore NEVER convert the old syntax on an older Nginx binary.
    local nginx_version major minor patch file tmp

    nginx_version="$(nginx -v 2>&1 | sed -n 's#^nginx version: nginx/##p' | head -n1)"
    [[ -n "$nginx_version" ]] || {
        warn "Could not determine Nginx version; leaving HTTP/2 syntax unchanged."
        return 0
    }

    major="${nginx_version%%.*}"
    local rest="${nginx_version#*.}"
    minor="${rest%%.*}"
    patch="${rest#*.}"
    patch="${patch%%[^0-9]*}"
    patch="${patch:-0}"

    log "Nginx version detected: $nginx_version"

    # Standalone `http2 on;` is supported from 1.25.1.
    if (( major > 1 || (major == 1 && minor > 25) ||
          (major == 1 && minor == 25 && patch >= 1) )); then
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
                log "Nginx: converted deprecated listen ... http2 syntax in $file (Nginx $nginx_version)"
            fi
        done < <(find /etc/nginx -type f -print0 2>/dev/null)
    else
        log "Nginx $nginx_version uses legacy listen ... http2 syntax; leaving it unchanged."
    fi
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
        "SELECT rolname FROM pg_roles;" > "$roles_file" ||
        die "PostgreSQL: could not query existing roles."

    declare -A existing=()
    local role

    while IFS= read -r role; do
        [[ -n "$role" ]] && existing["$role"]=1
    done < "$roles_file"

    : > "$output"

    local line decl role_name
    local create_role_re='^CREATE[[:space:]]+ROLE[[:space:]]+(.+);[[:space:]]*$'

    while IFS= read -r line || [[ -n "$line" ]]; do

    # Protect native PostgreSQL recovery account.
    #
    # Example:
    # ALTER ROLE postgres WITH SUPERUSER INHERIT CREATEROLE CREATEDB NOLOGIN REPLICATION BYPASSRLS;
    #
    # becomes:
    # ALTER ROLE postgres WITH SUPERUSER INHERIT CREATEROLE CREATEDB LOGIN REPLICATION BYPASSRLS;

    if [[ "$line" == ALTER\ ROLE\ postgres* ]] ||
       [[ "$line" == ALTER\ ROLE\ \"postgres\"* ]]; then

        if [[ "$line" == *NOLOGIN* ]]; then
            log "PostgreSQL: protecting native recovery role from NOLOGIN:"
            log "  $line"

            line="${line//NOLOGIN/LOGIN}"

            log "PostgreSQL: protected statement:"
            log "  $line"
        fi
    fi

    # Existing-role handling
    if [[ "$line" =~ $create_role_re ]]; then

        decl="${BASH_REMATCH[1]}"

        if [[ "${decl:0:1}" == '"' ]]; then
            role_name="$(
                printf '%s\n' "$decl" |
                    sed -E 's/^"(([^"]|"")*)".*/\1/'
            )"

            role_name="${role_name//\"\"/\"}"

        else
            role_name="${decl%%[[:space:]]*}"
            role_name="${role_name%;}"
        fi

        if [[ -n "${existing[$role_name]+yes}" ]]; then
            printf -- \
                '-- RESTORE-SKIPPED existing role: %s\n' \
                "$role_name" >> "$output"
        else
            printf '%s\n' "$line" >> "$output"
        fi

    else
        printf '%s\n' "$line" >> "$output"
    fi

done < "$input"

    # ================================================================
    # FINAL SAFETY NET
    # ================================================================
    #
    # Even if pg_dumpall contains an unusual ALTER ROLE postgres statement,
    # the native recovery account must finish with LOGIN + SUPERUSER.
    #
    # This is intentionally ONLY for postgres.
    # ================================================================

    cat >> "$output" <<'SQL'

-- ================================================================
-- RESTORE SAFETY: native PostgreSQL recovery account
-- ================================================================

ALTER ROLE postgres LOGIN;
ALTER ROLE postgres SUPERUSER;

SQL

    chown postgres:postgres "$output"
    chmod 600 "$output"

    [[ -s "$output" ]] ||
        die "Prepared PostgreSQL globals file is empty."

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
    log "PostgreSQL: starting database service/cluster..."

    if systemd_usable && unit_exists postgresql.service; then
        if service_start postgresql; then
            PG_SERVICE="postgresql"
            return 0
        fi
        warn "systemd PostgreSQL start failed; trying cluster-level startup."
    fi

    # Debian/Ubuntu uses pg_lsclusters + pg_ctlcluster. This is the preferred
    # systemd-less/container path. pg_lsclusters columns are:
    # version cluster port status owner datadir logfile
    if have_cmd pg_lsclusters && have_cmd pg_ctlcluster; then
        local version cluster port status owner datadir logfile
        while IFS=" " read -r version cluster port status owner datadir logfile; do
            [[ -n "$version" && -n "$cluster" ]] || continue
            [[ "$version" =~ ^[0-9]+$ ]] || continue

            if [[ "$status" != "online" ]]; then
                log "PostgreSQL: cluster $version/$cluster on port $port is $status; starting..."
                if ! pg_ctlcluster --skip-systemctl-redirect "$version" "$cluster" start; then
                    warn "Could not start PostgreSQL cluster $version/$cluster with pg_ctlcluster."
                    continue
                fi
            fi

            if have_cmd pg_isready && pg_isready -h 127.0.0.1 -p "$port" >/dev/null 2>&1; then
                PG_SERVICE="${version}/${cluster}"
                log "PostgreSQL: cluster $version/$cluster is ready on port $port."
                return 0
            fi

            # pg_ctlcluster status is useful even when pg_isready is unavailable.
            if pg_ctlcluster --skip-systemctl-redirect "$version" "$cluster" status >/dev/null 2>&1; then
                PG_SERVICE="${version}/${cluster}"
                return 0
            fi
        done < <(pg_lsclusters --no-header 2>/dev/null || true)
    fi

    # Generic fallback for installations without Debian cluster tooling.
    if have_cmd pg_ctl; then
        local datadir
        datadir="$(find /var/lib/postgresql -mindepth 2 -maxdepth 3 -type f -name PG_VERSION -printf '%h\n' 2>/dev/null | head -n1 || true)"
        if [[ -n "$datadir" ]]; then
            log "PostgreSQL: starting data directory directly: $datadir"
            run_as postgres pg_ctl -D "$datadir" -w start || true
            if run_as postgres pg_ctl -D "$datadir" status >/dev/null 2>&1; then
                PG_SERVICE="$datadir"
                return 0
            fi
        fi
    fi

    if have_cmd pg_isready && pg_isready -h 127.0.0.1 -p 5432 >/dev/null 2>&1; then
        PG_SERVICE="127.0.0.1:5432"
        return 0
    fi

    die "PostgreSQL could not be started. No usable systemd service, pg_ctlcluster cluster, or pg_ctl data directory was found."
}

pg_enable_recovery_roles() {
    # PostgreSQL recovery ALWAYS uses the native local superuser "postgres".
    # Do not create or enable arbitrary roles from the backup.
    # pg_dumpall globals may contain ALTER ROLE postgres NOLOGIN, so this
    # repair MUST happen after globals.sql is restored.
    local role_state

    log "PostgreSQL: verifying native recovery account 'postgres'..."

    role_state="$(run_as postgres psql -d postgres -Atqc \
        "SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_roles WHERE rolname='postgres') THEN 'EXISTS' ELSE 'MISSING' END;")" ||
        die "PostgreSQL: could not query pg_roles using the local postgres OS account."

    [[ "$role_state" == "EXISTS" ]] ||
        die "PostgreSQL: native recovery role 'postgres' does not exist. Refusing to create a replacement recovery account automatically."

    run_as postgres psql -v ON_ERROR_STOP=1 -d postgres -c \
        'ALTER ROLE postgres LOGIN;' ||
        die "PostgreSQL: could not enable LOGIN for native recovery role 'postgres'."

    role_state="$(run_as postgres psql -d postgres -Atqc \
        "SELECT rolname || '|' || CASE WHEN rolcanlogin THEN 'LOGIN' ELSE 'NOLOGIN' END || '|' || CASE WHEN rolsuper THEN 'SUPERUSER' ELSE 'NOSUPERUSER' END FROM pg_roles WHERE rolname='postgres';")" ||
        die "PostgreSQL: could not verify native recovery role 'postgres'."

    [[ "$role_state" == 'postgres|LOGIN|SUPERUSER' ]] ||
        die "PostgreSQL: native recovery role verification failed: $role_state"

    log "PostgreSQL: recovery account OK: $role_state"
}

restore_postgres() {
    [[ "$RESTORE_POSTGRES" == 1 ]] || return 0
    [[ -d "$TREE/POSTGRES" ]] || {
        warn "PostgreSQL backup not present."
        return
    }

    log "[6/11] Restoring PostgreSQL"

    need_cmd psql

    id postgres >/dev/null 2>&1 ||
    die "PostgreSQL OS user does not exist."

    local PG_RESTORE_BIN

    PG_RESTORE_BIN="$(get_pg_restore_bin)" ||
    die "No usable pg_restore executable found."

   log "PostgreSQL restore tool: $("$PG_RESTORE_BIN" --version)"
        

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

        # pg_dumpall globals can contain ALTER ROLE postgres NOLOGIN.
        # Never allow the backup to lock us out of the fresh recovery server.
        pg_enable_recovery_roles
    else
        # Even without globals.sql, make sure the local recovery account works.
        pg_enable_recovery_roles
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
 # get pg restore version

get_pg_restore_bin() {
    local candidate
    local best=""
    local best_major=0
    local major

    # Prefer the newest installed pg_restore.
    while IFS= read -r candidate; do
        [[ -x "$candidate" ]] || continue

        major="$(
            "$candidate" --version 2>/dev/null |
                sed -n 's/.*PostgreSQL) \([0-9][0-9]*\).*/\1/p'
        )"

        [[ "$major" =~ ^[0-9]+$ ]] || continue

        if (( major > best_major )); then
            best_major="$major"
            best="$candidate"
        fi
    done < <(
        find /usr/lib/postgresql -type f -path '*/bin/pg_restore' \
            2>/dev/null | sort -V
    )

    # Fallback to PATH version.
    if [[ -z "$best" ]] && command -v pg_restore >/dev/null 2>&1; then
        best="$(command -v pg_restore)"
    fi

    [[ -n "$best" ]] || return 1

    printf '%s\n' "$best"
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
        local logpath="/var/log/mongodb/mongod.log"

        if [[ -f "$cfg" ]]; then
            install -d -o mongodb -g mongodb -m 0755 /var/run/mongodb /var/log/mongodb 2>/dev/null || true
            if ! pgrep -x mongod >/dev/null 2>&1; then
                log "MongoDB: starting mongod without systemd."
                run_as mongodb mongod --config "$cfg" --fork --pidfilepath "$pidfile" --logpath "$logpath" || true
            fi
        fi
    fi

    local uri="${MONGO_URI:-mongodb://127.0.0.1:27017}"
    local i
    for i in {1..20}; do
        if have_cmd mongosh; then
            if mongosh "$uri" --quiet --eval 'db.adminCommand({ping:1}).ok' 2>/dev/null | grep -qx '1'; then
                MONGO_SERVICE="mongod"
                log "MongoDB: server is ready."
                return 0
            fi
        elif have_cmd nc; then
            if nc -z 127.0.0.1 27017 >/dev/null 2>&1; then
                MONGO_SERVICE="mongod"
                return 0
            fi
        elif pgrep -x mongod >/dev/null 2>&1; then
            MONGO_SERVICE="mongod"
            return 0
        fi
        sleep 1
    done

    die "MongoDB could not be started or did not become ready on 127.0.0.1:27017."
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

wait_mssql_ready() {
    local hostport="${1:-127.0.0.1,1433}"
    local i
    for i in {1..30}; do
        if have_cmd sqlcmd && SQLCMDPASSWORD="${MSSQL_PASSWORD:-}" sqlcmd -S "$hostport" -C -b -U "${MSSQL_USER:-sa}" -Q 'SELECT 1' >/dev/null 2>&1; then
            log "MSSQL: SQL Server is ready at $hostport."
            return 0
        fi
        sleep 1
    done
    die "MSSQL did not become ready at $hostport."
}

mssql_sqlcmd() {
    SQLCMDPASSWORD="$MSSQL_PASSWORD" \
        sqlcmd -S "$MSSQL_SERVER" -C -b -U "$MSSQL_USER" "$@"
}

mssql_enable_recovery_login() {
    # The built-in sa account is the native SQL Server recovery account.
    # A .bak restores database state, not server-level login state.
    # Therefore [sa] is repaired and verified independently.
    log "MSSQL: verifying native recovery login [sa]..."

    mssql_sqlcmd -Q "
IF NOT EXISTS (
    SELECT 1 FROM sys.server_principals WHERE name = N'sa'
)
    THROW 50001, 'Built-in recovery login [sa] does not exist.', 1;

IF EXISTS (
    SELECT 1 FROM sys.server_principals
    WHERE name = N'sa' AND is_disabled = 1
)
    ALTER LOGIN [sa] ENABLE;

IF IS_SRVROLEMEMBER(N'sysadmin', N'sa') <> 1
    ALTER SERVER ROLE [sysadmin] ADD MEMBER [sa];

SELECT
    name,
    is_disabled,
    IS_SRVROLEMEMBER(N'sysadmin', N'sa') AS is_sysadmin
FROM sys.server_principals
WHERE name = N'sa';
" ||
        die "MSSQL: could not enable/verify [sa]. The supplied login must have sufficient server-level permissions."

    local sa_state
    sa_state="$(mssql_sqlcmd -h -1 -W -s '|' -Q \
        "SELECT CAST(is_disabled AS varchar(10)) + '|' + CAST(IS_SRVROLEMEMBER(N'sysadmin', N'sa') AS varchar(10)) FROM sys.server_principals WHERE name=N'sa';")" ||
        die "MSSQL: could not read [sa] recovery state."

    sa_state="$(printf '%s\n' "$sa_state" | tr -d '\r' | tail -n 1)"

    [[ "$sa_state" == "0|1" ]] ||
        die "MSSQL: native recovery login [sa] verification failed: '$sa_state' (expected 0|1)."

    log "MSSQL: recovery login OK: sa|ENABLED|SYSADMIN"
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

    wait_mssql_ready "$MSSQL_SERVER"

    # Restore/backup files cannot be trusted to leave the server-level recovery
    # login enabled. Fix [sa] before touching any database.
    mssql_enable_recovery_login

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
            tr -d '\r' |
            grep -qx 'ONLINE' ||
            die "MSSQL verification failed: database $db is not ONLINE."

        # sa is sysadmin, so it has full access to every restored database.
        # Make the ownership explicit as well; this also avoids orphaned
        # database-owner state from the source server.
        mssql_sqlcmd -Q \
            "ALTER AUTHORIZATION ON DATABASE::[$qdb] TO [sa];" ||
            die "MSSQL verification failed: could not assign database owner to sa for $db."

        log "MSSQL [$i/${#baks[@]}]: ONLINE + owner=sa + sysadmin access OK"
    done

    # Final safety check: database restores are complete, so verify the
    # server-level recovery account one last time.
    mssql_enable_recovery_login

    unset MSSQL_PASSWORD
    log "MSSQL restore completed. Recovery login [sa] is enabled."
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
    write_restore_plan
    choose_restore_components
    validate_selected_backup

    if [[ "$PLAN_ONLY" == "1" ]]; then
        log "PLAN_ONLY=1: archive and backup layout validated; no system changes will be made."
        exit 0
    fi

    # Installation happens AFTER archive validation.
    # APT order is: save current repos/keys -> restore old repos/keys ->
    # apt-get update -> install exact old package versions.
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

    RESTORE_SUCCESS=1

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
