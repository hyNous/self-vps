#!/usr/bin/env bash
set -Eeuo pipefail

[[ ${EUID} -eq 0 ]] || {
  echo "Error: run with sudo" >&2
  exit 1
}

destination="${1:-/var/backups/self-vps}"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
archive="$destination/self-vps-$timestamp.tar.gz"
monitoring_dir="/opt/self-vps-monitoring"
monitoring_stopped=0

install -d -m 700 "$destination"

if [[ -f "$monitoring_dir/compose.yaml" ]] &&
  docker compose -f "$monitoring_dir/compose.yaml" ps --status running -q 2>/dev/null | grep -q .; then
  docker compose -f "$monitoring_dir/compose.yaml" stop
  monitoring_stopped=1
fi

restart_monitoring() {
  if ((monitoring_stopped)); then
    docker compose -f "$monitoring_dir/compose.yaml" start
  fi
}
trap restart_monitoring EXIT

paths=(
  etc/self-vps
  etc/letsencrypt
  usr/local/etc/xray/config.json
  usr/local/etc/xray/cert
)
for path in \
  etc/nginx/sites-available/self-vps \
  etc/nginx/sites-available/vless-cdn \
  etc/modules-load.d/bbr.conf \
  etc/sysctl.d/99-bbr.conf \
  etc/sysctl.d/99-tcp-tune.conf \
  etc/sysctl.conf \
  etc/ssh/sshd_config.d/00-hynous-hardening.conf; do
  [[ -e "/$path" ]] && paths+=("$path")
done
[[ -d "$monitoring_dir" ]] && paths+=(opt/self-vps-monitoring)

tar -C / -czf "$archive" "${paths[@]}"
chmod 600 "$archive"
(cd "$destination" && sha256sum "$(basename "$archive")" >"$(basename "$archive").sha256")
chmod 600 "$archive.sha256"

echo "Backup: $archive"
echo "Checksum: $archive.sha256"
