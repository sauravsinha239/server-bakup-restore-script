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
# - Firewall and SSH restoration are OFF by default in the checkbox menu.
# - Temporary extracted files are retained by default.

SCRIPT_VERSION="2.6.0"
ARCHIVE="${1:-}"

# Normalize the archive path once so every later operation is independent
# of the caller's current working directory.
if [[ -n "$ARCHIVE" && -f "$ARCHIVE" ]]; then
    ARCHIVE="$(realpath "$ARCHIVE")"
fi

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

# Persistent production debug log. Set DEBUG=1 for shell tracing.
DEBUG="${DEBUG:-0}"
LOG_FILE="${LOG_FILE:-/var/log/server-restore.log}"
TRACE_FILE=""

mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/var/tmp/server-restore.log"
chmod 600 "$LOG_FILE" 2>/dev/null || true

if [[ "$DEBUG" == "1" ]]; then
    TRACE_FILE="$RESTORE_ROOT.debug.trace"
fi

# Package policy: selected restore packages are upgraded/installed.
# No full Debian/Ubuntu upgrade is performed automatically.
UPGRADE_SELECTED_PACKAGES=1

# -------------------------------------------------------------------
# Logging / error handling
# -------------------------------------------------------------------

log() {
    local msg
    msg="[$(date '+%F %T')] $*"
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

on_error() {
    local rc=$?
    local line="${BASH_LINENO[0]:-unknown}"
    local cmd="${BASH_COMMAND:-unknown}"
    log "ERROR: command failed rc=$rc line=$line: $cmd"
    log "ERROR: restore workspace: ${RESTORE_ROOT:-unknown}"
    log "ERROR: debug log: $LOG_FILE"
    exit "$rc"
}

trap on_error ERR

cmd() {
    command -v "$1" >/dev/null 2>&1
}

# -------------------------------------------------------------------
# Interactive checkbox menu
# -------------------------------------------------------------------

prompt_yes_no() {
    local question="$1"
    local default="${2:-N}"
    local answer

    # Non-interactive restore: preserve safe default.
    if [[ ! -t 0 ]]; then
        [[ "$default" =~ ^[Yy]$ ]]
        return
    fi

    while true; do
        if [[ "$default" =~ ^[Yy]$ ]]; then
            read -r -p "$question [Y/n]: " answer
            answer="${answer:-Y}"
        else
            read -r -p "$question [y/N]: " answer
            answer="${answer:-N}"
        fi

        case "$answer" in
            [Yy]|[Yy][Ee][Ss]) return 0 ;;
            [Nn]|[Nn][Oo]) return 1 ;;
            *) echo "Please answer yes or no." ;;
        esac
    done
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

menu_checkbox() {
    local title="$1"
    shift
    local -a labels=("$@")
    local -a selected=("${MENU_SELECTED[@]}")
    local cursor=0
    local key seq i mark

    [[ -t 0 && -t 1 ]] || return 0

    while true; do
        printf '\033[2J\033[H'
        printf '\n'
        printf '============================================================\n'
        printf ' %s\n' "$title"
        printf '============================================================\n\n'
        printf '  ↑/↓  Move    SPACE  Select/Deselect    ENTER  Continue    q  Quit\n\n'

        for i in "${!labels[@]}"; do
            if [[ "${selected[$i]}" == 1 ]]; then
                mark='✓'
            else
                mark=' '
            fi

            if ((i == cursor)); then
                printf '\033[7m'
                printf '  [%s] %s\n' "$mark" "${labels[$i]}"
                printf '\033[0m'
            else
                printf '  [%s] %s\n' "$mark" "${labels[$i]}"
            fi
        done

        printf '\n'
        printf '  Selected components will have their required packages\n'
        printf '  installed/upgraded automatically before restore.\n'

        IFS= read -r -s -n 1 key || die "Unable to read terminal input."

        case "$key" in
            $'\x1b')
                IFS= read -r -s -n 2 seq || true
                case "$seq" in
                    '[A') ((cursor > 0)) && cursor=$((cursor - 1)) ;;
                    '[B') ((cursor < ${#labels[@]} - 1)) && cursor=$((cursor + 1)) ;;
                    '[5~') cursor=$((cursor - 5)); ((cursor < 0)) && cursor=0 ;;
                    '[6~') cursor=$((cursor + 5)); ((cursor >= ${#labels[@]})) && cursor=$((${#labels[@]} - 1)) ;;
                esac
                ;;
            ' ')
                selected[$cursor]=$((1 - selected[$cursor]))
                ;;
            '')
                MENU_SELECTED=("${selected[@]}")
                return 0
                ;;
            q|Q)
                die "Restore cancelled."
                ;;
        esac
    done
}

choose_components() {
    echo
    echo "============================================================"
    echo " SERVER DISASTER RECOVERY RESTORE v$SCRIPT_VERSION"
    echo "============================================================"
    echo
    echo "Archive:"
    echo "  $ARCHIVE"
    echo

    local -a labels=(
        "/var/www"
        "Nginx + Let's Encrypt"
        "PostgreSQL"
        "MongoDB"
        "Microsoft SQL Server"
        "Custom systemd units"
        "CrowdSec configuration"
        "Docker volumes"
        "Firewall rules"
        "SSH configuration"
    )

    # Defaults: common application/runtime pieces ON; MSSQL/firewall/SSH OFF.
    MENU_SELECTED=(1 1 1 1 0 1 1 1 0 0)
    menu_checkbox "SELECT RESTORE COMPONENTS" "${labels[@]}"

    RESTORE_WWW="${MENU_SELECTED[0]}"
    RESTORE_NGINX="${MENU_SELECTED[1]}"
    RESTORE_POSTGRES="${MENU_SELECTED[2]}"
    RESTORE_MONGO="${MENU_SELECTED[3]}"
    RESTORE_MSSQL="${MENU_SELECTED[4]}"
    RESTORE_SYSTEMD="${MENU_SELECTED[5]}"
    RESTORE_CROWDSEC="${MENU_SELECTED[6]}"
    RESTORE_DOCKER="${MENU_SELECTED[7]}"
    RESTORE_FIREWALL="${MENU_SELECTED[8]}"
    RESTORE_SSH="${MENU_SELECTED[9]}"

    echo
    echo "Selected components:"
    printf '  /var/www                 : %s\n' "$RESTORE_WWW"
    printf "  Nginx + Let\'s Encrypt     : %s\n" "$RESTORE_NGINX"
    printf '  PostgreSQL                : %s\n' "$RESTORE_POSTGRES"
    printf '  MongoDB                   : %s\n' "$RESTORE_MONGO"
    printf '  Microsoft SQL Server     : %s\n' "$RESTORE_MSSQL"
    printf '  systemd                   : %s\n' "$RESTORE_SYSTEMD"
    printf '  CrowdSec                  : %s\n' "$RESTORE_CROWDSEC"
    printf '  Docker                    : %s\n' "$RESTORE_DOCKER"
    printf '  Firewall                  : %s\n' "$RESTORE_FIREWALL"
    printf '  SSH                       : %s\n' "$RESTORE_SSH"
    echo
}

# -------------------------------------------------------------------
# Package bootstrap / upgrade
# -------------------------------------------------------------------

APT_DISABLED_REPOS=()

# Recover stale repository files left by an interrupted/older restore run.
# Example: mssql-release.list.restore-disabled.restore-disabled
# Only recover the original .list/.sources name when that original file is absent.
recover_stale_apt_repository_files() {
    local f original
    while IFS= read -r -d '' f; do
        original="$f"
        while [[ "$original" == *.restore-disabled ]]; do
            original="${original%.restore-disabled}"
        done

        if [[ "$original" == *.list || "$original" == *.sources ]]; then
            if [[ ! -e "$original" ]]; then
                mv -f -- "$f" "$original" || warn "Could not recover stale APT repository file: $f"
                log "Recovered stale Microsoft APT source: $original"
            else
                # The active source already exists; stale backup is not an active
                # repository and can safely remain untouched for manual review.
                log "Leaving stale disabled APT source untouched: $f"
            fi
        fi
    done < <(find /etc/apt/sources.list.d -maxdepth 1 -type f -name '*.restore-disabled*' -print0 2>/dev/null || true)
}

restore_apt_repositories() {
    local f original
    for f in "${APT_DISABLED_REPOS[@]:-}"; do
        [[ -f "$f" ]] || continue
        original="${f%.restore-disabled}"
        mv -f -- "$f" "$original" || warn "Could not restore APT repository file: $original"
    done
    APT_DISABLED_REPOS=()
}

# Always put temporarily disabled repositories back, even if package setup fails.
trap restore_apt_repositories EXIT

setup_mongodb_apt_repo() {
    local id="$1" version_codename="$2" arch
    arch="$(dpkg --print-architecture)"

    case "$id:$version_codename" in
        ubuntu:noble|ubuntu:jammy|ubuntu:focal)
            ;;
        debian:bookworm)
            ;;
        *)
            return 1
            ;;
    esac

    cmd curl || apt-get install -y curl
    cmd gpg || apt-get install -y gnupg

    install -d -m 0755 /usr/share/keyrings
    curl -fsSL https://pgp.mongodb.com/server-8.0.asc |
        gpg --dearmor --yes -o /usr/share/keyrings/mongodb-server-8.0.gpg
    chmod 0644 /usr/share/keyrings/mongodb-server-8.0.gpg

    local list_file="/etc/apt/sources.list.d/mongodb-org-8.0.list"
    if [[ "$id" == "ubuntu" ]]; then
        cat > "$list_file" <<EOF
# Managed by server-restore.sh
# MongoDB Community 8.0 official repository
 deb [ arch=${arch} signed-by=/usr/share/keyrings/mongodb-server-8.0.gpg ] https://repo.mongodb.org/apt/ubuntu ${version_codename}/mongodb-org/8.0 multiverse
EOF
    else
        cat > "$list_file" <<EOF
# Managed by server-restore.sh
# MongoDB Community 8.0 official repository
 deb [ arch=${arch} signed-by=/usr/share/keyrings/mongodb-server-8.0.gpg ] https://repo.mongodb.org/apt/debian ${version_codename}/mongodb-org/8.0 main
EOF
    fi
    sed -i 's/^ deb/deb/' "$list_file"
    chmod 0644 "$list_file"
    log "MongoDB: official MongoDB 8.0 APT repository configured."
}

setup_mssql_apt_repo() {
    local version_id="$1"

    [[ "$ID" == "ubuntu" ]] || return 1

    cmd curl || apt-get install -y curl
    cmd gpg || apt-get install -y gnupg

    case "$version_id" in
        24.04)
            local repo_url="https://packages.microsoft.com/config/ubuntu/24.04/mssql-server-2025.list"
            ;;
        22.04)
            local repo_url="https://packages.microsoft.com/config/ubuntu/22.04/mssql-server-2025.list"
            ;;
        20.04)
            local repo_url="https://packages.microsoft.com/config/ubuntu/20.04/mssql-server-2022.list"
            ;;
        *)
            return 1
            ;;
    esac

    install -d -m 0755 /usr/share/keyrings
    curl -fsSL https://packages.microsoft.com/keys/microsoft.asc |
        gpg --dearmor --yes -o /usr/share/keyrings/microsoft-prod.gpg
    chmod 0644 /usr/share/keyrings/microsoft-prod.gpg

    local list_file="/etc/apt/sources.list.d/mssql-server-restore.list"
    curl -fsSL "$repo_url" -o "$list_file"
    chmod 0644 "$list_file"
    log "MSSQL: Microsoft SQL Server repository configured for Ubuntu ${version_id}."
}

install_selected_packages() {
    [[ -f /etc/os-release ]] || return 0
    # shellcheck disable=SC1091
    source /etc/os-release

    case "$ID" in
        ubuntu|debian)
            export DEBIAN_FRONTEND=noninteractive

            local microsoft_files=()
            local ms_source

            recover_stale_apt_repository_files

            # If MSSQL is not selected, temporarily disable only ACTIVE Microsoft
            # APT sources. Never scan *.restore-disabled* files; those are backup
            # names and must not be disabled again.
            if [[ "$RESTORE_MSSQL" != 1 ]]; then
                while IFS= read -r -d '' f; do
                    microsoft_files+=("$f")
                done < <(
                    {
                        [[ -f /etc/apt/sources.list ]] && printf '%s\0' /etc/apt/sources.list
                        find /etc/apt/sources.list.d -maxdepth 1 -type f \
                            \( -name '*.list' -o -name '*.sources' \) -print0 2>/dev/null || true
                    } | while IFS= read -r -d '' f; do
                        if grep -qiE 'packages\.microsoft\.com' "$f" 2>/dev/null; then
                            printf '%s\0' "$f"
                        fi
                    done
                )

                for f in "${microsoft_files[@]}"; do
                    [[ -f "$f" ]] || continue
                    ms_source="${f}.restore-disabled"
                    mv -f -- "$f" "$ms_source"
                    APT_DISABLED_REPOS+=("$ms_source")
                    log "Temporarily disabled Microsoft APT source: $f"
                done
            fi

            log "Installing/upgrading base restore tools..."
            apt-get update

            local -a pkgs=(tar gzip coreutils ca-certificates curl gnupg)
            [[ "$RESTORE_NGINX" == 1 ]]    && pkgs+=(nginx)
            [[ "$RESTORE_POSTGRES" == 1 ]] && pkgs+=(postgresql postgresql-client)
            [[ "$RESTORE_DOCKER" == 1 ]]   && pkgs+=(docker.io)
            [[ "$RESTORE_SSH" == 1 ]]      && pkgs+=(openssh-server)
            [[ "$RESTORE_FIREWALL" == 1 ]] && pkgs+=(ufw iptables nftables)

            # MongoDB official repository on supported Ubuntu/Debian releases.
            if [[ "$RESTORE_MONGO" == 1 ]]; then
                if ! cmd mongorestore || ! cmd mongod; then
                    if setup_mongodb_apt_repo "$ID" "${VERSION_CODENAME:-}"; then
                        apt-get update
                        pkgs+=(mongodb-org)
                    else
                        die "MongoDB is not installed and automatic repository setup is unsupported for $ID ${VERSION_ID:-unknown}."
                    fi
                fi
            fi

            # MSSQL official repository + server/tools on supported Ubuntu.
            if [[ "$RESTORE_MSSQL" == 1 ]]; then
                if [[ "$ID" != "ubuntu" ]]; then
                    die "Automatic fresh MSSQL installation is supported here only on Ubuntu. Install Microsoft SQL Server separately on this OS, then rerun the restore."
                fi
                if ! cmd sqlcmd || ! cmd mssql-conf || ! cmd systemctl || ! systemctl list-unit-files mssql-server.service >/dev/null 2>&1; then
                    setup_mssql_apt_repo "$VERSION_ID" ||
                        die "Unsupported Ubuntu version for the automatic MSSQL restore bootstrap: $VERSION_ID"
                    apt-get update
                    pkgs+=(mssql-server mssql-tools18 unixodbc-dev)
                fi
            fi

            if [[ "$UPGRADE_SELECTED_PACKAGES" == 1 && ${#pkgs[@]} -gt 0 ]]; then
                log "Upgrading selected restore packages where newer versions are available..."
                apt-get install -y --only-upgrade "${pkgs[@]}" ||
                    warn "Some selected packages were not already installed; normal installation will handle them."
            fi

            log "Installing required restore packages..."
            apt-get install -y "${pkgs[@]}"

            # Ensure command-line database tools are available when the server
            # packages are already installed but PATH is not configured.
            if [[ "$RESTORE_MONGO" == 1 ]] && ! cmd mongorestore; then
                [[ -x /usr/bin/mongorestore ]] && ln -sf /usr/bin/mongorestore /usr/local/bin/mongorestore
            fi

            if [[ "$RESTORE_MSSQL" == 1 ]]; then
                if [[ -x /opt/mssql-tools18/bin/sqlcmd ]]; then
                    ln -sf /opt/mssql-tools18/bin/sqlcmd /usr/local/bin/sqlcmd
                fi
                cmd sqlcmd || die "sqlcmd is not available after MSSQL tools installation."
                [[ -x /opt/mssql/bin/mssql-conf ]] || die "mssql-conf is not available after MSSQL installation."
            fi

            restore_apt_repositories
            ;;

        arch)
            log "Synchronizing Arch repositories and upgrading the system..."
            pacman -Syu --noconfirm --needed

            local -a pkgs=()
            [[ "$RESTORE_NGINX" == 1 ]]    && pkgs+=(nginx)
            [[ "$RESTORE_POSTGRES" == 1 ]] && pkgs+=(postgresql)
            [[ "$RESTORE_DOCKER" == 1 ]]   && pkgs+=(docker)
            [[ "$RESTORE_SSH" == 1 ]]      && pkgs+=(openssh)
            [[ "$RESTORE_FIREWALL" == 1 ]] && pkgs+=(ufw iptables-nft nftables)

            if [[ "$RESTORE_MONGO" == 1 ]]; then
                if ! cmd mongorestore; then
                    die "MongoDB Database Tools are not installed on Arch. Install mongorestore from your approved repository/AUR first."
                fi
            fi

            if [[ "$RESTORE_MSSQL" == 1 ]]; then
                die "Automatic fresh MSSQL installation is not provided for Arch. Install a supported Microsoft SQL Server Linux package separately, then rerun the restore."
            fi

            if ((${#pkgs[@]})); then
                log "Installing/upgrading selected Arch restore packages..."
                pacman -S --noconfirm --needed "${pkgs[@]}"
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

    log "Archive root detected: $TREE"
    if [[ -f "$TREE/MANIFEST.sha256" ]]; then
        log "Backup manifest found: $TREE/MANIFEST.sha256"
    else
        warn "Backup MANIFEST.sha256 not found inside archive."
    fi

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

normalize_nginx_http2_syntax() {
    [[ -d /etc/nginx ]] || return 0

    local f tmp
    while IFS= read -r -d '' f; do
        # Modern nginx deprecates: listen 443 ssl http2;
        # Convert it to:
        #   listen 443 ssl;
        #   http2 on;
        #
        # Only transform a listen directive that explicitly contains
        # the standalone http2 parameter. Do not touch comments.
        if grep -Eq '^[[:space:]]*listen[[:space:]].*[[:space:]]http2[[:space:]]*;' "$f"; then
            tmp="${f}.restore-http2.tmp"

            awk '
            BEGIN { has_http2_on=0 }
            /^[[:space:]]*http2[[:space:]]+on[[:space:]]*;/ { has_http2_on=1 }
            {
                line=$0
                if (line !~ /^[[:space:]]*#/
                    && line ~ /^[[:space:]]*listen[[:space:]].*[[:space:]]http2[[:space:]]*;/) {
                    sub(/[[:space:]]+http2[[:space:]]*;/, ";", line)
                    print line
                    if (!has_http2_on) {
                        print "    http2 on;"
                        has_http2_on=1
                    }
                } else {
                    print line
                }
            }' "$f" > "$tmp" || {
                rm -f "$tmp"
                die "Nginx: failed to normalize HTTP/2 syntax in $f"
            }

            cat "$tmp" > "$f"
            rm -f "$tmp"
            log "Nginx: migrated deprecated listen ... http2 syntax in $f"
        fi
    done < <(find /etc/nginx -type f \( -name '*.conf' -o -path '*/sites-enabled/*' -o -path '*/sites-available/*' \) -print0 2>/dev/null)
}

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

    log "Normalizing deprecated Nginx HTTP/2 listen syntax..."
    normalize_nginx_http2_syntax

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

restore_postgres_globals_prepare() {
    local input="$1"
    local output="$TREE/POSTGRES/globals.restore.sql"

    mkdir -p "$(dirname "$output")" ||
        die "PostgreSQL: could not create globals restore workspace."
    local line decl role_name
    local -a existing_roles=()
    declare -A existing_role_map=()

    while IFS= read -r role_name; do
        [[ -n "$role_name" ]] || continue
        existing_role_map["$role_name"]=1
    done < <(
        runuser -u postgres -- psql -Atqc "SELECT rolname FROM pg_roles;"
    )

    [[ -f "$input" ]] || die "PostgreSQL: globals input file not found: $input"
    : > "$output" || die "PostgreSQL: could not create prepared globals file: $output"

    local create_role_re='^CREATE[[:space:]]+ROLE[[:space:]]+(.+);[[:space:]]*$'

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ $create_role_re ]]; then
            decl="${BASH_REMATCH[1]}"
            role_name="$decl"

            # pg_dumpall normally emits CREATE ROLE <identifier>;
            # support both quoted and unquoted identifiers here.
            if [[ "${role_name:0:1}" == '"' && "${role_name: -1}" == '"' ]]; then
                role_name="${role_name:1:${#role_name}-2}"
                role_name="$(printf '%s' "$role_name" | sed 's/""/"/g')"
            fi

            if [[ -n "${existing_role_map[$role_name]+x}" ]]; then
                printf '%s\n' "-- RESTORE SKIPPED: role '$role_name' already exists."
            else
                printf '%s\n' "$line"
            fi
        else
            printf '%s\n' "$line"
        fi
    done < "$input" > "$output"

    chown postgres:postgres "$output" ||
        die "PostgreSQL: could not set ownership on prepared globals file."
    chmod 600 "$output" ||
        die "PostgreSQL: could not set permissions on prepared globals file."

    [[ -s "$output" ]] ||
        die "PostgreSQL: prepared globals file is empty: $output"

    log "PostgreSQL: prepared globals file: $output"
    printf '%s\n' "$output"
}

set_new_postgres_password() {
    local pg_user="$1"
    local p1 p2

    echo
    echo "PostgreSQL '$pg_user' password can be replaced with a new password."
    echo "This is useful on a fresh disaster-recovery server because the old password may be unknown."

    while true; do
        read -r -s -p "New PostgreSQL password for '$pg_user': " p1
        echo
        read -r -s -p "Confirm PostgreSQL password: " p2
        echo

        [[ -n "$p1" ]] || { warn "PostgreSQL password cannot be empty."; continue; }
        [[ "$p1" == "$p2" ]] || { warn "PostgreSQL passwords do not match."; continue; }

        runuser -u postgres -- psql -v ON_ERROR_STOP=1 \
            -c "ALTER ROLE $(sql_ident_escape "$pg_user") PASSWORD '$(sql_literal_escape "$p1")';" \
            && break

        warn "PostgreSQL password change failed. Try again."
    done

    unset p1 p2
    log "PostgreSQL: new password configured successfully for '$pg_user'."
}

restore_postgres() {
    [[ "$RESTORE_POSTGRES" == 1 ]] || return 0
    [[ -d "$TREE/POSTGRES/databases" ]] || {
        warn "PostgreSQL backup directory not found."
        return 0
    }

    cmd psql || die "psql is required for PostgreSQL restore."
    cmd pg_restore || die "pg_restore is required for PostgreSQL restore."
    cmd runuser || die "runuser is required for local PostgreSQL restore."
    id postgres >/dev/null 2>&1 || die "PostgreSQL OS user 'postgres' does not exist."

    log "[6] Restoring PostgreSQL"
    log "PostgreSQL: preparing backup ownership and permissions..."

    chown -R postgres:postgres "$TREE/POSTGRES" ||
        die "Could not assign PostgreSQL backup ownership to postgres."
    chmod -R u+rwX "$TREE/POSTGRES" ||
        die "Could not set PostgreSQL backup permissions."

    # RESTORE_ROOT/TREE are private by default (umask 077). Grant only
    # traversal to allow the postgres OS account to reach its own files.
    chmod o+x "$RESTORE_ROOT" "$TREE" ||
        die "Could not grant PostgreSQL traverse permission to restore workspace."

    log "PostgreSQL: backup ownership fixed (postgres:postgres)."
    log "PostgreSQL: restore workspace traverse permission fixed."

    systemctl enable postgresql 2>/dev/null || true
    systemctl start postgresql || die "PostgreSQL service could not be started."

    local pg_user="${PG_USER:-postgres}"
    local pg_host="${PG_HOST:-}"
    local pg_port="${PG_PORT:-}"
    local use_local_auth=0
    local -a PSQL_BASE

    PSQL_BASE=(psql -v ON_ERROR_STOP=1)

    if [[ -n "$pg_host" ]]; then
        PSQL_BASE+=(-h "$pg_host")
        [[ -n "$pg_port" ]] && PSQL_BASE+=(-p "$pg_port")
        PSQL_BASE+=(-U "$pg_user")
        prompt_password PG_PASSWORD "PostgreSQL user '$pg_user'"
        [[ -n "${PG_PASSWORD:-}" ]] && export PGPASSWORD="$PG_PASSWORD"
        log "PostgreSQL: using configured remote/password authentication."
    else
        use_local_auth=1
        log "PostgreSQL: using local OS authentication; old PostgreSQL password is not required."
    fi

    pg_exec() {
        if ((use_local_auth)); then
            runuser -u postgres -- psql -v ON_ERROR_STOP=1 "$@"
        else
            "${PSQL_BASE[@]}" "$@"
        fi
    }

    pg_restore_exec() {
        if ((use_local_auth)); then
            runuser -u postgres -- pg_restore "$@"
        else
            pg_restore "$@"
        fi
    }

    if [[ -f "$TREE/POSTGRES/globals.sql" ]]; then
        log "PostgreSQL: preparing globals.sql for idempotent role restore..."
        local globals_restore
        if ((use_local_auth)); then
            globals_restore="$(restore_postgres_globals_prepare "$TREE/POSTGRES/globals.sql")"
        else
            globals_restore="$TREE/POSTGRES/globals.sql"
        fi

        log "PostgreSQL: restoring global roles/privileges..."
        if ! pg_exec -d postgres -f "$globals_restore"; then
            unset PGPASSWORD
            die "PostgreSQL globals restore failed."
        fi
        log "PostgreSQL: globals restored successfully. Existing roles were preserved without duplicate CREATE ROLE errors."
    fi

    local -a dumps=()
    local dump db safe db_exists ident total index
    shopt -s nullglob
    dumps=( "$TREE"/POSTGRES/databases/*.dump )
    shopt -u nullglob

    total=${#dumps[@]}
    if ((total == 0)); then
        unset PGPASSWORD
        if ((use_local_auth)) && [[ "$pg_user" == "postgres" ]]; then
            set_new_postgres_password "$pg_user"
        fi
        warn "No PostgreSQL database dumps found."
        return 0
    fi

    index=0
    for dump in "${dumps[@]}"; do
        index=$((index + 1))
        db="$(basename "$dump" .dump)"
        safe="$db"
        ident="$(sql_ident_escape "$safe")"

        log "PostgreSQL [$index/$total]: restoring database '$safe'..."

        db_exists="$(
            pg_exec -d postgres -Atqc \
                "SELECT 1 FROM pg_database WHERE datname='$(sql_literal_escape "$safe")';" \
                2>/dev/null || true
        )"

        if [[ "$db_exists" == "1" ]]; then
            log "PostgreSQL [$index/$total]: dropping existing database '$safe'..."
            pg_exec -d postgres -c "DROP DATABASE \"$ident\" WITH (FORCE);" || {
                unset PGPASSWORD
                die "Could not drop existing PostgreSQL database: $safe"
            }
        fi

        log "PostgreSQL [$index/$total]: creating database '$safe'..."
        pg_exec -d postgres -c "CREATE DATABASE \"$ident\";" || {
            unset PGPASSWORD
            die "Could not create PostgreSQL database: $safe"
        }

        log "PostgreSQL [$index/$total]: loading $(basename "$dump")..."
        if ! pg_restore_exec \
            -v \
            --exit-on-error \
            --no-owner \
            --no-acl \
            --dbname="$safe" \
            "$dump"; then
            unset PGPASSWORD
            die "PostgreSQL restore failed for database: $safe"
        fi

        log "PostgreSQL [$index/$total]: database '$safe' restored successfully."
    done

    unset PGPASSWORD

    if ((use_local_auth)) && [[ "$pg_user" == "postgres" ]]; then
        set_new_postgres_password "$pg_user"
    fi

    log "PostgreSQL: restore completed successfully ($total database(s))."
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
    cmd mongod || warn "mongod binary was not found; assuming MongoDB is provided by an external service."

    log "[7] Restoring MongoDB"
    log "MongoDB: preparing backup ownership and permissions..."

    # The restore process itself runs as root, but the backup file is kept
    # private and assigned to the service account when it exists.
    if id mongodb >/dev/null 2>&1; then
        chown mongodb:mongodb "$TREE/MONGODB/mongodb.archive.gz" ||
            die "Could not assign MongoDB backup ownership."
    else
        chown root:root "$TREE/MONGODB/mongodb.archive.gz" ||
            die "Could not assign MongoDB backup ownership."
    fi
    chmod 600 "$TREE/MONGODB/mongodb.archive.gz" ||
        die "Could not set MongoDB backup permissions."

    log "MongoDB: backup ownership/permissions fixed."

    if systemctl list-unit-files mongod.service >/dev/null 2>&1; then
        systemctl enable mongod 2>/dev/null || true
        systemctl start mongod || die "MongoDB service could not be started."
        systemctl is-active --quiet mongod || die "MongoDB service is not active."
    elif systemctl list-unit-files mongodb.service >/dev/null 2>&1; then
        systemctl enable mongodb 2>/dev/null || true
        systemctl start mongodb || die "MongoDB service could not be started."
        systemctl is-active --quiet mongodb || die "MongoDB service is not active."
    else
        die "MongoDB service unit not found."
    fi

    local uri="${MONGO_URI:-mongodb://127.0.0.1:27017}"
    prompt_with_default MONGO_URI "MongoDB URI" "$uri"
    uri="${MONGO_URI:-mongodb://127.0.0.1:27017}"

    log "MongoDB: restoring archive..."
    if ! mongorestore \
        --uri="$uri" \
        --archive="$TREE/MONGODB/mongodb.archive.gz" \
        --gzip \
        --drop \
        --stopOnError; then
        die "MongoDB restore failed."
    fi

    log "MongoDB: restore completed successfully."
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

mssql_validate_password() {
    local p="$1"
    local len count=0
    len=${#p}

    ((len >= 8 && len <= 128)) || return 1
    [[ "$p" =~ [A-Z] ]] && count=$((count + 1))
    [[ "$p" =~ [a-z] ]] && count=$((count + 1))
    [[ "$p" =~ [0-9] ]] && count=$((count + 1))
    [[ "$p" =~ [^A-Za-z0-9] ]] && count=$((count + 1))

    ((count >= 3))
}

prompt_mssql_sa_password() {
    local p1 p2
    while true; do
        read -r -s -p "NEW MSSQL sa password: " p1
        echo
        read -r -s -p "Confirm NEW MSSQL sa password: " p2
        echo

        [[ "$p1" == "$p2" ]] || { warn "MSSQL passwords do not match."; continue; }
        mssql_validate_password "$p1" || {
            warn "MSSQL password must be 8-128 characters and contain characters from at least 3 of: uppercase, lowercase, number, symbol."
            continue
        }
        MSSQL_NEW_SA_PASSWORD="$p1"
        unset p1 p2
        return 0
    done
}

setup_fresh_mssql_if_needed() {
    local server_conf="/var/opt/mssql/mssql.conf"
    local pid="${MSSQL_PID:-Developer}"

    [[ -x /opt/mssql/bin/mssql-conf ]] || die "mssql-conf is not installed."

    # Native package installs require an initial mssql-conf setup. Detect a
    # configured instance by the presence of the EULA acceptance setting.
    if [[ -f "$server_conf" ]] && grep -qiE '^[[:space:]]*accepteula[[:space:]]*=[[:space:]]*[Yy]' "$server_conf"; then
        return 0
    fi

    echo
    echo "Fresh SQL Server installation detected."
    echo "A NEW sa password is required; the old server password is not needed."
    prompt_with_default MSSQL_PID "MSSQL edition/product ID" "$pid"
    pid="$MSSQL_PID"
    prompt_mssql_sa_password

    log "MSSQL: performing unattended first-time setup..."
    if ! ACCEPT_EULA=Y MSSQL_PID="$pid" MSSQL_SA_PASSWORD="$MSSQL_NEW_SA_PASSWORD" \
        /opt/mssql/bin/mssql-conf -n setup; then
        unset MSSQL_NEW_SA_PASSWORD
        die "MSSQL first-time setup failed."
    fi

    MSSQL_PASSWORD="$MSSQL_NEW_SA_PASSWORD"
    unset MSSQL_NEW_SA_PASSWORD
    systemctl enable mssql-server >/dev/null 2>&1 || true
    systemctl restart mssql-server || die "MSSQL service failed to start after initial setup."
}

restore_mssql() {
    [[ "$RESTORE_MSSQL" == 1 ]] || return 0
    [[ -d "$TREE/MSSQL/bak" ]] || {
        warn "MSSQL backup directory not found."
        return 0
    }

    cmd sqlcmd || die "sqlcmd is required for MSSQL restore."

    log "[8] Restoring Microsoft SQL Server"
    setup_fresh_mssql_if_needed

    local server="${MSSQL_SERVER:-127.0.0.1,1433}"
    local user="${MSSQL_USER:-sa}"
    local password="${MSSQL_PASSWORD:-}"

    prompt_with_default MSSQL_SERVER "MSSQL server" "$server"
    server="$MSSQL_SERVER"

    prompt_with_default MSSQL_USER "MSSQL username" "$user"
    user="$MSSQL_USER"

    if [[ -z "$password" ]]; then
        prompt_password MSSQL_PASSWORD "MSSQL user '$user'"
        password="${MSSQL_PASSWORD:-}"
    fi

    [[ -n "$password" ]] || die "MSSQL password is required for SQL restore."

    # SQLCMDPASSWORD avoids putting the SA password in the process command line.
    export SQLCMDPASSWORD="$password"

    local -a SQLCMD
    SQLCMD=(sqlcmd -S "$server" -C -b -U "$user")

    local server_info="$TREE/MSSQL/restore-server-info.txt"
    if ! "${SQLCMD[@]}" -Q "SELECT @@SERVERNAME AS ServerName, SERVERPROPERTY('Edition') AS Edition, SERVERPROPERTY('ProductVersion') AS ProductVersion;" > "$server_info" 2>&1; then
        unset SQLCMDPASSWORD MSSQL_PASSWORD
        die "Cannot connect to MSSQL with the supplied credentials."
    fi

    # SQL Server reads .bak files as the mssql service account. Stage them in
    # its native backup directory with strict ownership and permissions.
    local mssql_backup_dir="/var/opt/mssql/backup"
    mkdir -p "$mssql_backup_dir"
    chown mssql:mssql "$mssql_backup_dir" || die "Could not assign MSSQL backup directory ownership."
    chmod 750 "$mssql_backup_dir" || die "Could not set MSSQL backup directory permissions."

    log "MSSQL: staging backup files into $mssql_backup_dir..."

    shopt -s nullglob
    local -a baks=( "$TREE"/MSSQL/bak/*.bak )
    shopt -u nullglob

    local total=${#baks[@]}
    if ((total == 0)); then
        unset SQLCMDPASSWORD MSSQL_PASSWORD
        warn "No MSSQL .bak files found."
        return 0
    fi

    local bak staged_bak db qdb qpath logical_data logical_log data_file log_file sql
    local index=0

    for bak in "${baks[@]}"; do
        index=$((index + 1))
        db="$(basename "$bak" .bak)"
        staged_bak="$mssql_backup_dir/$(basename "$bak")"

        log "MSSQL [$index/$total]: staging $(basename "$bak")..."
        install -o mssql -g mssql -m 0600 "$bak" "$staged_bak" ||
            die "Could not stage MSSQL backup: $bak"

        qdb="$(mssql_escape_identifier "$db")"
        qpath="$(mssql_escape_literal "$staged_bak")"

        log "MSSQL [$index/$total]: verifying backup '$db'..."
        if ! "${SQLCMD[@]}" -Q "RESTORE VERIFYONLY FROM DISK=N'$qpath';"; then
            die "MSSQL backup verification failed: $db"
        fi
        log "MSSQL [$index/$total]: backup verification OK."

        log "MSSQL [$index/$total]: reading logical file names..."
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

        if [[ -z "$logical_data" || -z "$logical_log" ]]; then
            die "Could not determine logical data/log files for MSSQL database: $db"
        fi

        mkdir -p /var/opt/mssql/data
        chown mssql:mssql /var/opt/mssql/data
        chmod 750 /var/opt/mssql/data

        data_file="/var/opt/mssql/data/${db}.mdf"
        log_file="/var/opt/mssql/data/${db}_log.ldf"

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

        log "MSSQL [$index/$total]: restoring database '$db'..."
        if ! "${SQLCMD[@]}" -Q "$sql"; then
            "${SQLCMD[@]}" -Q \
                "IF DB_ID(N'$(mssql_escape_literal "$db")') IS NOT NULL ALTER DATABASE [$qdb] SET MULTI_USER;" \
                >/dev/null 2>&1 || true
            die "MSSQL restore failed for database: $db"
        fi

        log "MSSQL [$index/$total]: database '$db' restored successfully."
    done

    unset SQLCMDPASSWORD MSSQL_PASSWORD
    log "MSSQL: restore completed successfully ($total database(s))."
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
    echo "Debug log:"
    echo "  $LOG_FILE"
    if [[ -n "${TRACE_FILE:-}" ]]; then
        echo "Shell trace:"
        echo "  $TRACE_FILE"
    fi
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
    echo
    echo "IMPORTANT: Do not delete $RESTORE_ROOT until the restored services"
    echo "and databases have been verified."
}

# -------------------------------------------------------------------
# Main
# -------------------------------------------------------------------

main() {
    mkdir -p "$RESTORE_ROOT"
    log "Starting server disaster-recovery restore v$SCRIPT_VERSION"
    log "Archive: $ARCHIVE"
    log "Restore workspace: $RESTORE_ROOT"
    log "Persistent debug log: $LOG_FILE"

    if [[ "$DEBUG" == "1" ]]; then
        TRACE_FILE="$RESTORE_ROOT/debug.trace"
        exec 19>"$TRACE_FILE"
        export BASH_XTRACEFD=19
        PS4='+ ${BASH_SOURCE}:${LINENO}:${FUNCNAME[0]}: '
        set -x
        log "DEBUG shell tracing enabled: $TRACE_FILE"
    fi

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

    log "All selected restore stages completed."
    final_status
}

main "$@"
