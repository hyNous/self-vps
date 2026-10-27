#!/usr/bin/env bash
set -Eeuo pipefail

[[ ${EUID} -eq 0 ]] || {
  echo "Error: run with sudo" >&2
  exit 1
}

destination="${1:-/var/backups/self-vps}"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
archive="$destination/self-vps-$timestamp.tar.gz"
compose_files=()
monitoring_stopped=0

install -d -m 700 "$destination"

for compose in \
  /opt/self-vps-monitoring/compose.yaml \
  /opt/uptime-kuma/compose.yml \
  /opt/beszel/compose.yml; do
  [[ -f "$compose" ]] && compose_files+=("$compose")
done

if ((${#compose_files[@]} > 0)); then
  for compose in "${compose_files[@]}"; do
    docker compose -f "$compose" stop || true
  done
  monitoring_stopped=1
fi

restart_monitoring() {
  if ((monitoring_stopped)); then
    for compose in "${compose_files[@]}"; do
      docker compose -f "$compose" start || true
    done
  fi
}
trap restart_monitoring EXIT

paths=()
for path in \
  etc/self-vps \
  etc/letsencrypt \
  etc/cloudflared \
  etc/nginx/sites-available \
  etc/nginx/sites-enabled \
  etc/systemd/system/cloudflared.service \
  usr/local/etc/xray/config.json \
  var/www \
  etc/modules-load.d/bbr.conf \
  etc/sysctl.d/99-bbr.conf \
  etc/sysctl.d/99-tcp-tune.conf \
  etc/sysctl.conf \
  etc/ssh/sshd_config.d/00-hynous-hardening.conf \
  etc/nginx/qqq-8443.conf; do
  [[ -e "/$path" ]] && paths+=("$path")
done
for unit in /etc/systemd/system/cloudflared-*.service /etc/systemd/system/qqq-*.service; do
  [[ -e "$unit" ]] && paths+=("${unit#/}")
done
for dir in /opt/self-vps-monitoring /opt/uptime-kuma /opt/beszel; do
  [[ -d "$dir" ]] && paths+=("${dir#/}")
done

# Optional extra paths, one absolute path per line. This is how deployments
# with additional applications add them without hard-coding those apps here.
if [[ -f /etc/self-vps/backup-extra-paths ]]; then
  while IFS= read -r extra; do
    [[ -z "$extra" || "$extra" == \#* ]] && continue
    [[ "$extra" == /* ]] || {
      echo "Error: backup-extra-paths entries must be absolute: $extra" >&2
      exit 1
    }
    [[ -e "$extra" ]] && paths+=("${extra#/}")
  done </etc/self-vps/backup-extra-paths
fi

tar -C / -czf "$archive" "${paths[@]}"
chmod 600 "$archive"
(cd "$destination" && sha256sum "$(basename "$archive")" >"$(basename "$archive").sha256")
chmod 600 "$archive.sha256"

echo "Backup: $archive"
echo "Checksum: $archive.sha256"
