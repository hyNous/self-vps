#!/usr/bin/env bash
set -Eeuo pipefail

trap 'echo "Install failed at line $LINENO. Existing unmanaged configuration was not intentionally removed." >&2' ERR

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
env_file="${1:-$repo_root/.env}"
managed_dir="/etc/self-vps"
xray_config="/usr/local/etc/xray/config.json"
nginx_site="/etc/nginx/sites-available/self-vps"
nginx_vless_site="/etc/nginx/sites-available/vless-cdn"
reality_env="$managed_dir/reality.env"
vless_env="$managed_dir/vless-ws.env"
xray_install_ref="e741a4f56d368afbb9e5be3361b40c4552d3710d"

die() {
  echo "Error: $*" >&2
  exit 1
}

[[ ${EUID} -eq 0 ]] || die "run with sudo"
[[ -f "$env_file" ]] || die "missing $env_file; copy .env.example to .env first"

# The file is local administrator input and uses simple shell KEY=value syntax.
set -a
# shellcheck disable=SC1090
source "$env_file"
set +a

NODE_DOMAIN="${NODE_DOMAIN:-}"
ACME_EMAIL="${ACME_EMAIL:-}"
SSH_PORT="${SSH_PORT:-22}"
REALITY_DEST="${REALITY_DEST:-104.16.123.96:443}"
REALITY_SERVER_NAME="${REALITY_SERVER_NAME:-www.cloudflare.com}"
CDN_DOMAIN="${CDN_DOMAIN:-}"
VLESS_UUID="${VLESS_UUID:-}"
VLESS_WS_PATH="${VLESS_WS_PATH:-}"

# Reuse generated values on a managed reinstall. Empty .env values are
# intentionally allowed so an existing node can be updated without changing
# its client credentials.
if [[ -f "$reality_env" ]]; then
  # shellcheck disable=SC1090
  source "$reality_env"
fi
if [[ -f "$vless_env" ]]; then
  # shellcheck disable=SC1090
  source "$vless_env"
fi

[[ "$NODE_DOMAIN" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]] ||
  die "NODE_DOMAIN is not a valid hostname"
[[ "$NODE_DOMAIN" != *.example.com ]] || die "replace the example NODE_DOMAIN"
[[ "$ACME_EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] ||
  die "ACME_EMAIL is not valid"
if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || ((SSH_PORT < 1 || SSH_PORT > 65535)); then
  die "SSH_PORT must be between 1 and 65535"
fi
[[ "$REALITY_DEST" =~ ^[^[:space:]:]+:[0-9]+$ ]] ||
  die "REALITY_DEST must be host:port, for example 104.16.123.96:443"
[[ "$REALITY_SERVER_NAME" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]] ||
  die "REALITY_SERVER_NAME is not a valid hostname"

if [[ -z "$CDN_DOMAIN" ]]; then
  CDN_DOMAIN="cdn.${NODE_DOMAIN#*.}"
fi
[[ "$CDN_DOMAIN" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]] ||
  die "CDN_DOMAIN is not a valid hostname"
[[ "$CDN_DOMAIN" != "$NODE_DOMAIN" ]] || die "CDN_DOMAIN must differ from NODE_DOMAIN"

if [[ -e "$xray_config" && ! -f "$managed_dir/managed" ]]; then
  die "$xray_config already exists and is not managed by this project"
fi
if [[ -e "$nginx_site" && ! -f "$managed_dir/managed" ]]; then
  die "$nginx_site already exists and is not managed by this project"
fi
if [[ -e "$nginx_vless_site" && ! -f "$managed_dir/managed" ]]; then
  die "$nginx_vless_site already exists and is not managed by this project"
fi

# shellcheck disable=SC1091
source /etc/os-release
[[ "$ID" == "ubuntu" && "$VERSION_ID" == "24.04" ]] ||
  die "only Ubuntu 24.04 is supported by this Beta"
[[ "$(dpkg --print-architecture)" == "amd64" ]] ||
  die "only amd64 is supported by this Beta"

getent ahosts "$NODE_DOMAIN" >/dev/null ||
  die "$NODE_DOMAIN does not resolve; create DNS records before installing"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates certbot curl nginx openssl python3 ufw

if [[ -z "$VLESS_UUID" ]]; then
  VLESS_UUID="$(cat /proc/sys/kernel/random/uuid)"
fi
if [[ -z "$VLESS_WS_PATH" ]]; then
  VLESS_WS_PATH="/$(openssl rand -hex 16)"
fi
if [[ -z "$REALITY_UUID" ]]; then
  REALITY_UUID="$(cat /proc/sys/kernel/random/uuid)"
fi
if [[ -z "$REALITY_SHORT_ID" ]]; then
  REALITY_SHORT_ID="$(openssl rand -hex 8)"
fi

[[ "$VLESS_UUID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] ||
  die "VLESS_UUID must be a UUID"
[[ "$VLESS_WS_PATH" =~ ^/[A-Za-z0-9._~-]{8,128}$ ]] ||
  die "VLESS_WS_PATH must start with / and use 8-128 safe ASCII characters"
[[ "$REALITY_UUID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] ||
  die "REALITY_UUID must be a UUID"
[[ "$REALITY_SHORT_ID" =~ ^[0-9a-fA-F]{1,16}$ ]] ||
  die "REALITY_SHORT_ID must be 1-16 hexadecimal characters"

backup_dir="/var/backups/self-vps/$(date -u +%Y%m%dT%H%M%SZ)"
install -d -m 700 "$backup_dir"
for path in "$xray_config" "$nginx_site" "$nginx_vless_site" "$reality_env" "$vless_env" /etc/sysctl.conf; do
  if [[ -e "$path" ]]; then
    cp -a "$path" "$backup_dir/"
  fi
done

install -d -m 700 "$managed_dir"
install -d -m 755 /var/www/self-vps/.well-known/acme-challenge
printf '%s\n' '<!doctype html><title>self-vps</title><h1>self-vps is running</h1>' \
  >/var/www/self-vps/index.html

sed "s/__NODE_DOMAIN__/$NODE_DOMAIN/g" "$repo_root/templates/nginx-node.conf" >"$nginx_site"
ln -sfn "$nginx_site" /etc/nginx/sites-enabled/self-vps
sed \
  -e "s#__CDN_DOMAIN__#$CDN_DOMAIN#g" \
  -e "s#__VLESS_WS_PATH__#$VLESS_WS_PATH#g" \
  "$repo_root/templates/nginx-vless-cdn.conf" >"$nginx_vless_site"
chown root:root "$nginx_vless_site"
chmod 640 "$nginx_vless_site"
ln -sfn "$nginx_vless_site" /etc/nginx/sites-enabled/vless-cdn
nginx -t
systemctl enable --now nginx

certbot certonly --non-interactive --agree-tos --keep-until-expiring \
  --email "$ACME_EMAIL" --webroot -w /var/www/self-vps -d "$NODE_DOMAIN"

xray_installer="$(mktemp)"
trap 'rm -f "$xray_installer"' EXIT
curl --fail --location --proto '=https' --tlsv1.2 \
  "https://raw.githubusercontent.com/XTLS/Xray-install/$xray_install_ref/install-release.sh" \
  --output "$xray_installer"
bash "$xray_installer" install

# Reuse the private key from an existing managed config when possible. This
# keeps a reinstall from silently rotating all client credentials.
if [[ -z "${REALITY_PRIVATE_KEY:-}" && -f "$xray_config" ]]; then
  REALITY_PRIVATE_KEY="$(
    python3 - "$xray_config" <<'PY' 2>/dev/null || true
import json
import sys

try:
    with open(sys.argv[1]) as fh:
        data = json.load(fh)
    for inbound in data.get("inbounds", []):
        reality = inbound.get("streamSettings", {}).get("realitySettings", {})
        if reality.get("privateKey"):
            print(reality["privateKey"])
            break
except Exception:
    pass
PY
  )"
fi

if [[ -z "${REALITY_PRIVATE_KEY:-}" ]]; then
  key_output="$(/usr/local/bin/xray x25519)"
  REALITY_PRIVATE_KEY="$(printf '%s\n' "$key_output" | sed -n -e 's/^PrivateKey: //p' -e 's/^Private key: //p' | head -n 1)"
fi
if [[ -z "${REALITY_PUBLIC_KEY:-}" ]]; then
  key_output="$(/usr/local/bin/xray x25519 -i "$REALITY_PRIVATE_KEY")"
  REALITY_PUBLIC_KEY="$(printf '%s\n' "$key_output" | sed -n -e 's/^Password (PublicKey): //p' -e 's/^PublicKey: //p' -e 's/^Public key: //p' | head -n 1)"
fi
[[ -n "$REALITY_PRIVATE_KEY" && -n "$REALITY_PUBLIC_KEY" ]] ||
  die "could not generate or read Reality keypair"

{
  printf 'NODE_DOMAIN=%q\n' "$NODE_DOMAIN"
  printf 'REALITY_UUID=%q\n' "$REALITY_UUID"
  printf 'REALITY_PUBLIC_KEY=%q\n' "$REALITY_PUBLIC_KEY"
  printf 'REALITY_PRIVATE_KEY=%q\n' "$REALITY_PRIVATE_KEY"
  printf 'REALITY_SHORT_ID=%q\n' "$REALITY_SHORT_ID"
  printf 'REALITY_SERVER_NAME=%q\n' "$REALITY_SERVER_NAME"
  printf 'REALITY_DEST=%q\n' "$REALITY_DEST"
} >"$reality_env"
chmod 600 "$reality_env"

{
  printf 'CDN_DOMAIN=%q\n' "$CDN_DOMAIN"
  printf 'VLESS_UUID=%q\n' "$VLESS_UUID"
  printf 'VLESS_WS_PATH=%q\n' "$VLESS_WS_PATH"
} >"$vless_env"
chmod 600 "$vless_env"
touch "$managed_dir/managed"
chmod 600 "$managed_dir/managed"

install -d -o root -g nogroup -m 750 /usr/local/etc/xray
sed \
  -e "s#__REALITY_UUID__#$REALITY_UUID#g" \
  -e "s#__REALITY_DEST__#$REALITY_DEST#g" \
  -e "s#__REALITY_SERVER_NAME__#$REALITY_SERVER_NAME#g" \
  -e "s#__REALITY_PRIVATE_KEY__#$REALITY_PRIVATE_KEY#g" \
  -e "s#__REALITY_SHORT_ID__#$REALITY_SHORT_ID#g" \
  -e "s#__VLESS_UUID__#$VLESS_UUID#g" \
  -e "s#__VLESS_WS_PATH__#$VLESS_WS_PATH#g" \
  "$repo_root/templates/xray-config.json" >"$xray_config"
chown root:nogroup "$xray_config"
chmod 640 "$xray_config"

/usr/local/bin/xray run -test -config "$xray_config"
systemctl enable --now xray

printf '%s\n' tcp_bbr >/etc/modules-load.d/bbr.conf
install -m 644 "$repo_root/templates/99-tcp-tune.conf" /etc/sysctl.d/99-tcp-tune.conf
if [[ -f /etc/sysctl.conf ]]; then
  if grep -qE '^[[:space:]]*net\.core\.somaxconn[[:space:]]*=' /etc/sysctl.conf; then
    sed -i -E 's/^([[:space:]]*net\.core\.somaxconn[[:space:]]*=.*)$/# \1/' /etc/sysctl.conf
  fi
  grep -qE '^[[:space:]]*net\.core\.somaxconn[[:space:]]*=' /etc/sysctl.conf ||
    printf '%s\n' 'net.core.somaxconn = 8192' >>/etc/sysctl.conf
fi
modprobe tcp_bbr
sysctl --system >/dev/null

mapfile -t detected_ssh_ports < <(sshd -T 2>/dev/null | awk '$1 == "port" {print $2}')
detected_ssh_ports+=("$SSH_PORT")
ufw default deny incoming
ufw default allow outgoing
for port in "${detected_ssh_ports[@]}"; do
  ufw allow "$port/tcp"
done
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

if [[ "${ENABLE_SSH_HARDENING:-0}" == "1" ]]; then
  install -d -m 755 /etc/ssh/sshd_config.d
  install -m 600 "$repo_root/templates/sshd-hardening.conf" \
    /etc/ssh/sshd_config.d/00-hynous-hardening.conf
  sshd -t
  systemctl reload ssh
fi

systemctl restart nginx xray

# Optional: install the monitoring watchdog when Docker is already present.
if command -v docker >/dev/null 2>&1 && systemctl is-active --quiet docker; then
  install -m 750 "$repo_root/scripts/docker-watchdog.sh" /usr/local/sbin/self-vps-docker-watchdog.sh
  install -m 644 "$repo_root/templates/self-vps-docker-watchdog.service" \
    /etc/systemd/system/self-vps-docker-watchdog.service
  install -m 644 "$repo_root/templates/self-vps-docker-watchdog.timer" \
    /etc/systemd/system/self-vps-docker-watchdog.timer
  systemctl daemon-reload
  systemctl enable --now self-vps-docker-watchdog.timer
fi

echo "Core Reality node installed."
echo "Reality values are stored in $reality_env (mode 600)."
echo "Client public key: $REALITY_PUBLIC_KEY"
echo "VLESS/CDN values are stored in $vless_env (mode 600)."
echo "Run: sudo $repo_root/scripts/verify.sh"
