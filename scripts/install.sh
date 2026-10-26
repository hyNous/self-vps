#!/usr/bin/env bash
set -Eeuo pipefail

trap 'echo "Install failed at line $LINENO. Existing unmanaged configuration was not intentionally removed." >&2' ERR

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
env_file="${1:-$repo_root/.env}"
managed_dir="/etc/self-vps"
xray_config="/usr/local/etc/xray/config.json"
nginx_site="/etc/nginx/sites-available/self-vps"
nginx_vless_site="/etc/nginx/sites-available/vless-cdn"
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
TROJAN_PASSWORD="${TROJAN_PASSWORD:-}"
CDN_DOMAIN="${CDN_DOMAIN:-}"
VLESS_UUID="${VLESS_UUID:-}"
VLESS_WS_PATH="${VLESS_WS_PATH:-}"

[[ "$NODE_DOMAIN" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]] ||
  die "NODE_DOMAIN is not a valid hostname"
[[ "$NODE_DOMAIN" != *.example.com ]] || die "replace the example NODE_DOMAIN"
[[ "$ACME_EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] ||
  die "ACME_EMAIL is not valid"
if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || ((SSH_PORT < 1 || SSH_PORT > 65535)); then
  die "SSH_PORT must be between 1 and 65535"
fi

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
apt-get install -y ca-certificates certbot curl nginx openssl ufw

if [[ -z "$TROJAN_PASSWORD" && -f "$managed_dir/node.env" ]]; then
  TROJAN_PASSWORD="$(sed -n 's/^TROJAN_PASSWORD=//p' "$managed_dir/node.env" | head -n 1)"
fi
if [[ -z "$TROJAN_PASSWORD" ]]; then
  TROJAN_PASSWORD="$(openssl rand -hex 24)"
fi
[[ "$TROJAN_PASSWORD" =~ ^[A-Za-z0-9._~-]{16,128}$ ]] ||
  die "TROJAN_PASSWORD must be 16-128 safe ASCII characters"

if [[ -z "$VLESS_UUID" && -f "$vless_env" ]]; then
  VLESS_UUID="$(sed -n 's/^VLESS_UUID=//p' "$vless_env" | head -n 1)"
fi
if [[ -z "$VLESS_WS_PATH" && -f "$vless_env" ]]; then
  VLESS_WS_PATH="$(sed -n 's/^VLESS_WS_PATH=//p' "$vless_env" | head -n 1)"
fi
if [[ -z "$VLESS_UUID" ]]; then
  VLESS_UUID="$(cat /proc/sys/kernel/random/uuid)"
fi
if [[ -z "$VLESS_WS_PATH" ]]; then
  VLESS_WS_PATH="/$(openssl rand -hex 16)"
fi
[[ "$VLESS_UUID" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] ||
  die "VLESS_UUID must be a UUID"
[[ "$VLESS_WS_PATH" =~ ^/[A-Za-z0-9._~-]{8,128}$ ]] ||
  die "VLESS_WS_PATH must start with / and use 8-128 safe ASCII characters"

backup_dir="/var/backups/self-vps/$(date -u +%Y%m%dT%H%M%SZ)"
install -d -m 700 "$backup_dir"
for path in "$xray_config" "$nginx_site" "$nginx_vless_site" "$managed_dir/node.env" "$vless_env" /etc/sysctl.conf; do
  if [[ -e "$path" ]]; then
    cp -a "$path" "$backup_dir/"
  fi
done

install -d -m 700 "$managed_dir"
{
  printf 'NODE_DOMAIN=%q\n' "$NODE_DOMAIN"
  printf 'ACME_EMAIL=%q\n' "$ACME_EMAIL"
  printf 'SSH_PORT=%q\n' "$SSH_PORT"
  printf 'TROJAN_PASSWORD=%q\n' "$TROJAN_PASSWORD"
} >"$managed_dir/node.env"
chmod 600 "$managed_dir/node.env"
{
  printf 'CDN_DOMAIN=%q\n' "$CDN_DOMAIN"
  printf 'VLESS_UUID=%q\n' "$VLESS_UUID"
  printf 'VLESS_WS_PATH=%q\n' "$VLESS_WS_PATH"
} >"$vless_env"
chmod 600 "$vless_env"
touch "$managed_dir/managed"
chmod 600 "$managed_dir/managed"

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

install -d -o root -g nogroup -m 750 /usr/local/etc/xray/cert
sed \
  -e "s/__NODE_DOMAIN__/$NODE_DOMAIN/g" \
  -e "s/__TROJAN_PASSWORD__/$TROJAN_PASSWORD/g" \
  -e "s#__VLESS_UUID__#$VLESS_UUID#g" \
  -e "s#__VLESS_WS_PATH__#$VLESS_WS_PATH#g" \
  "$repo_root/templates/xray-config.json" >"$xray_config"
chown root:nogroup "$xray_config"
chmod 640 "$xray_config"

hook="/etc/letsencrypt/renewal-hooks/deploy/xray-cert.sh"
sed "s/__NODE_DOMAIN__/$NODE_DOMAIN/g" "$repo_root/templates/xray-cert-hook.sh" >"$hook"
chmod 750 "$hook"
"$hook"

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

echo "Core node installed. Password is stored in $managed_dir/node.env (mode 600)."
echo "VLESS/CDN values are stored in $vless_env (mode 600)."
echo "Run: sudo $repo_root/scripts/verify.sh"
