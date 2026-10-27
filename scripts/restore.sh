#!/usr/bin/env bash
set -Eeuo pipefail

mode="${1:-}"
if [[ "$mode" != "--check" && "$mode" != "--confirm" ]] || [[ -z "${2:-}" ]]; then
  echo "Usage: $0 --check|--confirm /path/to/self-vps-TIMESTAMP.tar.gz" >&2
  exit 2
fi
if [[ "$mode" == "--confirm" && ${EUID} -ne 0 ]]; then
  echo "Error: restore requires sudo" >&2
  exit 1
fi

archive="$(realpath "$2")"
[[ -f "$archive" ]] || {
  echo "Error: archive not found" >&2
  exit 1
}
[[ -f "$archive.sha256" ]] || {
  echo "Error: checksum file not found: $archive.sha256" >&2
  exit 1
}
(cd "$(dirname "$archive")" && sha256sum -c "$(basename "$archive").sha256")

allowed='^(etc/self-vps(/.*)?|etc/letsencrypt(/.*)?|etc/cloudflared(/.*)?|etc/nginx(/.*)?|etc/systemd/system/(cloudflared[^/]*|qqq[^/]*|self-vps-docker-watchdog[^/]*)\.(service|timer)|etc/modules-load\.d/bbr\.conf|etc/sysctl\.d/99-bbr\.conf|etc/sysctl\.d/99-tcp-tune\.conf|etc/sysctl\.conf|etc/ssh/sshd_config\.d/00-hynous-hardening\.conf|usr/local/etc/xray/config\.json|usr/local/etc/xray/cert(/.*)?|usr/local/sbin/self-vps-docker-watchdog\.sh|var/www(/.*)?|opt/(self-vps-monitoring|uptime-kuma|beszel)(/.*)?|opt/(qqq-monitor|race-history|sample-warehouse)(/.*)?)$'
while IFS= read -r entry; do
  normalized="${entry%/}"
  [[ "$normalized" =~ $allowed ]] || {
    echo "Error: unexpected archive path: $entry" >&2
    exit 1
  }
done < <(tar -tzf "$archive")

if [[ "$mode" == "--check" ]]; then
  echo "Archive checksum and paths are valid."
  exit 0
fi

tar -C / -xzf "$archive"
systemctl daemon-reload
sysctl --system >/dev/null
systemctl restart nginx xray
if [[ -f /etc/ssh/sshd_config.d/00-hynous-hardening.conf ]]; then
  sshd -t && systemctl reload ssh
fi

if command -v docker >/dev/null 2>&1; then
  for compose in \
    /opt/self-vps-monitoring/compose.yaml \
    /opt/uptime-kuma/compose.yml \
    /opt/beszel/compose.yml; do
    if [[ -f "$compose" ]]; then
      docker compose -f "$compose" up -d
    fi
  done
fi

if [[ -f /etc/systemd/system/cloudflared.service ]]; then
  systemctl restart cloudflared
fi
if [[ -f /etc/systemd/system/self-vps-docker-watchdog.timer ]]; then
  systemctl enable --now self-vps-docker-watchdog.timer
fi

echo "Restore complete. Run scripts/verify.sh and check monitoring manually."
