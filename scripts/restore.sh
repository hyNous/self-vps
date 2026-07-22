#!/usr/bin/env bash
set -Eeuo pipefail

mode="${1:-}"
[[ "$mode" == "--check" || "$mode" == "--confirm" ]] && [[ -n "${2:-}" ]] || {
  echo "Usage: $0 --check|--confirm /path/to/self-vps-TIMESTAMP.tar.gz" >&2
  exit 2
}
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

allowed='^(etc/self-vps(/.*)?|etc/nginx/sites-available/self-vps|etc/letsencrypt(/.*)?|etc/modules-load\.d/bbr\.conf|etc/sysctl\.d/99-bbr\.conf|usr/local/etc/xray/config\.json|usr/local/etc/xray/cert(/.*)?|opt/self-vps-monitoring(/.*)?)$'
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
systemctl restart nginx xray

if [[ -f /opt/self-vps-monitoring/compose.yaml ]]; then
  docker compose -f /opt/self-vps-monitoring/compose.yaml up -d
fi

echo "Restore complete. Run scripts/verify.sh and check monitoring manually."
