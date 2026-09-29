#!/usr/bin/env bash

# ============================================
# 1. STOP ALL SERVICES
# ============================================

systemctl stop nginx 2>/dev/null || true
systemctl stop postgresql 2>/dev/null || true
systemctl stop mongod 2>/dev/null || true
systemctl stop mongodb 2>/dev/null || true
systemctl stop mssql-server 2>/dev/null || true
systemctl stop docker 2>/dev/null || true


# ============================================
# 2. REMOVE /var/www
# ============================================

rm -rf /var/www/*
mkdir -p /var/www


# ============================================
# 3. REMOVE NGINX CONFIGURATION
# ============================================

rm -f /etc/nginx/sites-enabled/*
rm -f /etc/nginx/sites-available/*
rm -f /etc/nginx/conf.d/*

mkdir -p /etc/nginx/sites-enabled
mkdir -p /etc/nginx/sites-available


# ============================================
# 4. REMOVE POSTGRESQL COMPLETELY
# ============================================

systemctl stop postgresql 2>/dev/null || true

apt-get purge -y \
    postgresql\* \
    postgresql-client\* \
    postgresql-common 2>/dev/null || true

rm -rf /var/lib/postgresql
rm -rf /etc/postgresql
rm -rf /var/log/postgresql
rm -rf /var/run/postgresql


# ============================================
# 5. REMOVE MONGODB COMPLETELY
# ============================================

systemctl stop mongod 2>/dev/null || true
systemctl stop mongodb 2>/dev/null || true

apt-get purge -y \
    mongodb\* \
    mongodb-org\* 2>/dev/null || true

rm -rf /var/lib/mongodb
rm -rf /var/log/mongodb
rm -rf /etc/mongod.conf
rm -rf /etc/mongodb


# ============================================
# 6. REMOVE MSSQL COMPLETELY
# ============================================

systemctl stop mssql-server 2>/dev/null || true

apt-get purge -y \
    mssql-server \
    mssql-tools \
    mssql-tools18 2>/dev/null || true

rm -rf /var/opt/mssql
rm -rf /etc/opt/mssql
rm -rf /var/log/mssql


# ============================================
# 7. REMOVE DOCKER DATA
# ============================================

systemctl stop docker 2>/dev/null || true

rm -rf /var/lib/docker/volumes/*
rm -rf /var/lib/docker/containers/*
rm -rf /var/lib/docker/image/*

systemctl start docker 2>/dev/null || true


# ============================================
# 8. REMOVE OLD RESTORE STATE
# ============================================

rm -rf /var/tmp/server-restore-*
rm -rf /var/lib/server-restore
rm -rf /var/log/server-restore*


# ============================================
# 9. REMOVE OLD APT RESTORE TEMP FILES
# ============================================

rm -rf /var/lib/server-restore/apt-disabled
rm -rf /var/tmp/server-restore-apt-*


# ============================================
# 10. REMOVE OLD SYSTEMD OVERRIDES
# ============================================

rm -rf /etc/systemd/system/nginx.service.d
rm -rf /etc/systemd/system/postgresql.service.d
rm -rf /etc/systemd/system/mongod.service.d
rm -rf /etc/systemd/system/mssql-server.service.d

systemctl daemon-reload


# ============================================
# 11. CLEAN APT
# ============================================

apt-get autoremove -y
apt-get autoclean
apt-get clean


# ============================================
# 12. VERIFY
# ============================================

echo
echo "=========================================="
echo " CLEANUP COMPLETE"
echo "=========================================="

echo
echo "--- /var/www ---"
ls -la /var/www

echo
echo "--- PostgreSQL ---"
command -v psql || echo "PostgreSQL removed"

echo
echo "--- MongoDB ---"
command -v mongod || echo "MongoDB removed"

echo
echo "--- MSSQL ---"
command -v sqlcmd || echo "MSSQL tools removed"

echo
echo "--- Docker volumes ---"
docker volume ls 2>/dev/null || true

echo
echo "--- Restore temp ---"
ls -ld /var/tmp/server-restore-* 2>/dev/null || echo "Clean"

echo
echo "READY FOR FRESH RESTORE"