#!/usr/bin/env bash
set -Eeuo pipefail

managed_env="/etc/self-vps/node.env"
vless_env="/etc/self-vps/vless-ws.env"
failures=0

pass() {
  printf 'PASS  %s\n' "$1"
}

fail() {
  printf 'FAIL  %s\n' "$1" >&2
  failures=$((failures + 1))
}

check_service() {
  if systemctl is-active --quiet "$1"; then
    pass "$1 is active"
  else
    fail "$1 is not active"
  fi
}

[[ ${EUID} -eq 0 ]] || {
  echo "Error: run with sudo" >&2
  exit 1
}

NODE_DOMAIN=""
if [[ -f "$managed_env" ]]; then
  # shellcheck disable=SC1090
  source "$managed_env"
else
  echo "WARN  $managed_env is missing; skipping domain-specific HTTP/TLS checks" >&2
fi
if [[ -f "$vless_env" ]]; then
  # shellcheck disable=SC1090
  source "$vless_env"
fi

for service in ssh nginx xray certbot.timer; do
  check_service "$service"
done

if nginx -t >/dev/null 2>&1; then
  pass "nginx configuration"
else
  fail "nginx configuration"
fi
if /usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json >/dev/null 2>&1; then
  pass "xray configuration"
else
  fail "xray configuration"
fi

ports=(80 443 8080)
if [[ -n "${VLESS_WS_PATH:-}" ]]; then
  ports+=(10086 8082)
fi
for port in "${ports[@]}"; do
  if ss -lntH "( sport = :$port )" | grep -q .; then
    pass "TCP $port is listening"
  else
    fail "TCP $port is not listening"
  fi
done

if [[ "$(sysctl -n net.ipv4.tcp_congestion_control)" == "bbr" ]] &&
  grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control; then
  pass "BBR is active"
else
  fail "BBR is not active"
fi

if [[ -n "$NODE_DOMAIN" ]]; then
  if curl --fail --silent --show-error --max-time 15 \
    --resolve "$NODE_DOMAIN:80:127.0.0.1" "http://$NODE_DOMAIN/" >/dev/null; then
    pass "Nginx HTTP site"
  else
    fail "Nginx HTTP site"
  fi

  if curl --fail --silent --show-error --max-time 15 \
    --resolve "$NODE_DOMAIN:443:127.0.0.1" "https://$NODE_DOMAIN/" >/dev/null; then
    pass "Xray TLS fallback"
  else
    fail "Xray TLS fallback"
  fi
fi

if [[ -n "${CDN_DOMAIN:-}" && -n "${VLESS_WS_PATH:-}" ]]; then
  ws_status="$(curl --http1.1 --silent --show-error --max-time 15 \
    -H "Host: $CDN_DOMAIN" \
    -H 'Upgrade: websocket' \
    -H 'Connection: Upgrade' \
    -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
    -H 'Sec-WebSocket-Version: 13' \
    -o /dev/null -w '%{http_code}' \
    "http://127.0.0.1:8082$VLESS_WS_PATH" || true)"
  if [[ "$ws_status" == "101" ]]; then
    pass "VLESS WebSocket upgrade"
  else
    fail "VLESS WebSocket upgrade (status=$ws_status)"
  fi

  plain_status="$(curl --http1.1 --silent --show-error --max-time 15 \
    -H "Host: $CDN_DOMAIN" \
    -o /dev/null -w '%{http_code}' \
    "http://127.0.0.1:8082$VLESS_WS_PATH" || true)"
  if [[ "$plain_status" == "404" ]]; then
    pass "VLESS path without Upgrade returns 404"
  else
    fail "VLESS path without Upgrade (status=$plain_status)"
  fi

  camo_status="$(curl --http1.1 --silent --show-error --max-time 15 \
    -H "Host: $CDN_DOMAIN" \
    -o /dev/null -w '%{http_code}' \
    "http://127.0.0.1:8082/" || true)"
  if [[ "$camo_status" == "200" ]]; then
    pass "VLESS CDN camouflage page"
  else
    fail "VLESS CDN camouflage page (status=$camo_status)"
  fi
fi

if [[ -f /etc/ssh/sshd_config.d/00-hynous-hardening.conf ]]; then
  sshd_effective="$(sshd -T 2>/dev/null || true)"
  if grep -qx 'passwordauthentication no' <<<"$sshd_effective" &&
    grep -Eq '^permitrootlogin (no|without-password)$' <<<"$sshd_effective"; then
    pass "SSH key-only hardening"
  else
    fail "SSH key-only hardening"
  fi
fi

if ((failures > 0)); then
  echo "$failures check(s) failed." >&2
  exit 1
fi

echo "All core checks passed."
