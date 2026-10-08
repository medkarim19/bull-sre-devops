#!/bin/bash

DATE=$(date +"%Y%m%d_%H%M%S")
HOST=$(hostname -s)

BASE_DIR="/var/backups"
BACKUP_DIR="${BASE_DIR}/backup_${HOST}_${DATE}"
ENV_DIR="${BACKUP_DIR}/env_${HOST}_${DATE}"

mkdir -p "$ENV_DIR" "$BACKUP_DIR"
chmod 700 "$BASE_DIR" "$ENV_DIR" "$BACKUP_DIR"


hostnamectl > "$ENV_DIR/hostnamectl.txt"
cat /etc/os-release > "$ENV_DIR/os-release.txt"
uname -a > "$ENV_DIR/system-information.txt"

lscpu > "$ENV_DIR/cpu-specs.txt"
free -h > "$ENV_DIR/memory.txt"
lsblk -f > "$ENV_DIR/disks.txt"
df -h > "$ENV_DIR/filesystems.txt"

ip a > "$ENV_DIR/ip_addr.txt"
ip r > "$ENV_DIR/ip_route.txt"
ip n > "$ENV_DIR/ip_neigh.txt"
ss -tulpn > "$ENV_DIR/listening_ports.txt"

dnf repolist > "$ENV_DIR/dnf_repolist.txt"
dnf repolist --enabled > "$ENV_DIR/dnf_enabled_repos.txt"

rpm -qa | sort > "$ENV_DIR/packages_list.txt"

systemctl list-unit-files --state=enabled > "$ENV_DIR/services_enabled.txt"
systemctl list-units --type=service --state=running > "$ENV_DIR/services_running.txt"

cat /etc/passwd > "$ENV_DIR/users.txt"
cat /etc/group > "$ENV_DIR/groups.txt"

crontab -l > "$ENV_DIR/root_crontab.txt"
ls -la /etc/cron* > "$ENV_DIR/cron_dirs.txt"

cat /etc/fstab > "$ENV_DIR/fstab.txt"
mount > "$ENV_DIR/mounts.txt"
findmnt > "$ENV_DIR/findmnt.txt"

ps -ef > "$ENV_DIR/processes.txt"
ss -tunlp > "$ENV_DIR/network_connections.txt"

if command -v docker >/dev/null 2>&1; then
    docker --version > "$ENV_DIR/docker_version.txt"
    docker ps -a > "$ENV_DIR/docker_containers.txt"
    docker images > "$ENV_DIR/docker_images.txt"
    docker volume ls > "$ENV_DIR/docker_volumes.txt"
fi

if command -v psql >/dev/null 2>&1; then
    psql --version > "$ENV_DIR/postgresql_version.txt"
fi
rpm -qa | grep -i postgresql > "$ENV_DIR/postgresql_packages.txt"

if command -v nginx >/dev/null 2>&1; then
    nginx -v > "$ENV_DIR/nginx_version.txt"
fi

if command -v httpd >/dev/null 2>&1; then
    httpd -v > "$ENV_DIR/apache_version.txt"
fi

rpm -qa | grep -Ei "nginx|httpd" > "$ENV_DIR/web_packages.txt"

{
  echo "Server : $HOST"
  echo "Date : $(date)"
  echo
  grep PRETTY_NAME /etc/os-release
  uname -r
  echo
  echo "Installed Packages : $(rpm -qa | wc -l)"
  echo "Enabled Services : $(systemctl list-unit-files --state=enabled | wc -l)"
  echo "Running Services : $(systemctl list-units --type=service --state=running | wc -l)"
  echo "Docker Installed : $(command -v docker >/dev/null && echo YES || echo NO)"
  echo "PostgreSQL Installed : $(command -v psql >/dev/null && echo YES || echo NO)"
  echo "Nginx Installed : $(command -v nginx >/dev/null && echo YES || echo NO)"
  echo "Apache Installed : $(command -v httpd >/dev/null && echo YES || echo NO)"
} > "$ENV_DIR/summary.txt"


tar -czf "$BACKUP_DIR/etc_backup.tar" /etc

if [ -d /data ]; then
    tar -czf "$BACKUP_DIR/data_backup.tar" /data
fi

if [ -d /home ]; then
    tar -czf "$BACKUP_DIR/home_backup.tar" /home
fi

tar -czf "$BACKUP_DIR/root_backup.tar" --exclude="${BASE_DIR}" /root

cp /etc/passwd "$BACKUP_DIR/passwd_backup"
cp /etc/group "$BACKUP_DIR/group_backup"
cp /etc/shadow "$BACKUP_DIR/shadow_backup"
chmod 600 "$BACKUP_DIR/passwd_backup" "$BACKUP_DIR/group_backup" "$BACKUP_DIR/shadow_backup"

if command -v pg_dumpall >/dev/null 2>&1; then
    pg_dumpall -U postgres > "$BACKUP_DIR/postgres_backup.sql"
fi

if command -v mysqldump >/dev/null 2>&1; then
    mysqldump --all-databases > "$BACKUP_DIR/mysql_backup.sql"
fi

#if command -v docker >/dev/null 2>&1; then
#    mkdir -p "$BACKUP_DIR/docker"
#    docker ps -a > "$BACKUP_DIR/docker/docker_containers.txt"
#    docker images > "$BACKUP_DIR/docker/docker_images.txt"
#    docker volume ls > "$BACKUP_DIR/docker/docker_volumes.txt"
#
#    if [ -d /etc/docker ]; then
#        tar -czf "$BACKUP_DIR/docker/docker_config.tar" /etc/docker
#    fi
#fi

crontab -l > "$BACKUP_DIR/root_crontab_backup.txt"
systemctl list-unit-files --state=enabled > "$BACKUP_DIR/services_enabled_backup.txt"

{
  echo "Network configuration"
  echo
  ip a
  echo
  ip r
  echo
  ss -tulpn
} > "$BACKUP_DIR/network_backup.txt"


chmod -R go-rwx "$BACKUP_DIR" "$ENV_DIR"

tar -czf "${BACKUP_DIR}.tar" -C "$BASE_DIR" "$(basename "$BACKUP_DIR")"
chmod 600 "${BACKUP_DIR}.tar"

echo "Backup archive:"
echo "${BACKUP_DIR}.tar"

echo "Verifying archive integrity..."
if gzip -t "${BACKUP_DIR}.tar"; then
    echo "Integrity check passed: ${BACKUP_DIR}.tar"

    NEXUS_CONF="/etc/nexus-backup/nexus.conf"

    if [ ! -f "$NEXUS_CONF" ]; then
        echo "ERROR: Nexus credentials file not found at $NEXUS_CONF" >&2
    else
        NEXUS_URL="$(grep '^url' "$NEXUS_CONF" | cut -d'"' -f2)$(basename "${BACKUP_DIR}.tar")"

        curl --silent --show-error -K <(grep -v '^url' "$NEXUS_CONF") --upload-file "${BACKUP_DIR}.tar" "$NEXUS_URL"

        HTTP_CODE=$(curl --silent --output /dev/null --write-out "%{http_code}" --insecure -K <(grep -v '^url' "$NEXUS_CONF") --head "$NEXUS_URL")

        if [ "$HTTP_CODE" -eq 200 ]; then
            echo "Upload successful: $(basename "${BACKUP_DIR}.tar")"

            PUSH_DATE=$(curl --silent --show-error --insecure -K <(grep -v '^url' "$NEXUS_CONF") --head "$NEXUS_URL" | grep -i '^Last-Modified' | cut -d' ' -f2- | tr -d '\r' | xargs -I{} date -d "{}" +"%a %b %d %Y %H:%M:%S %Z")
            PUSH_USER=$(grep '^user' "$NEXUS_CONF" | cut -d'"' -f2 | cut -d':' -f1)
            echo "Pushed file: $(basename "$NEXUS_URL")"
            echo "Pushed date: $PUSH_DATE"
            echo "Pushed by: $PUSH_USER"

            rm -rf "$BACKUP_DIR" "${BACKUP_DIR}.tar"
        else
            echo "Upload FAILED: HTTP $HTTP_CODE"
        fi
    fi
else
    echo "Integrity check FAILED: ${BACKUP_DIR}.tar  archive is corrupted, upload skipped" >&2
fi