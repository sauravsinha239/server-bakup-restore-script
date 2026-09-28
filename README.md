# Server Disaster Recovery Backup

This package creates a portable, timestamped backup of a Linux application server and provides a restore helper.

## What is backed up

- OS/kernel/hardware/filesystem/network inventory
- Debian/Ubuntu package inventory
- .NET SDK/runtime information
- Nginx configuration and `nginx -T`
- UFW, nftables and iptables state
- CrowdSec configuration, collections, parsers, scenarios and decisions
- SSH configuration and effective configuration
- systemd units, overrides, timers, sockets and failed services
- cron configuration
- `/var/www`
- `/opt` and `/srv` (with `.git` and `node_modules` excluded)
- PostgreSQL databases + globals/roles + PostgreSQL configuration
- MongoDB logical dump using `mongodump`
- Microsoft SQL Server database `.bak` files using `BACKUP DATABASE`
- Docker metadata and named volumes
- Let's Encrypt configuration
- Fail2ban configuration
- checksums and backup metadata

## Important security warning

The archive can contain:

- TLS private keys
- SSH keys
- application configuration
- database connection strings
- password hashes
- secrets in `/var/www`, `/opt`, `/srv`
- PostgreSQL globals
- MongoDB/MSSQL data

Treat the archive as **highly sensitive**. Store an additional encrypted/off-server copy.

## Backup

```bash
sudo chmod 700 server-backup.sh
sudo mkdir -p /root/server-backups
sudo ./server-backup.sh
```

The result is:

```text
/root/server-backups/server-backup-HOST-YYYY-MM-DD_HHMMSS.tar.gz
/root/server-backups/server-backup-HOST-YYYY-MM-DD_HHMMSS.tar.gz.sha256
```

The default retention is 8 backups:

```bash
RETENTION=12 sudo ./server-backup.sh
```

## Database requirements

### PostgreSQL

The script uses the local `postgres` OS account:

```bash
sudo -u postgres pg_dumpall --globals-only
sudo -u postgres pg_dump -Fc ...
```

### MongoDB

Install `mongodump` (MongoDB Database Tools) and set `MONGO_URI` if authentication is enabled.

### Microsoft SQL Server

Install `sqlcmd`. The script discovers online user databases and executes native SQL Server `BACKUP DATABASE` with compression/checksum.

Example:

```bash
export MSSQL_SERVER=localhost
export MSSQL_USER=backupuser
export MSSQL_PASSWORD='YOUR_PASSWORD'
sudo -E ./server-backup.sh
```

For production, use a dedicated SQL Server backup principal with the minimum required permissions.

## Restore

First install the same or a compatible OS and required database/web packages.

Extract/inspect:

```bash
tar -tzf server-backup-HOST-DATE.tar.gz | less
```

Then:

```bash
sudo ./server-restore.sh server-backup-HOST-DATE.tar.gz
```

The restore script does NOT automatically replace firewall or SSH configuration.

To restore firewall:

```bash
sudo RESTORE_FIREWALL=1 ./server-restore.sh backup.tar.gz
```

Only do this when you have console access or have verified the rules.

To restore SSH:

```bash
sudo RESTORE_SSH=1 ./server-restore.sh backup.tar.gz
```

The script validates `sshd -t` before reloading SSH.

Selective restore:

```bash
sudo RESTORE_WWW=1 \
     RESTORE_NGINX=1 \
     RESTORE_POSTGRES=0 \
     RESTORE_MONGO=0 \
     RESTORE_MSSQL=0 \
     ./server-restore.sh backup.tar.gz
```

## Weekly systemd timer

After testing the script manually:

```bash
sudo install -m 700 server-backup.sh /usr/local/sbin/server-backup.sh
sudo install -m 600 server-backup.env /etc/server-backup.env
```

Create `/etc/systemd/system/server-backup.service`:

```ini
[Unit]
Description=Server Disaster Recovery Backup
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=-/etc/server-backup.env
ExecStart=/usr/local/sbin/server-backup.sh
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
```

Create `/etc/systemd/system/server-backup.timer`:

```ini
[Unit]
Description=Weekly Server Disaster Recovery Backup

[Timer]
OnCalendar=Sun 03:30
Persistent=true
RandomizedDelaySec=15m

[Install]
WantedBy=timers.target
```

Enable:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now server-backup.timer
systemctl list-timers server-backup.timer
```

Test:

```bash
sudo systemctl start server-backup.service
sudo journalctl -u server-backup.service -n 200 --no-pager
```

## Recommended disaster recovery practice

Do not keep the only backup on the same server.

Use at least:

1. local weekly backup for fast recovery
2. encrypted off-server copy
3. periodic restore test on a disposable VM

A backup that has never been restored is not a verified disaster-recovery backup.

## Notes

The restore helper intentionally does not attempt to reinstall packages or recreate DNS/cloud-provider resources. Package installation and cloud/network resources vary between servers. The package inventory tells you what must be installed before restoration.

Also review application-specific secrets, environment files, Docker Compose files, reverse-proxy DNS/certificates, cloud firewall/security-group rules and external services.
