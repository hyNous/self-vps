#!/usr/bin/env bash
set -Eeuo pipefail

managed_env="/etc/self-vps/node.env"
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
[[ -f "$managed_env" ]] || {
  echo "Error: $managed_env is missing" >&2
  exit 1
}

# shellcheck disable=SC1090
source "$managed_env"

for service in ssh nginx xray certbot.timer; do
  check_service "$service"
done

nginx -t >/dev/null 2>&1 && pass "nginx configuration" || fail "nginx configuration"
/usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json >/dev/null 2>&1 &&
  pass "xray configuration" || fail "xray configuration"

for port in 80 443 8080; do
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

curl --fail --silent --show-error --max-time 15 \
  --resolve "$NODE_DOMAIN:80:127.0.0.1" "http://$NODE_DOMAIN/" >/dev/null &&
  pass "Nginx HTTP site" || fail "Nginx HTTP site"

curl --fail --silent --show-error --max-time 15 \
  --resolve "$NODE_DOMAIN:443:127.0.0.1" "https://$NODE_DOMAIN/" >/dev/null &&
  pass "Xray TLS fallback" || fail "Xray TLS fallback"

if ((failures > 0)); then
  echo "$failures check(s) failed." >&2
  exit 1
fi

echo "All core checks passed."
